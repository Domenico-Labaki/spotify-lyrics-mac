import AppKit
import Foundation
import QuartzCore
import CoreText
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
    private var lyricClip: PassthroughClip!
    private var lyricLabel: GradientLabel!
    private var displayedText = ""
    private let script = """
    tell application "Spotify"
        if player state is not playing then return {"", "", "", "", 0, 0, false, ""}
        set t to current track
        set coverURL to ""
        try
            set coverURL to artwork url of t
        end try
        return {id of t, name of t, artist of t, album of t, duration of t, player position, true, coverURL}
    end tell
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            if let r = result, r.numberOfItems == 8, r.atIndex(7)?.booleanValue == true {
                track = Track(id: r.atIndex(1)?.stringValue ?? "", title: r.atIndex(2)?.stringValue ?? "", artist: r.atIndex(3)?.stringValue ?? "", album: r.atIndex(4)?.stringValue ?? "", artworkURL: r.atIndex(8)?.stringValue ?? "", duration: Double(r.atIndex(5)?.int32Value ?? 0) / 1000, position: r.atIndex(6)?.doubleValue ?? 0, playing: true)
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
                self.sampledPosition = track.position
                self.sampledAt = Date()
                self.show(position: track.position)
            }
        }
    }

    private func clear() {
        request?.cancel(); request = nil; artworkRequest?.cancel(); artworkRequest = nil; titleColors = nil; currentID = nil; currentTitle = ""; currentArtist = ""; isHovering = false; lines = []; sampledPosition = nil
        item.length = NSStatusItem.variableLength
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

    private func show(position: Double) {
        let index = lines.lastIndex(where: { $0.time <= position })
        let opening = OpeningDisplay.showTitle(lines: lines, position: position) && !currentTitle.isEmpty
        let showTrack = (opening || isHovering) && !currentTitle.isEmpty
        let trackDescription = currentArtist.isEmpty ? currentTitle : "\(currentTitle) — \(currentArtist)"
        let text = showTrack ? trackDescription : (index.map { lines[$0].text } ?? "")
        guard let button = item.button else { return }
        item.length = lines.isEmpty && !opening ? NSStatusItem.variableLength : 320
        lyricClip.frame = NSRect(x: 8, y: 0, width: max(0, button.bounds.width - 16), height: button.bounds.height)
        let title = text.isEmpty ? "♫" : text
        if displayedText != title {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               !lyricLabel.isHidden, !lyricLabel.stringValue.isEmpty, !text.isEmpty {
                let outgoing = GradientLabel(labelWithString: lyricLabel.stringValue)
                outgoing.gradientColors = lyricLabel.gradientColors
                outgoing.font = lyricLabel.font
                outgoing.textColor = lyricLabel.textColor
                outgoing.alignment = lyricLabel.alignment
                outgoing.lineBreakMode = .byClipping
                outgoing.frame = lyricLabel.frame
                outgoing.wantsLayer = true
                lyricClip.addSubview(outgoing, positioned: .below, relativeTo: lyricLabel)
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
                outgoing.layer?.add(animation(fromY: 0, toY: distance, fromOpacity: 1, toOpacity: 0), forKey: "outgoing")
                lyricLabel.layer?.removeAnimation(forKey: "incoming")
                lyricLabel.layer?.add(animation(fromY: -distance, toY: 0, fromOpacity: 0, toOpacity: 1), forKey: "incoming")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { outgoing.removeFromSuperview() }
            }
            displayedText = title
            button.title = text.isEmpty ? "♫" : ""
            lyricLabel.stringValue = text
        }
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
