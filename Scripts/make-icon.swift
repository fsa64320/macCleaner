import AppKit

// Dessine l'icône (dégradé et étincelles), puis écrit un .iconset.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func sparkle(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let points = [(0, 1), (1, 0), (0, -1), (-1, 0)].map {
        NSPoint(x: center.x + CGFloat($0.0) * radius, y: center.y + CGFloat($0.1) * radius)
    }
    let path = NSBezierPath()
    path.move(to: points[0])
    for index in 1...4 {
        path.curve(to: points[index % 4], controlPoint1: center, controlPoint2: center)
    }
    path.close()
    return path
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [
        NSColor(red: 0.07, green: 0.72, blue: 0.62, alpha: 1),
        NSColor(red: 0.20, green: 0.25, blue: 0.75, alpha: 1),
    ])!.draw(in: shape, angle: -55)
    NSColor.white.setFill()
    sparkle(center: NSPoint(x: s * 0.46, y: s * 0.46), radius: s * 0.27).fill()
    NSColor.white.withAlphaComponent(0.85).setFill()
    sparkle(center: NSPoint(x: s * 0.70, y: s * 0.70), radius: s * 0.11).fill()
    sparkle(center: NSPoint(x: s * 0.72, y: s * 0.27), radius: s * 0.07).fill()
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
