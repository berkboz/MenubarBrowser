// Draws Perch's app icon into an .iconset folder: swift Icon/icon.swift <out>
//
// A squircle of evening sky with the menu bar glyph on it, bigger: a little
// window, its address bar, hanging from a strip of menu bar.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Apple's grid: a 824-point body centred in 1024, radius ~185.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    shape.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.36, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.24, blue: 0.80, alpha: 1),
    ])!.draw(in: body, angle: -90)

    // Soft light from the top, like glass.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)

    // The menu bar strip.
    NSColor.white.withAlphaComponent(0.22).setFill()
    NSRect(x: 100, y: 800, width: 824, height: 124).fill()

    // The window hanging from it.
    let window = NSRect(x: 262, y: 222, width: 500, height: 540)
    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = NSColor(srgbRed: 0.12, green: 0.06, blue: 0.35, alpha: 0.45)
    lift.shadowBlurRadius = 40
    lift.shadowOffset = NSSize(width: 0, height: -18)
    lift.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: window, xRadius: 70, yRadius: 70).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Its address bar.
    NSColor(srgbRed: 0.36, green: 0.40, blue: 0.95, alpha: 0.18).setFill()
    NSBezierPath(roundedRect: NSRect(x: 312, y: 640, width: 400, height: 70), xRadius: 35, yRadius: 35).fill()
    NSColor(srgbRed: 0.36, green: 0.40, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 336, y: 660, width: 30, height: 30)).fill()

    // Four favourites.
    let tiles: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.35, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
    ]
    for (i, color) in tiles.enumerated() {
        color.setFill()
        let x = 322 + CGFloat(i % 2) * 200
        let y = 290 + CGFloat(1 - i / 2) * 170
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 180, height: 140), xRadius: 34, yRadius: 34).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
print(out)
