import AppKit
import SwiftUI

/// Renders the dropdown offscreen: normal beside out-of-credit. Lets the panel
/// be checked without a live flight, a key, or screen recording permission.
enum PanelSheet {

    private static func snapshot(now: Date) -> FlightSnapshot {
        FlightSnapshot(
            number: "EK312",
            origin: Airport(iata: "DXB", timeZoneID: "Asia/Dubai"),
            destination: Airport(iata: "HND", timeZoneID: "Asia/Tokyo"),
            scheduledDeparture: now.addingTimeInterval(-6.2 * 3600),
            revisedDeparture: nil,
            actualDeparture: now.addingTimeInterval(-6.2 * 3600),
            scheduledArrival: now.addingTimeInterval(3.8 * 3600),
            predictedArrival: nil,
            actualArrival: nil,
            aircraft: "777-300ER",
            registration: "JA784A",
            providerStatus: "EnRoute",
            fetchedAt: now.addingTimeInterval(-14 * 60)
        )
    }

    @MainActor
    private static func render(_ coordinator: Coordinator) -> NSImage? {
        let host = NSHostingView(rootView: PanelView(coordinator: coordinator))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return Render.image(of: host)
    }

    @MainActor
    static func write(to path: String) {
        let now = Date()

        var normal = PersistedState.fresh(now: now)
        normal.trackedNumber = "EK312"
        normal.snapshot = snapshot(now: now)
        normal.quota = QuotaLedger(monthKey: QuotaLedger.key(for: now), units: 186)
        normal.nextPoll = now.addingTimeInterval(76 * 60)

        var spent = normal
        spent.quota = QuotaLedger(monthKey: QuotaLedger.key(for: now), units: 600)
        spent.nextPoll = now.addingTimeInterval(-40 * 60)   // overdue, so it reads as estimated

        let panels = [
            ("In flight", Coordinator(preview: normal, now: now)),
            ("Out of credit", Coordinator(preview: spent, now: now))
        ].compactMap { label, coordinator -> (String, NSImage)? in
            guard let image = render(coordinator) else { return nil }
            return (label, image)
        }
        guard !panels.isEmpty else {
            FileHandle.standardError.write(Data("could not render panels\n".utf8))
            return
        }

        let pad: CGFloat = 26
        let gap: CGFloat = 30
        let tallest = panels.map(\.1.size.height).max() ?? 0
        let width = pad * 2 + panels.map(\.1.size.width).reduce(0, +) + gap * CGFloat(panels.count - 1)
        let height = tallest + pad * 2 + 26

        _ = Render.png(size: CGSize(width: width, height: height), to: path) {
            NSColor(srgbRed: 0.14, green: 0.17, blue: 0.26, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: width, height: height).fill()

            var x = pad
            for (label, image) in panels {
                let y = height - pad - 26 - image.size.height
                // popover-ish backing so the panel reads as a floating window
                let card = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: image.size.width,
                                                            height: image.size.height),
                                        xRadius: 11, yRadius: 11)
                NSColor(white: 0.13, alpha: 0.96).setFill()
                card.fill()
                image.draw(at: CGPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1)

                (label as NSString).draw(at: CGPoint(x: x, y: height - pad - 16), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor(white: 0.6, alpha: 1)
                ])
                x += image.size.width + gap
            }
        }
        print("wrote \(path)")
    }
}
