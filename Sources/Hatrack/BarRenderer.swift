import AppKit
import CoreText

/// Everything the menu bar item needs to draw itself.
struct BarContent {
    var phase: Phase?          // nil = idle, nothing tracked
    var flightNumber: String = ""
    var origin: String = ""
    var destination: String = ""
    var progress: Double = 0
    var readout: String = ""
    var delayNote: String?     // "+32" beside a delayed countdown
    var unverified: Bool = false
    var showFlightNumber: Bool = true
    var showAirports: Bool = true
    var showReadout: Bool = true
}

/// Colours for one menu bar appearance. macOS does not tint a non-template
/// image, so the palette has to be chosen for the bar we are actually sitting on.
struct BarPalette {
    let text: NSColor
    let muted: NSColor
    let idleTrack: NSColor
    let blue: NSColor
    let green: NSColor
    let amber: NSColor

    static let dark = BarPalette(
        text: NSColor(white: 1, alpha: 0.92),
        muted: NSColor(white: 1, alpha: 0.62),
        idleTrack: NSColor(white: 1, alpha: 0.32),
        blue: NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1),      // #0A84FF
        green: NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1),   // #30D158
        amber: NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)      // #FF9F0A
    )

    static let light = BarPalette(
        text: NSColor(white: 0, alpha: 0.88),
        muted: NSColor(white: 0, alpha: 0.62),
        idleTrack: NSColor(white: 0, alpha: 0.30),
        blue: NSColor(srgbRed: 0.0, green: 0.443, blue: 0.890, alpha: 1),      // #0071E3
        green: NSColor(srgbRed: 0.114, green: 0.541, blue: 0.247, alpha: 1),   // #1D8A3F
        amber: NSColor(srgbRed: 0.698, green: 0.314, blue: 0.0, alpha: 1)      // #B25000
    )
}

enum BarMetrics {
    static let gap: CGFloat = 6
    /// Three dash periods shorter than it started: the track shows proportion,
    /// not precision, and every point here is menu bar real estate.
    static let trackWidth: CGFloat = 40
    static let stroke: CGFloat = 1.5
    static let dash: [CGFloat] = [2, 2.6]
    static let planeWidth: CGFloat = 11.5
    static let planeHeight: CGFloat = 9
    static let landedDotRadius: CGFloat = 2.3
    /// Alone in the bar the aircraft has no text to sit against, so it carries
    /// the whole item and is drawn larger than the one riding the track.
    static let idleScale: CGFloat = 1.5
    /// Half the glyph, so neither nose nor tail ever crosses the track's ends.
    static var planeClamp: CGFloat { planeWidth / 2 + 0.15 }
}

enum BarRenderer {

    // MARK: fonts

    private static func tabular(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static let flightFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let airportFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static var readoutFont: NSFont { tabular(.systemFont(ofSize: 11.5, weight: .medium)) }

    // MARK: layout

    private struct Piece {
        var text: String
        var font: NSFont
        var color: NSColor
    }

    private static func pieces(_ c: BarContent, _ p: BarPalette) -> (lead: [Piece], trail: [Piece]) {
        var lead: [Piece] = []
        var trail: [Piece] = []

        if c.showFlightNumber, !c.flightNumber.isEmpty {
            lead.append(Piece(text: c.flightNumber, font: flightFont, color: p.text))
        }
        if c.showAirports {
            lead.append(Piece(text: c.origin, font: airportFont, color: p.muted))
            trail.append(Piece(text: c.destination, font: airportFont, color: p.muted))
        }

        if c.showReadout, !c.readout.isEmpty {
            let color: NSColor
            switch c.phase {
            case .delayed: color = p.amber
            case .notFound: color = p.muted
            default: color = c.unverified ? p.amber : p.text.withAlphaComponent(0.82)
            }
            var text = c.readout
            if let note = c.delayNote { text += " " + note }
            trail.append(Piece(text: text, font: readoutFont, color: color))
        }
        return (lead, trail)
    }

    private static func width(_ piece: Piece) -> CGFloat {
        (piece.text as NSString).size(withAttributes: [.font: piece.font]).width
    }

    static func size(for content: BarContent, palette: BarPalette, height: CGFloat) -> CGSize {
        guard content.phase != nil else {
            return CGSize(width: (BarMetrics.planeWidth * BarMetrics.idleScale) + 7, height: height)
        }
        let (lead, trail) = pieces(content, palette)
        var w: CGFloat = 0
        for piece in lead { w += width(piece) + BarMetrics.gap }
        w += BarMetrics.trackWidth + BarMetrics.gap
        if content.unverified { w += 5 + BarMetrics.gap }   // the amber dot
        for (i, piece) in trail.enumerated() {
            w += width(piece)
            if i < trail.count - 1 { w += BarMetrics.gap }
        }
        return CGSize(width: ceil(w), height: height)
    }

    // MARK: drawing

    static func image(for content: BarContent, palette: BarPalette, height: CGFloat) -> NSImage {
        let size = size(for: content, palette: palette, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(content, palette: palette, in: size)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws a bar directly into the current context at `origin`. Going through
    /// an NSImage first bakes it at that image's resolution, which is why the
    /// documentation sheets were soft.
    static func draw(_ content: BarContent, palette: BarPalette,
                     at origin: CGPoint, height: CGFloat) -> CGFloat {
        let size = size(for: content, palette: palette, height: height)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        transform.concat()
        draw(content, palette: palette, in: size)
        NSGraphicsContext.restoreGraphicsState()
        return size.width
    }

    private static func draw(_ content: BarContent, palette p: BarPalette, in size: CGSize) {
        let midY = (size.height / 2).rounded()

        guard let phase = content.phase else {
            // Idle: the glyph alone, drawn larger since nothing else is there.
            let scale = BarMetrics.idleScale
            let path = planePath(at: .zero)
            path.transform(using: AffineTransform(scaleByX: scale, byY: scale))
            path.transform(using: AffineTransform(
                translationByX: (BarMetrics.planeWidth * scale) / 2 + 3.5, byY: midY))
            p.text.withAlphaComponent(0.75).setFill()
            path.fill()
            return
        }

        let (lead, trail) = pieces(content, p)
        var x: CGFloat = 0

        for piece in lead {
            drawText(piece, at: &x, midY: midY)
            x += BarMetrics.gap
        }

        drawTrack(content, phase: phase, palette: p, originX: x, midY: midY)
        x += BarMetrics.trackWidth + BarMetrics.gap

        // Destination first, then the credit dot, then the readout: the dot
        // belongs with the number it qualifies, not with the track.
        func creditDot() {
            let r: CGFloat = 2.5
            p.amber.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: midY - r, width: r * 2, height: r * 2)).fill()
            x += r * 2 + BarMetrics.gap
        }
        if content.unverified, !content.showAirports { creditDot() }
        for (i, piece) in trail.enumerated() {
            drawText(piece, at: &x, midY: midY)
            if i == 0, content.unverified, content.showAirports {
                x += BarMetrics.gap
                creditDot()
                x -= BarMetrics.gap
            }
            if i < trail.count - 1 { x += BarMetrics.gap }
        }
    }

    private static func drawText(_ piece: Piece, at x: inout CGFloat, midY: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: piece.font, .foregroundColor: piece.color]
        let string = piece.text as NSString
        let size = string.size(withAttributes: attributes)
        // Centre on the cap height rather than the line box, so text and track align.
        let y = midY - size.height / 2 + (piece.font.descender / 2) + 1
        string.draw(at: CGPoint(x: x, y: y.rounded()), withAttributes: attributes)
        x += size.width
    }

    private static func drawTrack(_ content: BarContent, phase: Phase, palette p: BarPalette,
                                  originX: CGFloat, midY: CGFloat) {
        let W = BarMetrics.trackWidth
        let accent: NSColor = phase == .landed ? p.green : p.blue
        let progress = min(max(content.progress, 0), 1)
        let x = originX + W * progress

        func line(from: CGFloat, to: CGFloat, color: NSColor, dash: [CGFloat]?) {
            guard to > from else { return }
            let path = NSBezierPath()
            path.move(to: CGPoint(x: from, y: midY))
            path.line(to: CGPoint(x: to, y: midY))
            path.lineWidth = BarMetrics.stroke
            path.lineCapStyle = .round
            if let dash { path.setLineDash(dash, count: dash.count, phase: 0) }
            color.setStroke()
            path.stroke()
        }

        switch phase {
        case .landed:
            let dotX = originX + W - BarMetrics.landedDotRadius
            line(from: originX, to: dotX, color: accent, dash: nil)
            accent.setFill()
            NSBezierPath(ovalIn: CGRect(x: dotX - BarMetrics.landedDotRadius,
                                        y: midY - BarMetrics.landedDotRadius,
                                        width: BarMetrics.landedDotRadius * 2,
                                        height: BarMetrics.landedDotRadius * 2)).fill()
            return

        case .scheduled, .delayed, .notFound:
            line(from: originX, to: originX + W, color: p.idleTrack, dash: BarMetrics.dash)
            // a small dot marks the origin the aircraft is still sitting at
            p.idleTrack.setFill()
            NSBezierPath(ovalIn: CGRect(x: originX - 0.2, y: midY - 1.6, width: 3.2, height: 3.2)).fill()

        case .inFlight:
            line(from: x, to: originX + W, color: p.idleTrack, dash: BarMetrics.dash)
            line(from: originX, to: x, color: accent,
                 dash: content.unverified ? [1, 2] : nil)
        }

        // aircraft, clamped so it can never clip at either end
        let clamp = BarMetrics.planeClamp
        let planeX = min(max(x, originX + clamp), originX + W - clamp)
        let path = planePath(at: CGPoint(x: planeX, y: midY))
        switch phase {
        case .scheduled, .delayed, .notFound:
            p.muted.setFill()
            path.fill()
        case .inFlight:
            if content.unverified {
                accent.setStroke()
                path.lineWidth = 0.9
                path.lineJoinStyle = .round
                path.stroke()
            } else {
                accent.setFill()
                path.fill()
            }
        case .landed:
            break
        }
    }

    /// Airliner seen from above, nose to the right, centred on `point`.
    static func planePath(at point: CGPoint) -> NSBezierPath {
        // (x, y) with y measured up from the centreline
        let points: [(CGFloat, CGFloat)] = [
            (11.5, 0), (6.5, -1.5), (4.5, -4.5), (3.2, -4.5), (4.2, -1.9),
            (1.6, -2.4), (0.6, -3.7), (0, -3.7), (0.6, 0), (0, 3.7),
            (0.6, 3.7), (1.6, 2.4), (4.2, 1.9), (3.2, 4.5), (4.5, 4.5), (6.5, 1.5)
        ]
        let path = NSBezierPath()
        let originX = point.x - BarMetrics.planeWidth / 2
        for (i, pt) in points.enumerated() {
            let p = CGPoint(x: originX + pt.0, y: point.y + pt.1)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }
}
