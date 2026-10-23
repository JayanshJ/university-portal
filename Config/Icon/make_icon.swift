import AppKit

// Regenerate: swift Config/Icon/make_icon.swift Config/Icon/icon-1024.png, then resize into App/Assets.xcassets.
// University Portal icon: a dark tile in the app's palette, a warm graduation cap, and a row of
// course-coloured schedule bars underneath.
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: 824 pt tile centred in 1024, continuous corners.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x0B0B0D).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [color(0x23232A), color(0x0E0E11)])!.draw(in: path, angle: -90)
    // A soft warm glow behind the cap.
    let capCenter = NSPoint(x: 512, y: 580)
    NSGradient(colors: [color(0xF5C451, 0.18), color(0xF5C451, 0)])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: capCenter.x - 270, y: capCenter.y - 250, width: 540, height: 500)),
              relativeCenterPosition: .zero)
    color(0xFFFFFF, 0.08).setStroke()
    path.lineWidth = 3
    path.stroke()

    // The cap.
    let config = NSImage.SymbolConfiguration(pointSize: 290, weight: .semibold)
        .applying(.init(paletteColors: [color(0xF5C451)]))
    if let cap = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let w = cap.size.width, h = cap.size.height
        cap.draw(in: NSRect(x: capCenter.x - w / 2, y: capCenter.y - h / 2, width: w, height: h))
    }

    // Course-coloured schedule bars.
    let bars: [(UInt32, CGFloat)] = [(0x6E9BFF, 132), (0x3DD68C, 84), (0xF472B6, 112), (0xA78BFA, 64)]
    let gap: CGFloat = 20
    let total = bars.reduce(0) { $0 + $1.1 } + gap * CGFloat(bars.count - 1)
    var x = (size - total) / 2
    for (hex, width) in bars {
        color(hex).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 300, width: width, height: 30), xRadius: 15, yRadius: 15).fill()
        x += width + gap
    }
    return true
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote", out.path)
