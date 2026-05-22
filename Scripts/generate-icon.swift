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
]

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawStroke(_ color: NSColor, width: CGFloat, _ build: (NSBezierPath) -> Void) {
    let path = NSBezierPath()
    build(path)
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

func drawSwipeArc(side: CGFloat) {
    drawStroke(.white.withAlphaComponent(0.96), width: side * 0.055) { path in
        path.move(to: CGPoint(x: side * 0.25, y: side * 0.64))
        path.curve(
            to: CGPoint(x: side * 0.73, y: side * 0.66),
            controlPoint1: CGPoint(x: side * 0.39, y: side * 0.82),
            controlPoint2: CGPoint(x: side * 0.58, y: side * 0.82)
        )
        path.line(to: CGPoint(x: side * 0.65, y: side * 0.74))
        path.move(to: CGPoint(x: side * 0.73, y: side * 0.66))
        path.line(to: CGPoint(x: side * 0.62, y: side * 0.66))
    }
}

func drawHand(side: CGFloat) {
    let shadowOffset = side * 0.014
    let lineWidth = side * 0.042

    for offsetColor in [(shadowOffset, NSColor.black.withAlphaComponent(0.18)), (CGFloat(0), NSColor.white)] {
        let offset = offsetColor.0
        let color = offsetColor.1

        drawStroke(color, width: lineWidth) { path in
            path.move(to: CGPoint(x: side * 0.47, y: side * 0.36 - offset))
            path.line(to: CGPoint(x: side * 0.47, y: side * 0.61 - offset))
            path.curve(
                to: CGPoint(x: side * 0.54, y: side * 0.62 - offset),
                controlPoint1: CGPoint(x: side * 0.47, y: side * 0.66 - offset),
                controlPoint2: CGPoint(x: side * 0.54, y: side * 0.66 - offset)
            )
            path.line(to: CGPoint(x: side * 0.58, y: side * 0.48 - offset))
            path.move(to: CGPoint(x: side * 0.58, y: side * 0.48 - offset))
            path.line(to: CGPoint(x: side * 0.64, y: side * 0.46 - offset))
            path.move(to: CGPoint(x: side * 0.64, y: side * 0.46 - offset))
            path.line(to: CGPoint(x: side * 0.70, y: side * 0.44 - offset))
            path.move(to: CGPoint(x: side * 0.47, y: side * 0.36 - offset))
            path.curve(
                to: CGPoint(x: side * 0.68, y: side * 0.28 - offset),
                controlPoint1: CGPoint(x: side * 0.50, y: side * 0.25 - offset),
                controlPoint2: CGPoint(x: side * 0.63, y: side * 0.24 - offset)
            )
            path.curve(
                to: CGPoint(x: side * 0.73, y: side * 0.43 - offset),
                controlPoint1: CGPoint(x: side * 0.72, y: side * 0.32 - offset),
                controlPoint2: CGPoint(x: side * 0.74, y: side * 0.38 - offset)
            )
        }
    }
}

for size in sizes {
    let side = CGFloat(size.pixels)
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size.pixels,
            pixelsHigh: size.pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        fatalError("Could not create bitmap for \(size.name)")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))

    let iconRect = CGRect(x: side * 0.055, y: side * 0.055, width: side * 0.89, height: side * 0.89)
    let background = roundedRect(iconRect, radius: side * 0.22)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.03, green: 0.36, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.18, green: 0.78, blue: 0.93, alpha: 1),
    ])?.draw(in: background, angle: 135)

    let highlight = NSBezierPath(ovalIn: CGRect(x: side * 0.20, y: side * 0.18, width: side * 0.60, height: side * 0.60))
    NSColor.white.withAlphaComponent(0.14).setFill()
    highlight.fill()

    drawSwipeArc(side: side)
    drawHand(side: side)

    NSColor.white.withAlphaComponent(0.20).setStroke()
    background.lineWidth = side * 0.012
    background.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render \(size.name)")
    }

    try png.write(to: outputURL.appendingPathComponent(size.name))
}
