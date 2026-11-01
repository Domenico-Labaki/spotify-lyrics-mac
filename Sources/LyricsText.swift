import Foundation

struct Line {
    let time: Double
    let text: String
}

enum LyricsText {
    // Encode only RFC 3986 unreserved ASCII. In particular, '+' must not be
    // interpreted as a space by servers using form-style query decoding.
    static func searchURL(title: String, artist: String, album: String) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let values = [("track_name", title), ("artist_name", artist), ("album_name", album)]
        components.percentEncodedQuery = values.map { key, value in
            let normalized = value.precomposedStringWithCanonicalMapping
            return "\(key)=\(normalized.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return components.url!
    }

    static func parse(_ raw: String) -> [Line] {
        let stamp = try! NSRegularExpression(pattern: #"\[([0-9]+):([0-9]{2}(?:\.[0-9]+)?)\]"#)
        var lines: [Line] = []
        for row in raw.components(separatedBy: .newlines) {
            var cursor = row.startIndex
            if cursor < row.endIndex && row[cursor] == "\u{FEFF}" { cursor = row.index(after: cursor) }
            var times: [Double] = []
            while cursor < row.endIndex {
                let range = NSRange(cursor..<row.endIndex, in: row)
                guard let match = stamp.firstMatch(in: row, options: .anchored, range: range),
                      let whole = Range(match.range, in: row),
                      let minutes = Range(match.range(at: 1), in: row),
                      let seconds = Range(match.range(at: 2), in: row),
                      let min = Double(row[minutes]), let sec = Double(row[seconds]), sec < 60 else { break }
                times.append(min * 60 + sec)
                cursor = whole.upperBound
            }
            guard !times.isEmpty else { continue }
            let text = String(row[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(contentsOf: times.map { Line(time: $0, text: text) })
        }
        return lines.sorted { $0.time < $1.time }
    }
}
