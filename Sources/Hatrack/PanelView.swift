import SwiftUI

/// The route line inside the dropdown: same idea as the menu bar track, drawn
/// larger. Flown portion solid, remaining dashed, aircraft riding the boundary.
struct RouteLine: View {
    var progress: Double
    var phase: Phase
    var unverified: Bool

    var accent: Color {
        phase == .landed ? Color(nsColor: BarPalette.dark.green)
                         : Color(nsColor: BarPalette.dark.blue)
    }

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let clamped = min(max(progress, 0), 1)
            let x = size.width * clamped
            let faint = Color.white.opacity(0.28)

            if phase == .landed {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: midY))
                line.addLine(to: CGPoint(x: size.width - 3, y: midY))
                context.stroke(line, with: .color(accent), style: .init(lineWidth: 2, lineCap: .round))
                context.fill(
                    Path(ellipseIn: CGRect(x: size.width - 6, y: midY - 3, width: 6, height: 6)),
                    with: .color(accent))
                return
            }

            var ahead = Path()
            ahead.move(to: CGPoint(x: x, y: midY))
            ahead.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(ahead, with: .color(faint),
                           style: .init(lineWidth: 2, lineCap: .round, dash: [2.6, 3.4]))

            if phase == .inFlight, x > 1 {
                var flown = Path()
                flown.move(to: CGPoint(x: 0, y: midY))
                flown.addLine(to: CGPoint(x: x, y: midY))
                context.stroke(flown, with: .color(accent),
                               style: .init(lineWidth: 2, lineCap: .round,
                                            dash: unverified ? [1.4, 2.6] : []))
            }

            let clamp: CGFloat = 7
            let planeX = min(max(x, clamp), size.width - clamp)
            let plane = Path(BarRenderer.planePath(at: CGPoint(x: planeX, y: midY)).cgPath)
            let colour = phase == .inFlight ? accent : Color.white.opacity(0.6)
            if unverified {
                context.stroke(plane, with: .color(colour), lineWidth: 1)
            } else {
                context.fill(plane, with: .color(colour))
            }
        }
        .frame(height: 14)
    }
}

struct PanelView: View {
    @ObservedObject var coordinator: Coordinator
    @State private var entry = ""
    @State private var keyEntry = ""
    @State private var showingKeyField = false

    /// Track and Save sit in stacked rows, so they share a width and the text
    /// fields beside them end on the same edge.
    private let actionButtonWidth: CGFloat = 52

    private var snapshot: FlightSnapshot? { coordinator.snapshot }
    private var now: Date { coordinator.now }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if coordinator.isResolving {
                resolving
            } else if let candidates = coordinator.candidates {
                picker(candidates)
            } else if let snapshot {
                header(snapshot)
                if coordinator.unverified || coordinator.quotaExhausted { quotaBanner }
                route(snapshot)
                Divider().opacity(0.5)
                details(snapshot)
            } else {
                empty
            }

            Divider().opacity(0.5)
            quotaMeter
            Divider().opacity(0.5)
            controls
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 11, trailing: 15))
        .frame(width: 296)
    }

    // MARK: pieces

    private func header(_ s: FlightSnapshot) -> some View {
        let phase = s.phase(at: now)
        return HStack(alignment: .firstTextBaseline) {
            Text(s.number.isEmpty ? (coordinator.state.trackedNumber ?? "") : s.number)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(statusLabel(phase))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(statusColor(phase))
        }
    }

    private func statusLabel(_ phase: Phase) -> String {
        guard let s = snapshot else { return "" }
        let pct = Int((s.progress(at: now) * 100).rounded())
        switch phase {
        case .scheduled: return "Scheduled"
        case .delayed: return "Delayed +\(s.delayMinutes)"
        case .inFlight: return coordinator.unverified ? "Estimated · \(pct)%" : "In flight · \(pct)%"
        case .landed: return "Landed"
        case .notFound: return "Not found"
        }
    }

    private func statusColor(_ phase: Phase) -> Color {
        if coordinator.unverified { return Color(nsColor: BarPalette.dark.amber) }
        switch phase {
        case .landed: return Color(nsColor: BarPalette.dark.green)
        case .delayed: return Color(nsColor: BarPalette.dark.amber)
        case .inFlight: return Color(nsColor: BarPalette.dark.blue)
        default: return .secondary
        }
    }

    private var quotaBanner: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
            Text("Out of API units. Times below are estimates, not live.")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(nsColor: BarPalette.dark.amber))
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: BarPalette.dark.amber).opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: BarPalette.dark.amber).opacity(0.34), lineWidth: 0.5))
    }

    private func route(_ s: FlightSnapshot) -> some View {
        let phase = s.phase(at: now)
        let estimated = coordinator.unverified
        return HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.origin.iata).font(.system(size: 15, weight: .semibold))
                Text("Dep \(Format.clock(s.departure, in: s.origin.timeZone))"
                     + (s.actualDeparture != nil ? " · actual" : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            RouteLine(progress: s.progress(at: now), phase: phase, unverified: estimated)
                .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 2) {
                Text(s.destination.iata).font(.system(size: 15, weight: .semibold))
                Text("Arr \(estimated ? "~" : "")\(Format.clock(s.arrival, in: s.destination.timeZone))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func details(_ s: FlightSnapshot) -> some View {
        let phase = s.phase(at: now)
        return VStack(spacing: 6) {
            switch phase {
            case .inFlight:
                row("Remaining", (coordinator.unverified ? "~" : "")
                    + Format.untilArrival(s.arrival.timeIntervalSince(now)))
            case .scheduled, .delayed:
                row("Departs in", Format.untilDeparture(s.departure.timeIntervalSince(now)))
            case .landed:
                row("Landed", Format.clock(s.arrival, in: s.destination.timeZone))
            case .notFound:
                EmptyView()
            }
            if let aircraft = s.aircraft {
                row("Aircraft", [aircraft, s.registration].compactMap { $0 }.joined(separator: " · "))
            }
            row(coordinator.unverified ? "Last verified" : "Last refresh", Format.ago(s.fetchedAt, now: now))
            if let next = coordinator.state.nextPoll, !coordinator.quotaExhausted, phase != .landed {
                let due = next.timeIntervalSince(now)
                row("Next check", due <= 0 ? "any moment" : Format.duration(due))
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No flight tracked").font(.system(size: 13, weight: .medium))
            Text(coordinator.lastError ?? "Enter a flight number to follow its progress in the menu bar.")
                .font(.system(size: 11.5))
                .foregroundStyle(coordinator.lastError == nil ? .secondary : Color(nsColor: BarPalette.dark.amber))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: date picker

    private var resolving: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Finding \(coordinator.pendingNumber ?? "flights")…")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// The mandatory pick: one row per operating day, tap to track. No silent
    /// default - even a single option is presented for an explicit tap.
    private func picker(_ candidates: [FlightSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(coordinator.pendingNumber ?? "").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { coordinator.cancelPicking() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if candidates.isEmpty {
                Text("No \(coordinator.pendingNumber ?? "flight") departures in the next 4 days.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: BarPalette.dark.amber))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(candidates.count == 1 ? "One departure - tap to track it"
                                           : "Choose which departure to track")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                VStack(spacing: 5) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { _, s in
                        pickerRow(s)
                    }
                }
            }
        }
    }

    private func pickerRow(_ s: FlightSnapshot) -> some View {
        Button { coordinator.commit(s) } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(dayLabel(s)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(Format.day(s.scheduledDeparture))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 52, alignment: .leading)
                Text("\(s.origin.iata)→\(s.destination.iata)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.clock(s.scheduledDeparture, in: s.origin.timeZone))
                    .font(.system(size: 12)).monospacedDigit()
                statusPill(s)
            }
            .padding(.vertical, 6).padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Today" for today, otherwise a short weekday ("Thu") - kept narrow so the
    /// row never wraps at 296 pt.
    private func dayLabel(_ s: FlightSnapshot) -> String {
        let dep = s.scheduledDeparture
        if Calendar.current.isDateInToday(dep) { return "Today" }
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: dep)
    }

    private func statusPill(_ s: FlightSnapshot) -> some View {
        let phase = s.phase(at: now)
        let text: String
        let tint: Color
        switch phase {
        case .delayed: text = "+\(s.delayMinutes)"; tint = Color(nsColor: BarPalette.dark.amber)
        case .inFlight: text = "In flight"; tint = Color(nsColor: BarPalette.dark.blue)
        case .landed: text = "Landed"; tint = Color(nsColor: BarPalette.dark.green)
        default: text = "Sched"; tint = Color.white.opacity(0.6)
        }
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(phase == .scheduled ? Color.white.opacity(0.08) : tint.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 5))
    }

    private var quotaMeter: some View {
        let used = coordinator.quota.units
        let cap = coordinator.preferences.monthlyUnitCap
        let fraction = cap > 0 ? min(Double(used) / Double(cap), 1) : 0
        let spent = coordinator.quotaExhausted
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("API units, \(monthName)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(used) / \(cap)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(spent ? Color(nsColor: BarPalette.dark.amber) : .primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule()
                        .fill(spent ? Color(nsColor: BarPalette.dark.amber) : Color(nsColor: BarPalette.dark.green))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
            if spent {
                HStack {
                    Text("Resets").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(resetLabel).font(.system(size: 12)).monospacedDigit()
                }
            }
        }
    }

    private var monthName: String {
        let f = DateFormatter()
        f.dateFormat = "LLLL"
        return f.string(from: now)
    }

    private var resetLabel: String {
        let f = DateFormatter()
        f.dateFormat = "d MMMM"
        return f.string(from: coordinator.quota.resetDate(now: now))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                TextField("Track a flight number", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(submit)
                Button("Track", action: submit)
                    .font(.system(size: 12))
                    .frame(width: actionButtonWidth)
                    .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !coordinator.hasAPIKey || showingKeyField {
                HStack(spacing: 6) {
                    SecureField("AeroDataBox RapidAPI key", text: $keyEntry)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("Save") {
                        coordinator.saveAPIKey(keyEntry)
                        keyEntry = ""
                        showingKeyField = false
                    }
                    .font(.system(size: 12))
                    .frame(width: actionButtonWidth)
                }
            }

            Toggle("Show flight number", isOn: Binding(
                get: { coordinator.preferences.showFlightNumber },
                set: { coordinator.preferences.showFlightNumber = $0 }))
            Toggle("Show time left", isOn: Binding(
                get: { coordinator.preferences.showTimeLeft },
                set: { coordinator.preferences.showTimeLeft = $0 }))
            if !hiddenToFit.isEmpty {
                Text("Menu bar is full - hiding \(hiddenToFit) to fit.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: BarPalette.dark.amber))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Check 2h before departure", isOn: Binding(
                get: { coordinator.preferences.preDepartureCheck },
                set: { coordinator.preferences.preDepartureCheck = $0 }))
            .help("Costs one extra call per flight, warns you of a delay before you leave.")

            HStack {
                if coordinator.snapshot != nil {
                    Button("Stop tracking") { coordinator.clearFlight() }
                        .font(.system(size: 12))
                }
                Spacer()
                Button("API key") { showingKeyField.toggle() }
                    .font(.system(size: 12))
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 12))
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    /// What the menu bar is dropping right now that the user asked to see.
    private var hiddenToFit: String {
        let level = coordinator.fitShedLevel
        var names: [String] = []
        if level >= 3, coordinator.preferences.showFlightNumber { names.append("the flight number") }
        if level >= 2 { names.append("the airport codes") }
        if level >= 1, coordinator.preferences.showTimeLeft { names.append("the time left") }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12)).monospacedDigit()
        }
    }

    private func submit() {
        let number = entry
        entry = ""
        Task { await coordinator.resolve(number) }
    }
}

extension NSBezierPath {
    /// AppKit's path has no cgPath before macOS 14's `cgPath` on some SDKs; this
    /// conversion keeps the aircraft glyph shared between the bar and the panel.
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
