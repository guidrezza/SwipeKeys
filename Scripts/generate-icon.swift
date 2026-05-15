import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/AppIcon.iconset")
try? FileManager.default.removeItem(at: outputURL)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawKey(_ text: String, in rect: CGRect, side: CGFloat) {
    NSColor.black.withAlphaComponent(0.16).setFill()
    roundedRect(rect.offsetBy(dx: 0, dy: -side * 0.008), radius: side * 0.025).fill()

    NSColor.white.withAlphaComponent(0.92).setFill()
    roundedRect(rect, radius: side * 0.025).fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    text.draw(
        in: rect.insetBy(dx: 0, dy: side * 0.01),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.42, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.18, alpha: 1),
            .paragraphStyle: paragraph,
        ]
    )
}

func drawSwipeArc(side: CGFloat) {
    let arc = NSBezierPath()
    arc.move(to: CGPoint(x: side * 0.25, y: side * 0.66))
    arc.curve(
        to: CGPoint(x: side * 0.72, y: side * 0.70),
        controlPoint1: CGPoint(x: side * 0.39, y: side * 0.83),
        controlPoint2: CGPoint(x: side * 0.58, y: side * 0.84)
    )
    arc.lineWidth = side * 0.045
    arc.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.96).setStroke()
    arc.stroke()

    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: side * 0.72, y: side * 0.70))
    arrow.line(to: CGPoint(x: side * 0.65, y: side * 0.76))
    arrow.move(to: CGPoint(x: side * 0.72, y: side * 0.70))
    arrow.line(to: CGPoint(x: side * 0.63, y: side * 0.68))
    arrow.lineWidth = side * 0.045
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()
}

func drawHand(side: CGFloat) {
    NSColor.black.withAlphaComponent(0.14).setFill()
    roundedRect(CGRect(x: side * 0.39, y: side * 0.28, width: side * 0.30, height: side * 0.24).offsetBy(dx: 0, dy: -side * 0.012), radius: side * 0.10).fill()

    NSColor.white.setFill()
    roundedRect(CGRect(x: side * 0.48, y: side * 0.40, width: side * 0.082, height: side * 0.30), radius: side * 0.041).fill()
    roundedRect(CGRect(x: side * 0.39, y: side * 0.29, width: side * 0.29, height: side * 0.22), radius: side * 0.095).fill()
    roundedRect(CGRect(x: side * 0.34, y: side * 0.36, width: side * 0.18, height: side * 0.07), radius: side * 0.035).fill()
    roundedRect(CGRect(x: side * 0.58, y: side * 0.42, width: side * 0.07, height: side * 0.16), radius: side * 0.035).fill()
    roundedRect(CGRect(x: side * 0.64, y: side * 0.40, width: side * 0.065, height: side * 0.14), radius: side * 0.032).fill()
}

for size in sizes {
    let side = CGFloat(size.pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let iconRect = CGRect(x: side * 0.055, y: side * 0.055, width: side * 0.89, height: side * 0.89)
    let background = roundedRect(iconRect, radius: side * 0.22)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.32, blue: 0.82, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.92, alpha: 1),
    ])?.draw(in: background, angle: 135)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    background.lineWidth = side * 0.012
    background.stroke()

    let glow = NSBezierPath(ovalIn: CGRect(x: side * 0.24, y: side * 0.24, width: side * 0.52, height: side * 0.52))
    NSColor.white.withAlphaComponent(0.16).setFill()
    glow.fill()

    drawSwipeArc(side: side)
    drawHand(side: side)

    let keyY = side * 0.22
    let keyW = side * 0.105
    let keyH = side * 0.075
    let gap = side * 0.018
    let startX = side * 0.25
    for (index, key) in ["W", "A", "S", "D"].enumerated() {
        drawKey(key, in: CGRect(x: startX + CGFloat(index) * (keyW + gap), y: keyY, width: keyW, height: keyH), side: side)
    }

    drawKey("Space", in: CGRect(x: side * 0.34, y: side * 0.13, width: side * 0.32, height: side * 0.055), side: side)

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(size.name)")
    }

    try png.write(to: outputURL.appendingPathComponent(size.name))
}
