import Foundation
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-cache-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: dir) }
let first = TrackCache(directory: dir)
let payload = Data("[00:01.00]你好 🎵".utf8)
precondition(first.get(kind: "lyrics", key: "track:1") == nil)
first.put(payload, kind: "lyrics", key: "track:1")
let next = TrackCache(directory: dir)
precondition(next.get(kind: "lyrics", key: "track:1") == payload)
precondition(next.get(kind: "artwork", key: "track:1") == nil)
let folder = dir.appendingPathComponent("lyrics")
let file = try! FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first!
try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -31 * 86400)], ofItemAtPath: file.path)
precondition(next.get(kind: "lyrics", key: "track:1") == nil)
print("Cache persistence, separation, and expiry checks passed")
