import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let side = CGFloat(size)
        let inset = side * 0.08
        let box = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let path = NSBezierPath(roundedRect: box, xRadius: side * 0.19, yRadius: side * 0.19)
        NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.28, alpha: 1),
                   ending: NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.075, alpha: 1))!.draw(in: path, angle: -90)
        guard let symbol = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [.white])) else {
            fatalError("The play.rectangle SF Symbol is unavailable.")
        }
        let symbolWidth = side * 0.65
        let symbolHeight = symbolWidth * symbol.size.height / symbol.size.width
        symbol.draw(in: NSRect(x: (side - symbolWidth) / 2, y: (side - symbolHeight) / 2,
                              width: symbolWidth, height: symbolHeight))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    }
}
