// Documentation images, run by scripts/docs/capture.sh.
//
//   shoot <out.png> <dark|light> <ring:COUNT:PROGRESS|check|party>
//       Photographs the dev build's zoomed panel over a drawn wallpaper and menu bar, so the Liquid Glass
//       shows over something pretty and never the capturing Mac's own menu bar.
//   shoot --states <out.png>
//       Draws the menu bar item's three states, on a dark and a light menu bar.
//
// Sizes below are in pixels of the final image (two per point of the panel), on 1x and Retina displays alike.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawSymbol(_ name: String, at point: NSPoint, size: CGFloat, colors: [NSColor]) {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: colors))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    image.draw(in: NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                          width: image.size.width, height: image.size.height))
}

/// The app's menu bar item as the app draws it (see StatusIcon), centred at `center`.
func drawItem(_ state: [String], center: NSPoint, dark: Bool, highlighted: Bool) {
    let ink = dark ? NSColor.white : NSColor(white: 0.08, alpha: 1)
    let label = NSAttributedString(string: state[0] == "ring" ? state[1] : "", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .medium), .foregroundColor: ink,
    ])
    let width: CGFloat = state[0] == "ring" ? 64 + label.size().width + 10 : 64
    let pill = NSRect(x: center.x - width / 2, y: center.y - 20, width: width, height: 40)
    if highlighted {
        (dark ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.12)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 20, yRadius: 20).fill()
    }
    switch state[0] {
    case "party":
        drawSymbol("party.popper.fill", at: NSPoint(x: pill.midX, y: pill.midY), size: 26, colors: [.systemOrange, .systemPink])
    case "check":
        drawSymbol("checkmark.circle", at: NSPoint(x: pill.midX, y: pill.midY), size: 26, colors: [ink])
    default:
        let progress = Double(state[2])!
        let ring = NSRect(x: pill.minX + 16, y: pill.midY - 14, width: 28, height: 28)
        let track = NSBezierPath(ovalIn: ring.insetBy(dx: 2, dy: 2))
        track.lineWidth = 4
        ink.withAlphaComponent(0.3).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2 - 2,
                      startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
        arc.lineWidth = 4
        arc.lineCapStyle = .round
        ink.setStroke()
        arc.stroke()
        label.draw(at: NSPoint(x: ring.maxX + 10, y: pill.midY - label.size().height / 2))
    }
}

func menuBarFill(dark: Bool) -> NSColor {
    dark ? NSColor(white: 0.08, alpha: 0.45) : NSColor(white: 1, alpha: 0.5)
}

/// A soft, macOS-like wallpaper: a diagonal wash with a few large glowing blobs.
func drawWallpaper(in bounds: NSRect, dark: Bool) {
    let base = dark ? [color(0x0B1026), color(0x1B1446), color(0x0E2A3F)]
                    : [color(0xDCE8FF), color(0xF3E6FF), color(0xDDF6F1)]
    NSGradient(colors: base)!.draw(in: bounds, angle: -35)
    let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = dark
        ? [(0.18, 0.78, 0.55, color(0x3B5BFF, 0.55)), (0.85, 0.25, 0.6, color(0x14B8A6, 0.45)),
           (0.7, 0.9, 0.45, color(0xA855F7, 0.45)), (0.1, 0.1, 0.5, color(0xF472B6, 0.25))]
        : [(0.18, 0.78, 0.55, color(0x93B4FF, 0.7)), (0.85, 0.25, 0.6, color(0x7EE7D3, 0.6)),
           (0.7, 0.9, 0.45, color(0xE9B5FF, 0.65)), (0.1, 0.1, 0.5, color(0xFFC6D9, 0.55))]
    for (x, y, r, c) in blobs {
        let center = NSPoint(x: bounds.width * x, y: bounds.height * y)
        let radius = max(bounds.width, bounds.height) * r
        NSGradient(colors: [c, c.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

/// A menu bar across the top of `bounds`: the app's item at `itemX`, then battery, Wi-Fi, Control Center, clock.
func drawMenuBar(in bounds: NSRect, dark: Bool, state: [String], itemX: CGFloat) {
    let bar = NSRect(x: 0, y: bounds.height - 48, width: bounds.width, height: 48)
    menuBarFill(dark: dark).setFill()
    bar.fill()
    let ink = dark ? NSColor.white : NSColor(white: 0.08, alpha: 1)
    var x = bounds.width - 28
    // Today's date, to match the panel's Today header; the time is the classic 9:41.
    let date = Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(Locale(identifier: "en_US")))
    let clock = NSAttributedString(string: date.replacingOccurrences(of: ",", with: "") + "  9:41", attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: ink,
    ])
    x -= clock.size().width
    clock.draw(at: NSPoint(x: x, y: bar.midY - clock.size().height / 2))
    for symbol in ["switch.2", "wifi", "battery.75percent"] {
        x -= 58
        drawSymbol(symbol, at: NSPoint(x: x, y: bar.midY), size: 26, colors: [ink])
    }
    // Highlighted, as while its panel is open.
    drawItem(state, center: NSPoint(x: itemX, y: bar.midY), dark: dark, highlighted: true)
}

// MARK: - The menu bar states

func writeStates(to output: String) {
    let size = NSSize(width: 720, height: 232)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let states = [["ring", "4", "0.2"], ["check"], ["party"]]
    for (row, dark) in [true, false].enumerated() {
        let strip = NSRect(x: 0, y: size.height - CGFloat(row + 1) * 116 + 8, width: size.width, height: 100)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: strip, xRadius: 24, yRadius: 24).addClip()
        drawWallpaper(in: strip, dark: dark)
        menuBarFill(dark: dark).setFill()
        strip.fill()
        for (i, state) in states.enumerated() {
            let x = size.width * (CGFloat(i) + 0.5) / CGFloat(states.count)
            drawItem(state, center: NSPoint(x: x, y: strip.midY), dark: dark, highlighted: false)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
}

// MARK: - The panel photograph

final class Backdrop: NSView {
    let dark: Bool
    let state: [String]

    init(frame: NSRect, dark: Bool, state: [String]) {
        self.dark = dark
        self.state = state
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Draw in pixels: on Retina a point is two of them.
        let scale = window?.backingScaleFactor ?? 1
        let transform = NSAffineTransform()
        transform.scale(by: 1 / scale)
        transform.concat()
        let pixels = NSRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale)
        drawWallpaper(in: pixels, dark: dark)
        // The item centred over the panel, as when the panel hangs from it.
        drawMenuBar(in: pixels, dark: dark, state: state, itemX: pixels.midX)
    }
}

func photographPanel(to output: String, dark: Bool, state: [String]) {
    // The panel: the dev app's largest on-screen window (CG coordinates, origin top-left).
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    let panelBounds = windows
        .filter { ($0[kCGWindowOwnerName as String] as? String) == "Google Tasks Client Dev" }
        .compactMap { $0[kCGWindowBounds as String] as? [String: Double] }
        .map { CGRect(x: $0["X"]!, y: $0["Y"]!, width: $0["Width"]!, height: $0["Height"]!) }
        .max { $0.width * $0.height < $1.width * $1.height }
    guard let panelBounds else {
        print("no panel on screen")
        exit(1)
    }
    // Margins (in pixels, converted to points): wallpaper to the sides and below, the drawn menu bar (48)
    // plus a gap (12) above.
    let scale = NSScreen.screens[0].backingScaleFactor
    let capture = CGRect(x: panelBounds.minX - 440 / scale, y: panelBounds.minY - 60 / scale,
                         width: panelBounds.width + 880 / scale, height: panelBounds.height + 140 / scale)
    let screenHeight = NSScreen.screens[0].frame.height
    let region = NSRect(x: capture.minX, y: screenHeight - capture.maxY, width: capture.width, height: capture.height)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .floating  // above ordinary windows, below the app's panel (pop-up menu level)
    window.contentView = Backdrop(frame: NSRect(origin: .zero, size: region.size), dark: dark, state: state)
    window.hasShadow = false
    window.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-R", "\(Int(capture.minX)),\(Int(capture.minY)),\(Int(capture.width)),\(Int(capture.height))", output]
        try! shot.run()
        shot.waitUntilExit()
        print("wrote \(output)")
        exit(0)
    }
    app.run()
}

let args = CommandLine.arguments
if args[1] == "--states" {
    writeStates(to: args[2])
} else {
    photographPanel(to: args[1], dark: args[2] == "dark", state: args[3].split(separator: ":").map(String.init))
}
