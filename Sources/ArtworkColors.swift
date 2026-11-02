import AppKit

/// Select common, distinct chromatic colors without inventing new hues.
enum ArtworkColors {
    static let whiteBlend: CGFloat = 0.35
    static let minimumDisplayDistance: CGFloat = 0.22

    static func displayColor(_ color: NSColor) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        return srgb.blended(withFraction: whiteBlend, of: .white) ?? srgb
    }

    static func displayDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let a = displayColor(a).usingColorSpace(.sRGB),
              let b = displayColor(b).usingColorSpace(.sRGB) else { return 0 }
        return sqrt(pow(a.redComponent - b.redComponent, 2) +
                    pow(a.greenComponent - b.greenComponent, 2) +
                    pow(a.blueComponent - b.blueComponent, 2))
    }

    static func extract(_ data: Data) -> [NSColor]? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        struct HueGroup {
            var score: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var pixels: Int = 0
        }
        var groups = [HueGroup](repeating: HueGroup(), count: 24)
        var neutralTotals = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), count: CGFloat(0))
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
            let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
            neutralTotals.r += r; neutralTotals.g += g; neutralTotals.b += b; neutralTotals.count += 1
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            guard high >= 0.12, delta > 0, delta / high >= 0.3 else { continue }
            let sat = delta / high
            var hue: CGFloat
            if high == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if high == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
            let bucket = min(23, Int(hue * 24))
            // Warm skin and beige areas often dominate covers; retain them as a
            // fallback but favor other chromatic accents when both are present.
            let warmPenalty: CGFloat = hue > 0.025 && hue < 0.12 ? 0.2 : 1
            let weight = sat * sat * sqrt(high) * warmPenalty
            groups[bucket].score += weight
            groups[bucket].saturation += sat * weight
            groups[bucket].brightness += high * weight
            groups[bucket].pixels += 1
        }
        let ranked = groups.indices.filter { groups[$0].pixels >= 3 && groups[$0].score > 0 }
            .sorted { groups[$0].score == groups[$1].score ? $0 < $1 : groups[$0].score > groups[$1].score }
        guard let first = ranked.first else {
            guard neutralTotals.count > 0 else { return nil }
            let gray = NSColor(srgbRed: neutralTotals.r / neutralTotals.count,
                               green: neutralTotals.g / neutralTotals.count,
                               blue: neutralTotals.b / neutralTotals.count, alpha: 1)
            return [gray, gray]
        }
        func color(_ bucket: Int) -> NSColor {
            let group = groups[bucket]
            // Keep the artwork hue while making muted accents distinguishable
            // after the title's white blend.
            let saturation = max(0.6, min(1, group.saturation / group.score))
            let brightness = max(0.65, min(1, group.brightness / group.score))
            return NSColor(deviceHue: (CGFloat(bucket) + 0.5) / 24,
                           saturation: saturation, brightness: brightness, alpha: 1)
        }
        let minScore = groups[first].score * 0.004
        let firstColor = color(first)
        let second = ranked.dropFirst().first { candidate in
            let difference = abs(candidate - first)
            let hueDistance = min(difference, 24 - difference)
            return hueDistance >= 4 && groups[candidate].score >= minScore &&
                displayDistance(firstColor, color(candidate)) >= minimumDisplayDistance
        }
        return [color(first), color(second ?? first)]
    }
}
