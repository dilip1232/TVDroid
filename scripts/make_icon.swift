// Draws the TVDroid app icon and writes an .iconset folder.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded square with a purple to blue gradient (macOS icon grid: 80% of the canvas).
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let base = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.95, alpha: 1)])!
        .draw(in: base, angle: -60)

    // TV screen.
    let screen = NSRect(x: rect.minX + rect.width * 0.17, y: rect.minY + rect.height * 0.3,
                        width: rect.width * 0.66, height: rect.height * 0.44)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: screen, xRadius: screen.height * 0.12, yRadius: screen.height * 0.12).fill()

    // Stand.
    let stand = NSRect(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.2,
                       width: rect.width * 0.24, height: rect.height * 0.045)
    NSBezierPath(roundedRect: stand, xRadius: stand.height / 2, yRadius: stand.height / 2).fill()

    // Play triangle.
    let tri = NSBezierPath()
    let c = NSPoint(x: screen.midX + screen.width * 0.02, y: screen.midY)
    let r = screen.height * 0.22
    tri.move(to: NSPoint(x: c.x - r * 0.8, y: c.y + r))
    tri.line(to: NSPoint(x: c.x - r * 0.8, y: c.y - r))
    tri.line(to: NSPoint(x: c.x + r, y: c.y))
    tri.close()
    NSColor(calibratedRed: 0.35, green: 0.3, blue: 0.95, alpha: 1).setFill()
    tri.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
