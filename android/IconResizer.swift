import AppKit

guard CommandLine.arguments.count >= 5 else {
    print("Usage: IconResizer <input_path> <output_path> <canvas_size> <scale_ratio>")
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let canvasSize = CGFloat(Double(CommandLine.arguments[3]) ?? 108)
let scaleRatio = CGFloat(Double(CommandLine.arguments[4]) ?? 0.65)

guard let sourceImage = NSImage(contentsOfFile: inputPath) else {
    print("Failed to load source image: \(inputPath)")
    exit(1)
}

let canvasRect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
let logoSize = canvasSize * scaleRatio
let logoX = (canvasSize - logoSize) / 2.0
let logoY = (canvasSize - logoSize) / 2.0
let logoRect = NSRect(x: logoX, y: logoY, width: logoSize, height: logoSize)

let offscreenRep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize),
    pixelsHigh: Int(canvasSize),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: offscreenRep)!
NSGraphicsContext.current = context

// Draw transparent canvas
NSColor.clear.set()
canvasRect.fill()

// Draw centered zoomed-out logo inside adaptive safe zone
sourceImage.draw(in: logoRect, from: .zero, operation: .copy, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = offscreenRep.representation(using: .png, properties: [:]) else {
    print("Failed to encode PNG")
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Generated padded icon \(outputPath) (\(Int(canvasSize))x\(Int(canvasSize)), scale: \(scaleRatio))")
} catch {
    print("Failed to write PNG: \(error)")
    exit(1)
}
