// Generates Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.78, blue: 0.72, alpha: 1),
                        NSColor(srgbRed: 0.25, green: 0.48, blue: 0.98, alpha: 1)])!
        .draw(in: shape, angle: -60)

    // A task card sliding in from the right edge.
    let card = NSRect(x: rect.minX + 250, y: rect.minY + 150, width: rect.width - 250, height: rect.height - 300)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 60, yRadius: 60)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSColor.white.withAlphaComponent(0.95).setFill()
    cardPath.fill()
    // Three tasks: a checked circle and two open ones, each with a line of text.
    let ink = NSColor(srgbRed: 0.24, green: 0.52, blue: 0.95, alpha: 1)
    for i in 0..<3 {
        let cy = card.maxY - 150 - CGFloat(i) * 110
        let circle = NSRect(x: card.minX + 70, y: cy - 30, width: 60, height: 60)
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 5, dy: 5))
        if i == 0 {
            ink.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: circle.minX + 16, y: circle.midY + 1))
            check.line(to: NSPoint(x: circle.minX + 27, y: circle.midY - 11))
            check.line(to: NSPoint(x: circle.maxX - 14, y: circle.midY + 13))
            check.lineWidth = 9
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            ink.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 9
            ring.stroke()
        }
        let widths: [CGFloat] = [0.55, 0.75, 0.45]
        ink.withAlphaComponent(i == 0 ? 0.22 : 0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: circle.maxX + 30, y: cy - 17, width: (card.maxX - circle.maxX - 30) * widths[i], height: 34),
                     xRadius: 17, yRadius: 17).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return true
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
