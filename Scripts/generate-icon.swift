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

func drawKey(_ text: String, in rect: CGRect, size: CGFloat, fill: NSColor = .white) {
    NSColor.black.withAlphaComponent(0.18).setFill()
    roundedRect(rect.offsetBy(dx: 0, dy: -size * 0.012), radius: size * 0.045).fill()

    fill.setFill()
    roundedRect(rect, radius: size * 0.045).fill()

    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.18, alpha: 1).setStroke()
    roundedRect(rect.insetBy(dx: size * 0.004, dy: size * 0.004), radius: size * 0.04).stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.12, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.16, alpha: 1),
        .paragraphStyle: paragraph,
    ]

    text.draw(in: rect.insetBy(dx: 0, dy: size * 0.025), withAttributes: attributes)
}

func drawArrow(from start: CGPoint, to end: CGPoint, size: CGFloat) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = max(2, size * 0.028)
    path.lineCapStyle = .round
    NSColor(calibratedRed: 0.20, green: 0.68, blue: 1.0, alpha: 1).setStroke()
    path.stroke()

    let angle = atan2(end.y - start.y, end.x - start.x)
    let head = size * 0.045
    let left = CGPoint(x: end.x - cos(angle - .pi / 6) * head, y: end.y - sin(angle - .pi / 6) * head)
    let right = CGPoint(x: end.x - cos(angle + .pi / 6) * head, y: end.y - sin(angle + .pi / 6) * head)

    let headPath = NSBezierPath()
    headPath.move(to: end)
    headPath.line(to: left)
    headPath.move(to: end)
    headPath.line(to: right)
    headPath.lineWidth = max(2, size * 0.028)
    headPath.lineCapStyle = .round
    headPath.stroke()
}

for size in sizes {
    let side = CGFloat(size.pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let full = CGRect(x: 0, y: 0, width: side, height: side)
    let iconRect = full.insetBy(dx: side * 0.055, dy: side * 0.055)
    let background = roundedRect(iconRect, radius: side * 0.22)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.12, alpha: 1),
    ])?.draw(in: background, angle: 90)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    background.lineWidth = side * 0.012
    background.stroke()

    let keySize = side * 0.19
    let gap = side * 0.028
    let center = CGPoint(x: side * 0.50, y: side * 0.52)

    let wRect = CGRect(x: center.x - keySize / 2, y: center.y + keySize / 2 + gap, width: keySize, height: keySize)
    let aRect = CGRect(x: center.x - keySize * 1.5 - gap, y: center.y - keySize / 2, width: keySize, height: keySize)
    let sRect = CGRect(x: center.x - keySize / 2, y: center.y - keySize / 2, width: keySize, height: keySize)
    let dRect = CGRect(x: center.x + keySize / 2 + gap, y: center.y - keySize / 2, width: keySize, height: keySize)

    drawKey("W", in: wRect, size: side)
    drawKey("A", in: aRect, size: side)
    drawKey("S", in: sRect, size: side)
    drawKey("D", in: dRect, size: side)

    drawArrow(from: CGPoint(x: center.x, y: wRect.maxY + side * 0.015), to: CGPoint(x: center.x, y: side * 0.84), size: side)
    drawArrow(from: CGPoint(x: center.x, y: sRect.minY - side * 0.015), to: CGPoint(x: center.x, y: side * 0.31), size: side)
    drawArrow(from: CGPoint(x: aRect.minX - side * 0.015, y: aRect.midY), to: CGPoint(x: side * 0.20, y: aRect.midY), size: side)
    drawArrow(from: CGPoint(x: dRect.maxX + side * 0.015, y: dRect.midY), to: CGPoint(x: side * 0.80, y: dRect.midY), size: side)

    let spaceRect = CGRect(x: side * 0.34, y: side * 0.18, width: side * 0.32, height: side * 0.075)
    drawKey("SPACE", in: spaceRect, size: side * 0.42, fill: NSColor.white.withAlphaComponent(0.92))

    let tap = NSBezierPath(ovalIn: CGRect(x: side * 0.475, y: side * 0.125, width: side * 0.05, height: side * 0.05))
    NSColor(calibratedRed: 0.20, green: 0.68, blue: 1.0, alpha: 0.95).setFill()
    tap.fill()

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
