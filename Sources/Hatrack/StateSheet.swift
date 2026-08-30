import AppKit

/// Renders every bar state onto one sheet, dark bar beside light bar. Used by
/// `--render-states` so the drawing can be checked without a live flight.
enum StateSheet {

    static func cases() -> [(String, BarContent)] {
        func content(_ phase: Phase?, progress: Double = 0, readout: String = "",
                     delay: String? = nil, unverified: Bool = false,
                     origin: String = "DXB", destination: String = "HND") -> BarContent {
            var c = BarContent()
            c.phase = phase
            c.flightNumber = "EK312"
            c.origin = origin
            c.destination = destination
            c.progress = progress
            c.readout = readout
            c.delayNote = delay
            c.unverified = unverified
            return c
        }

        var routeOnly = content(.inFlight, progress: 0.62, readout: "6h12m")
        routeOnly.showFlightNumber = false
        routeOnly.showReadout = false

        return [
            ("Idle", content(nil)),
            ("Scheduled", content(.scheduled, readout: "2h05m")),
            ("Delayed", content(.delayed, readout: "2h37m", delay: "+32")),
            ("Airborne", content(.inFlight, progress: 0.06, readout: "9h48m")),
            ("Cruise", content(.inFlight, progress: 0.62, readout: "6h12m")),
            ("Approach", content(.inFlight, progress: 0.94, readout: "38m")),
            ("Landed", content(.landed, progress: 1)),
            ("Out of credit", content(.inFlight, progress: 0.62, readout: "~6h10m", unverified: true)),
            ("Not found", content(.notFound, readout: "Not found", origin: "-", destination: "-")),
            ("Route only", routeOnly)
        ]
    }

    static func write(to path: String) {
        let rows = cases()
        let barHeight: CGFloat = 24
        let rowHeight: CGFloat = 46
        let labelWidth: CGFloat = 130
        let columnWidth: CGFloat = 250
        let width = labelWidth + columnWidth * 2 + 60
        let height = rowHeight * CGFloat(rows.count) + 60

        // Deliberately NOT flipped: compositing an unflipped NSImage into a
        // flipped context mirrors it. Y is measured from the bottom instead.
        let drawn = Render.png(size: CGSize(width: width, height: height), to: path) {
            NSColor(white: 0.09, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: width, height: height).fill()

            let heading: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor(white: 0.55, alpha: 1)
            ]
            ("DARK MENU BAR" as NSString).draw(
                at: CGPoint(x: labelWidth + 16, y: height - 30), withAttributes: heading)
            ("LIGHT MENU BAR" as NSString).draw(
                at: CGPoint(x: labelWidth + columnWidth + 36, y: height - 30), withAttributes: heading)

            for (index, row) in rows.enumerated() {
                let y = height - 60 - CGFloat(index) * rowHeight - barHeight
                let label: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor(white: 0.85, alpha: 1)
                ]
                (row.0 as NSString).draw(at: CGPoint(x: 16, y: y + 4), withAttributes: label)

                for (column, palette) in [BarPalette.dark, BarPalette.light].enumerated() {
                    let x = labelWidth + 16 + CGFloat(column) * (columnWidth + 20)
                    let backdrop = column == 0
                        ? NSColor(srgbRed: 0.13, green: 0.16, blue: 0.24, alpha: 1)
                        : NSColor(srgbRed: 0.87, green: 0.89, blue: 0.93, alpha: 1)
                    backdrop.setFill()
                    NSBezierPath(roundedRect: CGRect(x: x, y: y, width: columnWidth, height: barHeight),
                                 xRadius: 4, yRadius: 4).fill()

                    let barWidth = BarRenderer.size(for: row.1, palette: palette,
                                                    height: barHeight).width
                    _ = BarRenderer.draw(row.1, palette: palette,
                                         at: CGPoint(x: x + columnWidth - barWidth - 10, y: y),
                                         height: barHeight)
                }
            }

        }
        if drawn { print("wrote \(path)") }
    }
}
