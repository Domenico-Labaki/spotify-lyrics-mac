import AppKit

// A small color histogram selects common cover colors, then prefers a second
// common color sufficiently far from the first in RGB space.
enum ArtworkColors {
    static func extract(_ data: Data) -> [NSColor]? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var counts: [Int: Int] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
            let r = Int(pixels[i]) / 32, g = Int(pixels[i + 1]) / 32, b = Int(pixels[i + 2]) / 32
            counts[(r << 6) | (g << 3) | b, default: 0] += 1
        }
        let ranked = counts.sorted { $0.value > $1.value }
        guard let first = ranked.first else { return nil }
        func rgb(_ key: Int) -> (Double, Double, Double) {
            (Double((key >> 6) & 7) / 7, Double((key >> 3) & 7) / 7, Double(key & 7) / 7)
        }
        let one = rgb(first.key)
        let second = ranked.dropFirst().first { entry in
            let two = rgb(entry.key)
            let distance = sqrt(pow(one.0 - two.0, 2) + pow(one.1 - two.1, 2) + pow(one.2 - two.2, 2))
            return entry.value >= max(3, first.value / 20) && distance >= 0.42
        }
        func color(_ v: (Double, Double, Double)) -> NSColor {
            NSColor(srgbRed: v.0, green: v.1, blue: v.2, alpha: 0.12)
        }
        // A monochrome cover gets a neutral second stop, not an invented hue.
        return [color(one), second.map { color(rgb($0.key)) } ?? NSColor.labelColor.withAlphaComponent(0.05)]
    }
}
