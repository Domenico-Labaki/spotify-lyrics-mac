import AppKit
import Foundation
import QuartzCore
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class LyricsApp: NSObject, NSApplicationDelegate {
    private let cache = TrackCache()
    private var item: NSStatusItem!
    private let queue = DispatchQueue(label: "spotify.read")
    private var reading = false
    private var currentID: String?
    private var lines: [Line] = []
    private var request: URLSessionDataTask?
    private var artworkRequest: URLSessionDataTask?
    private var background: CAGradientLayer!
    private var backgroundMask: CAGradientLayer!
    private var timer: Timer?
    private var displayTimer: Timer?
    private var sampledPosition: Double?
    private var sampledAt = Date()
    private var lyricClip: PassthroughClip!
    private var lyricLabel: NSTextField!
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
        item.button?.toolTip = "Spotify Lyrics"
        if let button = item.button {
            button.wantsLayer = true
            background = CAGradientLayer()
            background.startPoint = CGPoint(x: 0, y: 0.5)
            background.endPoint = CGPoint(x: 1, y: 0.5)
            background.cornerRadius = 6
            backgroundMask = CAGradientLayer()
            backgroundMask.startPoint = CGPoint(x: 0, y: 0.5)
            backgroundMask.endPoint = CGPoint(x: 1, y: 0.5)
            backgroundMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            backgroundMask.locations = [0, 0.12, 0.88, 1]
            background.mask = backgroundMask
            background.isHidden = true
            button.layer?.insertSublayer(background, at: 0)
            lyricClip = PassthroughClip(frame: button.bounds.insetBy(dx: 8, dy: 0))
            lyricClip.autoresizingMask = [.width, .height]
            lyricClip.wantsLayer = true
            lyricClip.layer?.masksToBounds = true
            lyricLabel = NSTextField(labelWithString: "")
            lyricLabel.font = button.font ?? NSFont.menuBarFont(ofSize: 0)
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
                if let error { self.item.button?.toolTip = "Spotify Lyrics: \(error[NSAppleScript.errorMessage] ?? "Automation error")" }
                guard let track, !track.id.isEmpty else { self.clear(); return }
                if self.currentID != track.id {
                    self.currentID = track.id
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
        request?.cancel(); request = nil; artworkRequest?.cancel(); currentID = nil; lines = []; sampledPosition = nil
        background?.isHidden = true
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
                item.button?.toolTip = "Spotify Lyrics"
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
                    self.item.button?.toolTip = "Lyrics service unavailable; retrying shortly"
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
                self.item.button?.toolTip = parsed.isEmpty ? "No timed lyrics found" : "Spotify Lyrics"
            }
        }
        request?.resume()
    }

    private func fetchArtwork(_ track: Track) {
        artworkRequest?.cancel()
        background.colors = [NSColor.labelColor.withAlphaComponent(0.04).cgColor,
                             NSColor.labelColor.withAlphaComponent(0.025).cgColor]
        if let data = cache.get(kind: "artwork", key: track.artworkURL),
           let colors = ArtworkColors.extract(data) {
            background.colors = colors.map { $0.cgColor }
            return
        }
        guard let url = URL(string: track.artworkURL), url.scheme == "https",
              let host = url.host?.lowercased(), host == "scdn.co" || host.hasSuffix(".scdn.co") else { return }
        artworkRequest = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data, data.count <= 5_000_000,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let colors = ArtworkColors.extract(data) else { return }
            self?.cache.put(data, kind: "artwork", key: track.artworkURL)
            DispatchQueue.main.async {
                guard let self, self.currentID == track.id else { return }
                self.background.colors = colors.map { $0.cgColor }
            }
        }
        artworkRequest?.resume()
    }

    private func show(position: Double) {
        let index = lines.lastIndex(where: { $0.time <= position })
        let text = index.map { lines[$0].text } ?? ""
        guard let button = item.button else { return }
        item.length = lines.isEmpty ? NSStatusItem.variableLength : 320
        background.frame = button.bounds.insetBy(dx: 2, dy: 0)
        backgroundMask.frame = background.bounds
        background.isHidden = lines.isEmpty
        let title = text.isEmpty ? "♫" : text
        if displayedText != title {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               !lyricLabel.isHidden, !lyricLabel.stringValue.isEmpty, !text.isEmpty {
                let outgoing = NSTextField(labelWithString: lyricLabel.stringValue)
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
            if !text.isEmpty { button.toolTip = text }
        }
        guard !text.isEmpty else { lyricLabel.isHidden = true; return }
        lyricLabel.isHidden = false
        let font = lyricLabel.font ?? NSFont.menuBarFont(ofSize: 0)
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        let visible = max(1, lyricClip.bounds.width)
        let overflow = max(0, measured - visible)
        var progress = 0.0
        if overflow > 0, let index, index + 1 < lines.count,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let start = lines[index].time
            let end = lines[index + 1].time
            let duration = end - start
            if duration > 0 {
                // Hold briefly at each end, then traverse using provider timing.
                let lead = min(0.5, duration * 0.15)
                let tail = min(0.5, duration * 0.15)
                progress = min(1, max(0, (position - start - lead) / max(0.01, duration - lead - tail)))
            }
        }
        lyricLabel.alignment = overflow > 0 ? .left : .center
        let labelHeight = lyricLabel.intrinsicContentSize.height
        lyricLabel.frame = NSRect(x: -overflow * progress,
                                  y: (lyricClip.bounds.height - labelHeight) / 2,
                                  width: max(measured, visible), height: labelHeight)
    }

}

let app = NSApplication.shared
let delegate = LyricsApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
