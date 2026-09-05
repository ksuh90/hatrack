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

/// The account's real quota, read from the provider's response headers — the
/// source of truth, as opposed to the app's local estimate.
struct RemoteQuota: Codable, Equatable, Sendable {
    var limit: Int
    var remaining: Int
}

protocol FlightProvider: Sendable {
    /// Units one dated status lookup charges - re-anchoring the tracked leg.
    var unitsPerLookup: Int { get }
    /// Units one range lookup charges - listing the days the picker offers.
    var unitsPerRangeLookup: Int { get }
    /// Every operating leg of `number` on local dates within [from, to]. Feeds the
    /// date picker; one call covers the whole window.
    func candidates(number: String, from: Date, to: Date, now: Date) async throws -> [FlightSnapshot]
    /// Re-anchor one already-chosen leg: fetch the tracked local date and return
    /// the leg whose schedule matches `target`. Polling only ever calls this, so a
    /// tracked flight is never re-resolved to the nearest departure.
    func lookup(number: String, on localDate: String, matching target: Date, now: Date) async throws -> FlightSnapshot
}

/// AeroDataBox via RapidAPI. Dated flight status is a Tier 2 endpoint (2 units);
/// the range endpoint that lists the picker's days is Tier 3 (6 units).
struct AeroDataBoxProvider: FlightProvider {
    let apiKey: String
    let host = "aerodatabox.p.rapidapi.com"
    /// Called with the account's real quota whenever a response carries it.
    var onQuota: (@Sendable (RemoteQuota) -> Void)? = nil
    var unitsPerLookup: Int { 2 }
    var unitsPerRangeLookup: Int { 6 }

    func candidates(number: String, from: Date, to: Date, now: Date) async throws -> [FlightSnapshot] {
        guard let cleaned = Self.sanitise(number) else { throw ProviderError.notFound }
        // One range call `/flights/number/{n}/{from}/{to}` returns every leg in
        // the window; the Basic plan allows a span well past our four days.
        let path = "/flights/number/\(cleaned)/\(Self.dateKey(from))/\(Self.dateKey(to))"
        return try await fetchSnapshots(path: path, now: now)
    }

    func lookup(number: String, on localDate: String, matching target: Date, now: Date) async throws -> FlightSnapshot {
        guard let cleaned = Self.sanitise(number) else { throw ProviderError.notFound }
        let snaps = try await fetchSnapshots(path: "/flights/number/\(cleaned)/\(localDate)", now: now)
        guard let match = FlightSnapshot.nearest(to: target, in: snaps) else { throw ProviderError.notFound }
        return match
    }

    /// One GET, decoded into snapshots sorted by departure. A 204/404 means the
    /// number simply has no legs in the requested window, which is an empty list
    /// rather than an error - callers decide whether empty is "not found".
    private func fetchSnapshots(path: String, now: Date) async throws -> [FlightSnapshot] {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
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
        // Every response (even 204/404/429) carries the quota headers, so read
        // the real balance here regardless of the status.
        if let quota = Self.readQuota(from: http) { onQuota?(quota) }
        switch http.statusCode {
        case 200: break
        case 204, 404: return []
        case 429: throw ProviderError.quotaExhausted
        default: throw ProviderError.http(http.statusCode)
        }

        let legs = try JSONDecoder().decode([Leg].self, from: data)
        return legs.compactMap { try? $0.snapshot(fetchedAt: now) }
            .sorted { $0.scheduledDeparture < $1.scheduledDeparture }
    }

    /// AeroDataBox returns several `X-RateLimit-<object>-Limit`/`-Remaining`
    /// pairs: `api-units` is the real cost budget (e.g. 600) that actually binds,
    /// alongside a flat `requests` call-count cap and a blanket
    /// `rapid-free-plans-hard-limit` (500000). Units are what the app spends, so
    /// track `api-units`; fall back to `requests`.
    static func readQuota(from http: HTTPURLResponse) -> RemoteQuota? {
        for object in ["api-units", "requests"] {
            if let limit = intHeader(http, "x-ratelimit-\(object)-limit"),
               let remaining = intHeader(http, "x-ratelimit-\(object)-remaining") {
                return RemoteQuota(limit: limit, remaining: remaining)
            }
        }
        return nil
    }

    /// `value(forHTTPHeaderField:)` matches case-insensitively, so the lowercase
    /// names above find the headers whatever case the server sends.
    private static func intHeader(_ http: HTTPURLResponse, _ name: String) -> Int? {
        http.value(forHTTPHeaderField: name).flatMap(Int.init)
    }

    /// A flight number is letters and digits, nothing else. Anything that could
    /// change the shape of the request path is rejected rather than escaped.
    static func sanitise(_ number: String) -> String? {
        let cleaned = number.uppercased().filter { !$0.isWhitespace }
        guard (2...8).contains(cleaned.count),
              cleaned.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return cleaned
    }

    /// A local calendar date as the endpoint's YYYY-MM-DD path segment.
    static func dateKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
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
                  let depScheduled = departure.scheduledTime?.date ?? departure.best,
                  let arrScheduled = arrival.scheduledTime?.date ?? arrival.best else {
                throw ProviderError.malformed("missing times")
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
/// end to end without spending a unit. Offers one departure a day across the
/// picker window; the earliest is in progress so the tracked view has something
/// to draw once a day is committed.
struct DemoProvider: FlightProvider {
    var unitsPerLookup: Int { 0 }
    var unitsPerRangeLookup: Int { 0 }

    func candidates(number: String, from: Date, to: Date, now: Date) async throws -> [FlightSnapshot] {
        let cal = Calendar.current
        let days = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: from),
                                             to: cal.startOfDay(for: to)).day ?? 3)
        return (0...days).compactMap { day in
            // Today's leg is already airborne, so committing it exercises the
            // in-flight view; later days are scheduled departures.
            let dep = day == 0
                ? now.addingTimeInterval(-6 * 3600)
                : cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: now))?
                    .addingTimeInterval(11 * 3600 + 50 * 60)
            return dep.map { Self.leg(number: number, departing: $0, now: now) }
        }
    }

    func lookup(number: String, on localDate: String, matching target: Date, now: Date) async throws -> FlightSnapshot {
        Self.leg(number: number, departing: target, now: now)
    }

    private static func leg(number: String, departing dep: Date, now: Date) -> FlightSnapshot {
        let departed = dep <= now
        return FlightSnapshot(
            number: number.uppercased(),
            origin: Airport(iata: "DXB", timeZoneID: "Asia/Dubai"),
            destination: Airport(iata: "HND", timeZoneID: "Asia/Tokyo"),
            scheduledDeparture: dep,
            revisedDeparture: nil,
            actualDeparture: departed ? dep : nil,
            scheduledArrival: dep.addingTimeInterval(9.7 * 3600),
            predictedArrival: nil,
            actualArrival: nil,
            aircraft: "777-300ER",
            registration: "JA784A",
            providerStatus: departed ? "EnRoute" : "Expected",
            fetchedAt: now
        )
    }
}
