import AppKit

/// The app icon: the widget's own mark, seen through a cabin window.
///
/// Drawn rather than authored, from the same aircraft path the menu bar uses,
/// so the icon cannot drift from the thing it represents.
enum AppIcon {

    static let white = NSColor(white: 1, alpha: 0.96)

    static func draw(in r: CGRect) {
        let s = r.width
        let squircle = NSBezierPath(roundedRect: r, xRadius: s * 0.225, yRadius: s * 0.225)

        // fuselage
        NSGraphicsContext.saveGraphicsState()
        squircle.setClip()
        NSGradient(starting: NSColor(white: 0.21, alpha: 1),
                   ending: NSColor(white: 0.09, alpha: 1))?.draw(in: r, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // the port
        let inset: CGFloat = 0.24
        let p = CGRect(x: r.minX + s * inset, y: r.minY + s * (inset - 0.06),
                       width: s * (1 - inset * 2), height: s * (1 - (inset - 0.06) * 2))
        let glass = NSBezierPath(roundedRect: p, xRadius: p.width * 0.46, yRadius: p.width * 0.46)

        NSGraphicsContext.saveGraphicsState()
        glass.setClip()
        NSGradient(starting: NSColor(srgbRed: 0.03, green: 0.09, blue: 0.28, alpha: 1),
                   ending: NSColor(srgbRed: 0.30, green: 0.58, blue: 0.98, alpha: 1))?
            .draw(in: p, angle: 90)

        // the track, running out past the glass as though it continues beyond
        let y = p.minY + p.height * 0.52
        let start = CGPoint(x: p.minX - s * 0.04, y: y)
        let end = CGPoint(x: p.maxX + s * 0.04, y: y)
        let at = CGPoint(x: start.x + (end.x - start.x) * 0.56, y: y)

        func stroke(_ a: CGPoint, _ b: CGPoint, _ color: NSColor,
                    width: CGFloat, dash: [CGFloat]? = nil) {
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineWidth = width
            path.lineCapStyle = .round
            if let dash { path.setLineDash(dash, count: dash.count, phase: 0) }
            color.setStroke()
            path.stroke()
        }

        stroke(at, end, NSColor(white: 1, alpha: 0.45), width: s * 0.032,
               dash: [s * 0.04, s * 0.05])
        stroke(start, at, white, width: s * 0.035)

        let plane = BarRenderer.planePath(at: .zero)
        let scale = (s * 0.20) / BarMetrics.planeWidth
        plane.transform(using: AffineTransform(scaleByX: scale, byY: scale))
        plane.transform(using: AffineTransform(translationByX: at.x, byY: at.y))
        white.setFill()
        plane.fill()
        NSGraphicsContext.restoreGraphicsState()

        // bezel
        glass.lineWidth = s * 0.032
        NSColor(white: 1, alpha: 0.28).setStroke()
        glass.stroke()
    }

    /// Writes the .iconset macOS expects; `iconutil` turns it into an .icns.
    static let sizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
        ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
        ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
        ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
        ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
        ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2)
    ]

    static func writeIconset(to directory: String) {
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for entry in sizes {
            let pixels = entry.points * entry.scale
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            rep.size = NSSize(width: pixels, height: pixels)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url.appendingPathComponent("\(entry.name).png"))
            }
        }
        print("wrote \(directory)")
    }

    /// A preview sheet: full size beside the sizes that actually get used.
    static func writePreview(to path: String) {
        let large: CGFloat = 300
        let row: [CGFloat] = [128, 64, 32, 16]
        let width = large + 40 + row.reduce(0, +) + CGFloat(row.count) * 24
        let height = large + 60

        _ = Render.png(size: CGSize(width: width, height: height), to: path) {
            NSColor(white: 0.13, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: width, height: height).fill()
            draw(in: CGRect(x: 30, y: height - large - 30, width: large, height: large))
            var x = large + 60
            for size in row {
                draw(in: CGRect(x: x, y: height - 30 - size, width: size, height: size))
                ("\(Int(size))pt" as NSString).draw(
                    at: CGPoint(x: x, y: height - 30 - size - 18),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                     .foregroundColor: NSColor(white: 0.5, alpha: 1)])
                x += size + 24
            }
        }
    }
}
