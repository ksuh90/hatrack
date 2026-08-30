import Foundation

enum ProviderError: LocalizedError {
    case missingKey
    case notFound
    case quotaExhausted
    case http(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key set."
        case .notFound: return "No upcoming flight with that number."
        case .quotaExhausted: return "Monthly API units spent."
        case .http(let code): return "Provider returned HTTP \(code)."
        case .malformed(let detail): return "Unexpected response: \(detail)"
        }
    }
}

protocol FlightProvider: Sendable {
    /// Units this provider charges for one status lookup.
    var unitsPerLookup: Int { get }
    /// Resolve a bare flight number to its nearest upcoming (or in-progress) leg.
    func lookup(number: String, now: Date) async throws -> FlightSnapshot
}

/// AeroDataBox via RapidAPI. Flight status is a Tier 2 endpoint: 2 units a call.
struct AeroDataBoxProvider: FlightProvider {
    let apiKey: String
    let host = "aerodatabox.p.rapidapi.com"
    var unitsPerLookup: Int { 2 }

    func lookup(number: String, now: Date) async throws -> FlightSnapshot {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard let cleaned = Self.sanitise(number) else { throw ProviderError.notFound }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/flights/number/\(cleaned)"
        components.queryItems = [
            URLQueryItem(name: "withAircraftImage", value: "false"),
            URLQueryItem(name: "withLocation", value: "false")
        ]
        guard let url = components.url else { throw ProviderError.notFound }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "X-RapidAPI-Key")
        request.setValue(host, forHTTPHeaderField: "X-RapidAPI-Host")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformed("no HTTP response")
        }
        switch http.statusCode {
        case 200: break
        case 204, 404: throw ProviderError.notFound
        case 429: throw ProviderError.quotaExhausted
        default: throw ProviderError.http(http.statusCode)
        }

        let legs = try JSONDecoder().decode([Leg].self, from: data)
        guard let leg = Self.nearest(in: legs, now: now) else { throw ProviderError.notFound }
        return try leg.snapshot(fetchedAt: now)
    }

    /// A flight number is letters and digits, nothing else. Anything that could
    /// change the shape of the request path is rejected rather than escaped.
    static func sanitise(_ number: String) -> String? {
        let cleaned = number.uppercased().filter { !$0.isWhitespace }
        guard (2...8).contains(cleaned.count),
              cleaned.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return cleaned
    }

    /// The one the user means: still in progress, or the soonest still to come.
    /// Falls back to the most recent past leg so a just-landed flight still reads.
    static func nearest(in legs: [Leg], now: Date) -> Leg? {
        let dated = legs.compactMap { leg -> (Leg, Date, Date)? in
            guard let dep = leg.departureDate, let arr = leg.arrivalDate else { return nil }
            return (leg, dep, arr)
        }
        if let inProgress = dated.filter({ $0.1 <= now && now <= $0.2.addingTimeInterval(3600) })
            .min(by: { $0.1 < $1.1 }) {
            return inProgress.0
        }
        if let upcoming = dated.filter({ $0.1 > now }).min(by: { $0.1 < $1.1 }) {
            return upcoming.0
        }
        return dated.max(by: { $0.1 < $1.1 })?.0
    }

    // MARK: response shape

    struct Leg: Decodable {
        var number: String?
        var status: String?
        var departure: Movement?
        var arrival: Movement?
        var aircraft: Aircraft?

        var departureDate: Date? { departure?.best }
        var arrivalDate: Date? { arrival?.best }

        func snapshot(fetchedAt: Date) throws -> FlightSnapshot {
            guard let departure, let arrival,
                  let depScheduled = departure.scheduledTime?.date,
                  let arrScheduled = arrival.scheduledTime?.date else {
                throw ProviderError.malformed("missing scheduled times")
            }
            return FlightSnapshot(
                number: (number ?? "").replacingOccurrences(of: " ", with: ""),
                origin: Airport(iata: departure.airport?.iata ?? "???",
                                timeZoneID: departure.airport?.timeZone),
                destination: Airport(iata: arrival.airport?.iata ?? "???",
                                     timeZoneID: arrival.airport?.timeZone),
                scheduledDeparture: depScheduled,
                revisedDeparture: departure.revisedTime?.date,
                actualDeparture: departure.runwayTime?.date,
                scheduledArrival: arrScheduled,
                predictedArrival: arrival.predictedTime?.date ?? arrival.revisedTime?.date,
                actualArrival: arrival.runwayTime?.date,
                aircraft: aircraft?.model,
                registration: aircraft?.reg,
                providerStatus: status,
                fetchedAt: fetchedAt
            )
        }
    }

    struct Movement: Decodable {
        var airport: AirportRef?
        var scheduledTime: TimeRef?
        var revisedTime: TimeRef?
        var predictedTime: TimeRef?
        var runwayTime: TimeRef?

        var best: Date? {
            runwayTime?.date ?? predictedTime?.date ?? revisedTime?.date ?? scheduledTime?.date
        }
    }

    struct AirportRef: Decodable {
        var iata: String?
        var timeZone: String?
    }

    struct Aircraft: Decodable {
        var model: String?
        var reg: String?
    }

    /// AeroDataBox sends "2026-08-30 12:05Z" and "2026-08-30 21:05+09:00".
    struct TimeRef: Decodable {
        var utc: String?
        var local: String?

        var date: Date? {
            if let utc, let d = Self.parse(utc) { return d }
            if let local, let d = Self.parse(local) { return d }
            return nil
        }

        private static let formats = [
            "yyyy-MM-dd HH:mmZZZZZ",
            "yyyy-MM-dd HH:mm:ssZZZZZ",
            "yyyy-MM-dd HH:mmXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        ]

        static func parse(_ raw: String) -> Date? {
            let value = raw.replacingOccurrences(of: "Z", with: "+0000")
            for format in formats {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = format
                if let date = f.date(from: value) { return date }
            }
            return nil
        }
    }
}

/// Stand-in used by --render-states and by demo mode, so the UI can be exercised
/// end to end without spending a unit.
struct DemoProvider: FlightProvider {
    var unitsPerLookup: Int { 0 }

    func lookup(number: String, now: Date) async throws -> FlightSnapshot {
        FlightSnapshot(
            number: number.uppercased(),
            origin: Airport(iata: "DXB", timeZoneID: "Asia/Dubai"),
            destination: Airport(iata: "HND", timeZoneID: "Asia/Tokyo"),
            scheduledDeparture: now.addingTimeInterval(-6 * 3600),
            revisedDeparture: nil,
            actualDeparture: now.addingTimeInterval(-6 * 3600),
            scheduledArrival: now.addingTimeInterval(3.7 * 3600),
            predictedArrival: nil,
            actualArrival: nil,
            aircraft: "777-300ER",
            registration: "JA784A",
            providerStatus: "EnRoute",
            fetchedAt: now
        )
    }
}
