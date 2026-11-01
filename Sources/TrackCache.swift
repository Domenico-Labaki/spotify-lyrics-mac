import Foundation
import CryptoKit

final class TrackCache {
    private let directory: URL
    private let lock = NSLock()
    private let lifetime: TimeInterval = 30 * 24 * 60 * 60
    private let limit = 200

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.directory = directory ?? base.appendingPathComponent("SpotifyLyrics", isDirectory: true)
    }

    private func url(kind: String, key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(kind, isDirectory: true).appendingPathComponent(digest)
    }

    func get(kind: String, key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let file = url(kind: kind, key: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        guard Date().timeIntervalSince(modified) < lifetime else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return try? Data(contentsOf: file)
    }

    func put(_ data: Data, kind: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        let file = url(kind: kind, key: key)
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            if files.count > limit {
                let sorted = files.sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a < b
                }
                for old in sorted.prefix(files.count - limit) { try? FileManager.default.removeItem(at: old) }
            }
        } catch { NSLog("Spotify Lyrics cache write failed: %@", error.localizedDescription) }
    }
}
