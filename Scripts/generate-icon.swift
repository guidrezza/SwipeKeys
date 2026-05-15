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

for size in sizes {
    let image = NSImage(size: NSSize(width: size.pixels, height: size.pixels))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size.pixels, height: size.pixels)
    let radius = CGFloat(size.pixels) * 0.22
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(size.pixels) * 0.06, dy: CGFloat(size.pixels) * 0.06), xRadius: radius, yRadius: radius)

    NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.18, alpha: 1).setFill()
    background.fill()

    let stripeWidth = CGFloat(size.pixels) * 0.16
    let colors = [
        NSColor(calibratedRed: 0.19, green: 0.74, blue: 0.46, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.49, blue: 0.93, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.77, blue: 0.22, alpha: 1),
    ]

    for index in 0..<3 {
        let x = CGFloat(size.pixels) * (0.22 + CGFloat(index) * 0.20)
        let stripe = NSBezierPath(roundedRect: NSRect(x: x, y: CGFloat(size.pixels) * 0.18, width: stripeWidth, height: CGFloat(size.pixels) * 0.64), xRadius: stripeWidth / 2, yRadius: stripeWidth / 2)
        colors[index].setFill()
        stripe.fill()
    }

    let keyRect = NSRect(x: CGFloat(size.pixels) * 0.28, y: CGFloat(size.pixels) * 0.34, width: CGFloat(size.pixels) * 0.44, height: CGFloat(size.pixels) * 0.32)
    let key = NSBezierPath(roundedRect: keyRect, xRadius: CGFloat(size.pixels) * 0.06, yRadius: CGFloat(size.pixels) * 0.06)
    NSColor.white.withAlphaComponent(0.92).setFill()
    key.fill()

    let letter = "W"
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CGFloat(size.pixels) * 0.22, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.18, alpha: 1),
        .paragraphStyle: paragraph,
    ]
    letter.draw(in: keyRect.insetBy(dx: 0, dy: CGFloat(size.pixels) * 0.025), withAttributes: attributes)

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
