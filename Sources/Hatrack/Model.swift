import Foundation

/// Which part of its life a tracked flight is in. Drives colour and readout.
enum Phase: String, Codable {
    case scheduled      // grey track, counting down to departure
    case delayed        // as scheduled, but the airline moved the time
    case inFlight       // blue track filling
    case landed         // green track, dot at the destination
    case notFound       // the number resolved to nothing
}

struct Airport: Codable, Equatable {
    var iata: String
    var timeZoneID: String?

    var timeZone: TimeZone? { timeZoneID.flatMap(TimeZone.init(identifier:)) }
}

/// One reading of a flight from the provider. Everything the widget knows.
struct FlightSnapshot: Codable, Equatable {
    var number: String
    var origin: Airport
    var destination: Airport

    var scheduledDeparture: Date
    var revisedDeparture: Date?
    var actualDeparture: Date?

    var scheduledArrival: Date
    var predictedArrival: Date?
    var actualArrival: Date?

    var aircraft: String?
    var registration: String?
    var providerStatus: String?
    var fetchedAt: Date

    /// Best known departure: actual beats revised beats scheduled.
    var departure: Date { actualDeparture ?? revisedDeparture ?? scheduledDeparture }
    /// Best known arrival, same precedence.
    var arrival: Date { actualArrival ?? predictedArrival ?? scheduledArrival }

    /// Minutes the departure has slipped from schedule. Negative means early.
    var delayMinutes: Int {
        Int(((revisedDeparture ?? actualDeparture ?? scheduledDeparture)
            .timeIntervalSince(scheduledDeparture) / 60).rounded())
    }

    var hasDeparted: Bool {
        if actualDeparture != nil { return true }
        switch providerStatus?.lowercased() {
        case "enroute", "en route", "arrived", "landed", "departed": return true
        default: return false
        }
    }

    var hasArrived: Bool {
        if actualArrival != nil { return true }
        switch providerStatus?.lowercased() {
        case "arrived", "landed": return true
        default: return false
        }
    }

    func phase(at now: Date) -> Phase {
        if hasArrived { return .landed }
        if hasDeparted { return .inFlight }
        return delayMinutes >= 5 ? .delayed : .scheduled
    }

    /// Among a day's legs, the one whose scheduled departure is closest to a
    /// chosen instant. A flight number can fly several sectors on one date, so
    /// re-anchoring the leg the user picked means matching on its schedule
    /// rather than trusting position in the array.
    static func nearest(to target: Date, in snapshots: [FlightSnapshot]) -> FlightSnapshot? {
        snapshots.min {
            abs($0.scheduledDeparture.timeIntervalSince(target))
                < abs($1.scheduledDeparture.timeIntervalSince(target))
        }
    }

    /// 0 at the origin, 1 at the destination. Pure clock arithmetic, which is
    /// why the bar keeps moving between polls.
    func progress(at now: Date) -> Double {
        let total = arrival.timeIntervalSince(departure)
        guard total > 0 else { return hasArrived ? 1 : 0 }
        if hasArrived { return 1 }
        if !hasDeparted { return 0 }
        return min(max(now.timeIntervalSince(departure) / total, 0), 1)
    }
}

enum Format {
    /// "6h12m", "38m", "<1m". Never wider than it has to be.
    ///
    /// Deliberately says nothing about what the time means: a phase-specific
    /// word like "Landing" belongs at the call site, or it ends up labelling a
    /// departure countdown, or a negative one.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "<1m" }
        let minutes = total / 60
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    /// Time until departure. Once the scheduled time passes on a flight the
    /// airline still calls scheduled, there is no countdown left to show.
    static func untilDeparture(_ seconds: TimeInterval) -> String {
        seconds <= 0 ? "Due" : duration(seconds)
    }

    /// Time until arrival, which does end in a landing.
    static func untilArrival(_ seconds: TimeInterval) -> String {
        seconds <= 60 ? "Landing" : duration(seconds)
    }

    /// A delay, in the same units it deserves: "32" while it is minutes,
    /// "3h" or "1h30m" once it crosses an hour. The sign lives at the call
    /// site, which already writes the leading "+".
    static func delay(_ minutes: Int) -> String {
        let m = abs(minutes)
        if m < 60 { return "\(m)" }
        let h = m / 60, rem = m % 60
        return rem > 0 ? "\(h)h\(rem)m" : "\(h)h"
    }

    static func clock(_ date: Date, in zone: TimeZone?) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = zone ?? .current
        return f.string(from: date)
    }

    /// "2 Sep" - the calendar day, for a picker row's date line.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 90 { return "just now" }
        return duration(s) + " ago"
    }
}
