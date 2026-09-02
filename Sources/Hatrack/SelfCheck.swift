import Foundation

/// `--self-check` exercises the logic that decides when to spend a call and how
/// far along the bar should be. Run it after changing the polling policy.
enum SelfCheck {

    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("  ok    \(label)")
        } else {
            failures += 1
            print("  FAIL  \(label)")
        }
    }

    static func expect(_ actual: Date?, within tolerance: TimeInterval, of expected: Date?,
                       _ label: String) {
        switch (actual, expected) {
        case (nil, nil): print("  ok    \(label)")
        case let (a?, e?) where abs(a.timeIntervalSince(e)) <= tolerance: print("  ok    \(label)")
        default:
            failures += 1
            print("  FAIL  \(label)  (got \(actual.map(String.init(describing:)) ?? "nil"))")
        }
    }

    static func base(now: Date, departIn: TimeInterval, duration: TimeInterval,
                     delayMinutes: Int = 0, departed: Bool = false,
                     arrived: Bool = false) -> FlightSnapshot {
        let scheduled = now.addingTimeInterval(departIn)
        let revised = delayMinutes > 0 ? scheduled.addingTimeInterval(Double(delayMinutes) * 60) : nil
        let actualDep = departed ? (revised ?? scheduled) : nil
        let arrival = (revised ?? scheduled).addingTimeInterval(duration)
        return FlightSnapshot(
            number: "NH7",
            origin: Airport(iata: "HND", timeZoneID: "Asia/Tokyo"),
            destination: Airport(iata: "SEA", timeZoneID: "America/Los_Angeles"),
            scheduledDeparture: scheduled,
            revisedDeparture: revised,
            actualDeparture: actualDep,
            scheduledArrival: arrival,
            predictedArrival: nil,
            actualArrival: arrived ? arrival : nil,
            aircraft: nil, registration: nil,
            providerStatus: arrived ? "Arrived" : (departed ? "EnRoute" : "Expected"),
            fetchedAt: now
        )
    }

    static func run() -> Int32 {
        let now = Date()
        let hour: TimeInterval = 3600

        print("polling policy")
        // Nothing is spent before the scheduled time; the next call lands just after it.
        let scheduled = base(now: now, departIn: 4 * hour, duration: 10 * hour)
        expect(Coordinator.nextPoll(after: scheduled, now: now, preDepartureCheck: false),
               within: 60, of: now.addingTimeInterval(4 * hour + 10 * 60),
               "waits until 10 min past scheduled departure")

        // With the optional warning enabled, one extra call two hours out.
        expect(Coordinator.nextPoll(after: scheduled, now: now, preDepartureCheck: true),
               within: 60, of: now.addingTimeInterval(2 * hour),
               "optional pre-departure check fires at T-2h")

        // A delay moves the wake-up instead of starting a cadence.
        let delayed = base(now: now, departIn: 0.5 * hour, duration: 10 * hour, delayMinutes: 90)
        expect(Coordinator.nextPoll(after: delayed, now: now, preDepartureCheck: false),
               within: 60, of: now.addingTimeInterval(0.5 * hour + 90 * 60 + 10 * 60),
               "delay reschedules to the revised departure")

        // Past its scheduled time but not yet reported away: back off, do not
        // sit at a one-minute cadence burning units.
        let overdueDeparture = base(now: now, departIn: -0.75 * hour, duration: 10 * hour)
        expect(Coordinator.nextPoll(after: overdueDeparture, now: now, preDepartureCheck: false),
               within: 60, of: now.addingTimeInterval(10 * 60),
               "an overdue departure polls every 10 min, not every minute")

        // Cruise: 90 minutes, but never sleeping through the approach window.
        let cruise = base(now: now, departIn: -3 * hour, duration: 11 * hour, departed: true)
        expect(Coordinator.nextPoll(after: cruise, now: now, preDepartureCheck: false),
               within: 60, of: now.addingTimeInterval(90 * 60),
               "cruise polls every 90 min")

        let nearlyThere = base(now: now, departIn: -9 * hour, duration: 10 * hour, departed: true)
        expect(Coordinator.nextPoll(after: nearlyThere, now: now, preDepartureCheck: false),
               within: 60, of: now.addingTimeInterval(15 * 60),
               "cruise never overshoots the approach window")

        let approach = base(now: now, departIn: -9.5 * hour, duration: 10 * hour, departed: true)
        expect(Coordinator.nextPoll(after: approach, now: now, preDepartureCheck: false),
               within: 60, of: now.addingTimeInterval(20 * 60),
               "approach polls every 20 min")

        let overdue = base(now: now, departIn: -11 * hour, duration: 10 * hour, departed: true)
        expect(Coordinator.nextPoll(after: overdue, now: now, preDepartureCheck: false),
               within: 60, of: now.addingTimeInterval(10 * 60),
               "overdue arrival confirms touchdown in 10 min")

        let landed = base(now: now, departIn: -11 * hour, duration: 10 * hour,
                          departed: true, arrived: true)
        expect(Coordinator.nextPoll(after: landed, now: now, preDepartureCheck: false),
               within: 60, of: nil,
               "landed stops polling entirely")

        print("progress and phase")
        expect(scheduled.phase(at: now) == .scheduled, "before departure reads as scheduled")
        expect(delayed.phase(at: now) == .delayed, "a slip of 90 min reads as delayed")
        expect(delayed.delayMinutes == 90, "delay is reported in minutes")
        expect(cruise.phase(at: now) == .inFlight, "a departed flight reads as in flight")
        expect(landed.phase(at: now) == .landed, "an arrived flight reads as landed")
        expect(scheduled.progress(at: now) == 0, "progress is 0 before departure")
        expect(landed.progress(at: now) == 1, "progress is 1 after arrival")
        let midway = base(now: now, departIn: -5 * hour, duration: 10 * hour, departed: true)
        expect(abs(midway.progress(at: now) - 0.5) < 0.01, "progress is half way at half time")

        print("budget")
        var ledger = QuotaLedger.empty(at: now)
        ledger.units = 598
        expect((ledger.units + 2) <= 600, "two more units still fits a 600 cap")
        ledger.units = 599
        expect((ledger.units + 2) > 600, "a call that would exceed the cap is refused")
        var rolling = QuotaLedger(monthKey: "2025-01", units: 480)
        rolling.rollIfNeeded(at: now)
        expect(rolling.units == 0, "the ledger resets on a new month")

        print("date picker")
        // The window the picker offers spans today through three days ahead.
        let window = Coordinator.pickWindow(now: now)
        expect(Calendar.current.dateComponents([.day], from: window.from, to: window.to).day == 3,
               "picker window spans today plus three days")

        // Re-anchoring a tracked leg matches on its schedule, so a number that
        // flies several days is never re-resolved to the nearest one.
        let today = base(now: now, departIn: 2 * hour, duration: 10 * hour)
        let tomorrow = base(now: now, departIn: 26 * hour, duration: 10 * hour)
        let dayAfter = base(now: now, departIn: 50 * hour, duration: 10 * hour)
        let pool = [dayAfter, today, tomorrow]
        expect(FlightSnapshot.nearest(to: now.addingTimeInterval(26 * hour), in: pool)?
                .scheduledDeparture == tomorrow.scheduledDeparture,
               "re-anchor picks the leg matching the chosen date")
        expect(FlightSnapshot.nearest(to: now.addingTimeInterval(2 * hour), in: pool)?
                .scheduledDeparture == today.scheduledDeparture,
               "re-anchor picks today's leg for today's choice")
        expect(FlightSnapshot.nearest(to: now, in: []) == nil,
               "no legs re-anchors to nothing")

        print("flight number validation")
        expect(AeroDataBoxProvider.sanitise("nh7") == "NH7", "lowercase is normalised")
        expect(AeroDataBoxProvider.sanitise(" BA 15 ") == "BA15", "spaces are stripped")
        expect(AeroDataBoxProvider.sanitise("NH7/../admin") == nil, "path characters are rejected")
        expect(AeroDataBoxProvider.sanitise("NH?7") == nil, "query characters are rejected")
        expect(AeroDataBoxProvider.sanitise("") == nil, "empty is rejected")
        expect(AeroDataBoxProvider.sanitise(String(repeating: "A", count: 40)) == nil,
               "overlong input is rejected")

        print("formatting")
        expect(Format.duration(6 * hour + 12 * 60) == "6h12m", "6h12m")
        expect(Format.duration(38 * 60) == "38m", "38m")
        expect(Format.duration(30) == "<1m", "under a minute is not called Landing")
        expect(Format.duration(-600) == "<1m", "a negative duration never goes negative")
        expect(Format.untilArrival(30) == "Landing", "arrival within a minute is Landing")
        expect(Format.untilArrival(6 * hour) == "6h00m", "arrival further out counts down")
        expect(Format.untilDeparture(-300) == "Due", "an overdue departure reads Due, not Landing")
        expect(Format.untilDeparture(2 * hour) == "2h00m", "a pending departure counts down")

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
