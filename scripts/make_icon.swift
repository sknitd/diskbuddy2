import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [NSColor(white: 1.0, alpha: 1), NSColor(white: 0.93, alpha: 1)])!.draw(in: bg, angle: -90)
    NSColor(white: 0, alpha: 0.08).setStroke(); bg.lineWidth = s * 0.004; bg.stroke()

    let c = NSPoint(x: s / 2, y: s / 2)
    let r = s * 0.27, w = s * 0.115
    func arc(_ a0: CGFloat, _ a1: CGFloat, _ color: NSColor) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
        p.lineWidth = w; p.lineCapStyle = .butt; color.setStroke(); p.stroke()
    }
    // clockwise from 12 o'clock
    arc(90, 90 - 118, NSColor(white: 0.22, alpha: 1))
    arc(90 - 121, 90 - 190, NSColor(white: 0.62, alpha: 1))
    arc(90 - 193, 90 - 240, NSColor(red: 0.55, green: 0.40, blue: 0.96, alpha: 1))
    arc(90 - 243, 90 - 262, NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1))
    arc(90 - 265, 90 - 300, NSColor(white: 0.84, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                   ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
