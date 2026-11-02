import AppKit

func imageData(_ fill: (Int) -> (UInt8, UInt8, UInt8)) -> Data {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 48 * 4, bitsPerPixel: 32)!
    let bytes = image.bitmapData!
    for y in 0..<48 { for x in 0..<48 {
        let i = y * image.bytesPerRow + x * 4
        let (r, g, b) = fill(x)
        bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
    } }
    return image.representation(using: .png, properties: [:])!
}
let twoColors = imageData { $0 < 24 ? (240, 20, 20) : (20, 30, 240) }
let result = ArtworkColors.extract(twoColors)!
let first = result[0].usingColorSpace(.sRGB)!, second = result[1].usingColorSpace(.sRGB)!
precondition(abs(first.redComponent - second.redComponent) > 0.5)
precondition(abs(first.blueComponent - second.blueComponent) > 0.5)
let neutral = ArtworkColors.extract(imageData { _ in (80, 80, 80) })!
precondition(neutral.count == 2)
precondition(ArtworkColors.extract(Data()) == nil)
print("Artwork accent selection checks passed")
let portrait = imageData { x in
    if x < 29 { return (200, 132, 110) }
    if x < 40 { return (180, 30, 25) }
    return (88, 42, 140)
}
let accents = ArtworkColors.extract(portrait)!.map { $0.usingColorSpace(.deviceRGB)! }
precondition(accents.contains { $0.hueComponent < 0.05 || $0.hueComponent > 0.95 })
precondition(accents.contains { $0.hueComponent > 0.68 && $0.hueComponent < 0.85 })
print("Portrait accent selection checks passed")

precondition(ArtworkColors.displayDistance(result[0], result[1]) >= ArtworkColors.minimumDisplayDistance)
precondition(ArtworkColors.displayDistance(accents[0], accents[1]) >= ArtworkColors.minimumDisplayDistance)
precondition(ArtworkColors.displayDistance(neutral[0], neutral[1]) == 0)
print("Post-blend color separation checks passed")
