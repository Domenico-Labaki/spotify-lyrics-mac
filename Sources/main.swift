import AppKit
import Foundation
import QuartzCore
import CoreText
import OSLog
import ServiceManagement

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: String
    let duration: Double
    let position: Double
    let playing: Bool
}

struct LyricsResult: Decodable {
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let syncedLyrics: String?
    let instrumental: Bool?
}

final class PassthroughClip: NSView {
    var onHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Draw a single continuous gradient through title glyphs, avoiding repeating patterns.
final class GradientLabel: NSTextField {
    var gradientColors: [NSColor]? {
        didSet { if oldValue != gradientColors { needsDisplay = true } }
    }
    var shimmerPhase: CGFloat? {
        didSet { if oldValue != shimmerPhase { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors = gradientColors, colors.count >= 2,
              let context = NSGraphicsContext.current?.cgContext,
              let left = colors[0].usingColorSpace(.sRGB), let right = colors[1].usingColorSpace(.sRGB),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [left.cgColor, right.cgColor] as CFArray, locations: [0, 1]) else {
            super.draw(dirtyRect)
            return
        }
        let font = self.font ?? NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: stringValue, attributes: attributes))
        if lineBreakMode == .byTruncatingTail {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, Double(bounds.width), .end, token) ?? line
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let x = alignment == .center ? max(0, (bounds.width - width) / 2) : 0
        context.saveGState()
        if isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: (bounds.height - ascent - descent) / 2 + descent)
        context.setTextDrawingMode(.clip)
        CTLineDraw(line, context)
        context.drawLinearGradient(gradient, start: CGPoint(x: x, y: 0),
                                   end: CGPoint(x: x + max(width, 1), y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        if let phase = shimmerPhase,
           let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [NSColor.white.withAlphaComponent(0).cgColor,
                                               NSColor.white.withAlphaComponent(0.9).cgColor,
                                               NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, 0.5, 1]) {
            let center = x + max(width, 1) * phase
            let band = max(8, width * 0.18)
            context.drawLinearGradient(highlight, start: CGPoint(x: center - band, y: 0),
                                       end: CGPoint(x: center + band, y: 0), options: [])
        }
        context.restoreGState()
    }
}

final class LyricsApp: NSObject, NSApplicationDelegate {
    private let cache = TrackCache()
    private var item: NSStatusItem!
    private let queue = DispatchQueue(label: "spotify.read")
    private var reading = false
    private var currentID: String?
    private var currentTitle = ""
    private var currentArtist = ""
    private var isHovering = false
    private var lines: [Line] = []
    private var request: URLSessionDataTask?
    private var artworkRequest: URLSessionDataTask?
    private var titleColors: [NSColor]?
    private var timer: Timer?
    private var displayTimer: Timer?
    private var sampledPosition: Double?
    private var sampledAt = Date()
    private var widthTracker = MenuBarWidthTracker()
    private var desiredWidth: CGFloat { widthTracker.width }
    private var lastWidthCheck = Date.distantPast
    private var widthCheckInProgress = false
    private let widthQueue = DispatchQueue(label: "spotify.menubar.measure", qos: .utility)
    private let widthLogger = Logger(subsystem: "local.spotifylyrics.menubar", category: "width")
    private var lastWidthDiagnostic = ""
    private var lyricClip: PassthroughClip!
    private var lyricLabel: GradientLabel!
    private var displayedText = ""
    private let script = """
    tell application "Spotify"
        if player state is stopped then return {"", "", "", "", 0, 0, false, ""}
        set isPlaying to (player state is playing)
        set t to current track
        set coverURL to ""
        try
            set coverURL to artwork url of t
        end try
        return {id of t, name of t, artist of t, album of t, duration of t, player position, isPlaying, coverURL}
    end tell
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.removeObject(forKey: "settledMenuBarWidths")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "SpotifyLyrics"
        item.button?.title = "♫"
        if let button = item.button {
            button.wantsLayer = true
            lyricClip = PassthroughClip(frame: .zero)
            lyricClip.autoresizingMask = [.width, .height]
            lyricClip.onHover = { [weak self] hovering in
                guard let self else { return }
                self.isHovering = hovering
                if let position = self.sampledPosition {
                    self.show(position: position + Date().timeIntervalSince(self.sampledAt))
                }
            }
            lyricClip.wantsLayer = true
            lyricClip.layer?.masksToBounds = true
            lyricLabel = GradientLabel(labelWithString: "")
            lyricLabel.font = button.font ?? NSFont.menuBarFont(ofSize: 0)
            lyricLabel.textColor = .white
            lyricLabel.alignment = .left
            lyricLabel.lineBreakMode = .byClipping
            lyricLabel.wantsLayer = true
            lyricClip.addSubview(lyricLabel)
            button.addSubview(lyricClip)
        }
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } catch {
                NSLog("Spotify Lyrics login item registration failed: %@", error.localizedDescription)
            }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Spotify Lyrics", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let position = self.sampledPosition else { return }
            self.show(position: position + Date().timeIntervalSince(self.sampledAt))
        }
        // Request only the permission needed to read menu bar geometry.
        DispatchQueue.main.async { _ = MenuBarAccessibility.isTrusted(prompt: true) }
        poll()
    }

    private func poll() {
        guard !reading else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").count > 0 else {
            clear(); return
        }
        reading = true
        let source = script
        queue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let track: Track?
            if let r = result, r.numberOfItems == 8 {
                track = Track(id: r.atIndex(1)?.stringValue ?? "", title: r.atIndex(2)?.stringValue ?? "", artist: r.atIndex(3)?.stringValue ?? "", album: r.atIndex(4)?.stringValue ?? "", artworkURL: r.atIndex(8)?.stringValue ?? "", duration: Double(r.atIndex(5)?.int32Value ?? 0) / 1000, position: r.atIndex(6)?.doubleValue ?? 0, playing: r.atIndex(7)?.booleanValue ?? false)
            } else { track = nil }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                guard let track, !track.id.isEmpty else { self.clear(); return }
                if self.currentID != track.id {
                    self.currentID = track.id
                    self.currentTitle = track.title
                    self.currentArtist = track.artist
                    self.lines = []
                    self.item.button?.title = "♫"
                    self.lyricLabel.stringValue = ""
                    self.displayedText = ""
                    self.fetch(track)
                    self.fetchArtwork(track)
                }
                if track.playing {
                    self.sampledPosition = track.position
                    self.sampledAt = Date()
                    self.show(position: track.position)
                } else {
                    self.sampledPosition = nil
                    self.showPaused()
                }
            }
        }
    }

    private func clear() {
        request?.cancel(); request = nil; artworkRequest?.cancel(); artworkRequest = nil; titleColors = nil; currentID = nil; currentTitle = ""; currentArtist = ""; isHovering = false; lines = []; sampledPosition = nil
        item.length = NSStatusItem.variableLength
        widthTracker = MenuBarWidthTracker()
        lastWidthCheck = .distantPast
        item.button?.title = "♫"
        lyricLabel?.stringValue = ""
        displayedText = ""
    }

    private func fetch(_ track: Track) {
        request?.cancel()
        if let data = cache.get(kind: "lyrics", key: track.id),
           let raw = String(data: data, encoding: .utf8) {
            let cached = LyricsText.parse(raw)
            if !cached.isEmpty {
                lines = cached
                return
            }
        }
        var urlRequest = URLRequest(url: LyricsText.searchURL(title: track.title, artist: track.artist, album: track.album))
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("SpotifyLyrics/0.1 (macOS personal lyrics display)", forHTTPHeaderField: "User-Agent")
        request = URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, let results = try? JSONDecoder().decode([LyricsResult].self, from: data) else {
                DispatchQueue.main.async {
                    guard let self, self.currentID == track.id else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.currentID == track.id else { return }
                        self.fetch(track)
                    }
                }
                return
            }
            // Reject distant recordings; prefer the closest duration among timed results.
            let candidates = results.filter { $0.syncedLyrics != nil && $0.instrumental != true && ($0.duration == nil || abs($0.duration! - track.duration) <= 5) }
            let best = candidates.min { abs(($0.duration ?? track.duration) - track.duration) < abs(($1.duration ?? track.duration) - track.duration) }
            let raw = best?.syncedLyrics ?? ""
            let parsed = LyricsText.parse(raw)
            if !parsed.isEmpty, let data = raw.data(using: .utf8) {
                self?.cache.put(data, kind: "lyrics", key: track.id)
            }
            DispatchQueue.main.async {
                guard let self, self.currentID == track.id else { return }
                self.lines = parsed
            }
        }
        request?.resume()
    }

    private func fetchArtwork(_ track: Track) {
        artworkRequest?.cancel()
        titleColors = nil
        guard let url = URL(string: track.artworkURL), url.scheme == "https",
              let host = url.host?.lowercased(), host == "scdn.co" || host.hasSuffix(".scdn.co") else { return }
        if let data = cache.get(kind: "artwork", key: track.artworkURL), let colors = ArtworkColors.extract(data) {
            titleColors = colors.map { ArtworkColors.displayColor($0) }
            return
        }
        artworkRequest = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data, data.count <= 5_000_000,
                  let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let colors = ArtworkColors.extract(data) else { return }
            self?.cache.put(data, kind: "artwork", key: track.artworkURL)
            DispatchQueue.main.async {
                guard let self, self.currentID == track.id else { return }
                self.titleColors = colors.map { ArtworkColors.displayColor($0) }
            }
        }
        artworkRequest?.resume()
    }

    private func logWidthStatus(_ status: String) {
        guard status != lastWidthDiagnostic else { return }
        lastWidthDiagnostic = status
        widthLogger.notice("\(status, privacy: .public)")
    }

    private func requestWidthMeasurement() {
        let trusted = MenuBarAccessibility.isTrusted(prompt: false)
        if !trusted { logWidthStatus("Accessibility unavailable; using compact width") }
        guard !widthCheckInProgress, NSMenu.menuBarVisible(),
              item.isVisible, let primary = NSScreen.screens.first else { return }
        widthCheckInProgress = true
        let top = primary.frame.maxY
        let screenInfo = NSScreen.screens.map { screen in
            let frame = screen.frame
            return MenuBarAccessibility.ScreenInfo(
                frame: CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height),
                notchRight: screen.auxiliaryTopRightArea?.minX)
        }
        let running = NSWorkspace.shared.runningApplications
        let ownWindowFrame = item.button?.window.map { window in
            let frame = window.frame
            return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        }
        let snapshot = MenuBarAccessibility.Snapshot(
            ownPID: ProcessInfo.processInfo.processIdentifier,
            appPIDs: running.map { $0.processIdentifier },
            statusHostPIDs: running.filter { $0.bundleIdentifier == "com.apple.controlcenter" }.map { $0.processIdentifier },
            frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            allocatedWidth: desiredWidth,
            ownWindowFrame: ownWindowFrame,
            screens: screenInfo)
        widthQueue.async { [weak self] in
            let measurement = MenuBarAccessibility.measure(snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.widthCheckInProgress = false
                guard self.currentID != nil else { return }
                switch measurement {
                case .visible(let width, let layout):
                    self.logWidthStatus("Measured available width: \(width)")
                    _ = self.widthTracker.update(width, layout: layout)
                case .hidden:
                    self.logWidthStatus("Status item hidden; shrinking to recover")
                    _ = self.widthTracker.itemIsHidden()
                case .unavailable:
                    self.logWidthStatus("Menu bar measurement unavailable; using safe recovery")
                    _ = self.widthTracker.update(nil)
                }
            }
        }
    }

    private func animateTextTransition() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        func animation(fromY: CGFloat, toY: CGFloat, fromOpacity: Float, toOpacity: Float) -> CAAnimationGroup {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = fromY; move.toValue = toY
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity; fade.toValue = toOpacity
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.3
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            return group
        }
        let distance = lyricClip.bounds.height
        if !lyricLabel.isHidden, !lyricLabel.stringValue.isEmpty {
            let outgoing = GradientLabel(labelWithString: lyricLabel.stringValue)
            outgoing.gradientColors = lyricLabel.gradientColors
            outgoing.font = lyricLabel.font
            outgoing.textColor = lyricLabel.textColor
            outgoing.alignment = lyricLabel.alignment
            outgoing.lineBreakMode = .byClipping
            outgoing.frame = lyricLabel.frame
            outgoing.wantsLayer = true
            lyricClip.addSubview(outgoing, positioned: .below, relativeTo: lyricLabel)
            outgoing.layer?.add(animation(fromY: 0, toY: distance, fromOpacity: 1, toOpacity: 0), forKey: "outgoing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { outgoing.removeFromSuperview() }
        }
        lyricLabel.layer?.removeAnimation(forKey: "incoming")
        lyricLabel.layer?.add(animation(fromY: -distance, toY: 0, fromOpacity: 0, toOpacity: 1), forKey: "incoming")
    }

    private func showPaused() {
        guard let button = item.button else { return }
        // Keep the current width; use the stable compact width on a paused launch.
        if item.length < 0 { item.length = desiredWidth }
        lyricClip.frame = NSRect(x: 8, y: 0, width: max(0, button.bounds.width - 16), height: button.bounds.height)
        if displayedText != "⏸︎ Paused" { animateTextTransition() }
        lyricLabel.gradientColors = nil
        lyricLabel.shimmerPhase = nil
        lyricLabel.stringValue = "⏸︎ Paused"
        lyricLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        lyricLabel.alignment = .center
        lyricLabel.lineBreakMode = .byTruncatingTail
        lyricLabel.isHidden = false
        let height = lyricLabel.intrinsicContentSize.height
        lyricLabel.frame = NSRect(x: 0, y: (lyricClip.bounds.height - height) / 2,
                                 width: lyricClip.bounds.width, height: height)
        displayedText = "⏸︎ Paused"
        button.title = ""
    }

    private func show(position: Double) {
        let index = lines.lastIndex(where: { $0.time <= position })
        let opening = OpeningDisplay.showTitle(lines: lines, position: position) && !currentTitle.isEmpty
        let showTrack = (opening || isHovering) && !currentTitle.isEmpty
        let trackDescription = currentArtist.isEmpty ? currentTitle : "\(currentTitle) — \(currentArtist)"
        let text = showTrack ? trackDescription : (index.map { lines[$0].text } ?? "")
        guard let button = item.button else { return }
        if lines.isEmpty && !opening {
            item.length = NSStatusItem.variableLength
        } else {
            let now = Date()
            if item.length != desiredWidth {
                item.length = desiredWidth
                lastWidthCheck = now // Let macOS settle after a resize.
            } else if now.timeIntervalSince(lastWidthCheck) >= 1.2 {
                lastWidthCheck = now
                requestWidthMeasurement()
            }
        }
        lyricClip.frame = NSRect(x: 8, y: 0, width: max(0, button.bounds.width - 16), height: button.bounds.height)
        let title = text.isEmpty ? "♫" : text
        if displayedText != title {
            if !lyricLabel.isHidden, !lyricLabel.stringValue.isEmpty, !text.isEmpty {
                animateTextTransition()
            }
            displayedText = title
            button.title = text.isEmpty ? "♫" : ""
            lyricLabel.stringValue = text
        }
        lyricLabel.textColor = .white
        lyricLabel.gradientColors = showTrack ? titleColors : nil
        if showTrack, titleColors != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let cycle = CACurrentMediaTime().truncatingRemainder(dividingBy: 4.5)
            lyricLabel.shimmerPhase = cycle < 1.4 ? CGFloat(cycle / 1.4) * 1.4 - 0.2 : nil
        } else {
            lyricLabel.shimmerPhase = nil
        }
        guard !text.isEmpty else { lyricLabel.isHidden = true; return }
        lyricLabel.isHidden = false
        let font = lyricLabel.font ?? NSFont.menuBarFont(ofSize: 0)
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        let visible = max(1, lyricClip.bounds.width)
        let overflow = max(0, measured - visible)
        var progress = 0.0
        if overflow > 0, !showTrack, let index, index + 1 < lines.count,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            progress = LyricScroll.progress(position: position, start: lines[index].time,
                                            end: lines[index + 1].time)
        }
        lyricLabel.alignment = overflow > 0 && !showTrack ? .left : .center
        lyricLabel.lineBreakMode = showTrack ? .byTruncatingTail : .byClipping
        let labelHeight = lyricLabel.intrinsicContentSize.height
        lyricLabel.frame = NSRect(x: -overflow * progress,
                                  y: (lyricClip.bounds.height - labelHeight) / 2,
                                  width: showTrack ? visible : max(measured, visible), height: labelHeight)
    }

}

let app = NSApplication.shared
let delegate = LyricsApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
