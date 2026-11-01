import AppKit
let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 48 * 4, bitsPerPixel: 32)!
let bytes = image.bitmapData!
for y in 0..<48 { for x in 0..<48 {
    let i = y * image.bytesPerRow + x * 4
    bytes[i] = x < 24 ? 255 : 0; bytes[i + 1] = 0; bytes[i + 2] = x < 24 ? 0 : 255; bytes[i + 3] = 255
} }
let png = image.representation(using: .png, properties: [:])!
let colors = ArtworkColors.extract(png)!
let a = colors[0].usingColorSpace(.sRGB)!, b = colors[1].usingColorSpace(.sRGB)!
precondition(abs(a.redComponent - b.redComponent) > 0.5 && abs(a.blueComponent - b.blueComponent) > 0.5)
precondition(ArtworkColors.extract(Data()) == nil)
print("Artwork palette checks passed")
