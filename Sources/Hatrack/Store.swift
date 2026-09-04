import Foundation
import Security

/// User-visible settings. Both bar elements the design made optional live here.
struct Preferences: Codable, Equatable {
    var showFlightNumber = true
    var showTimeLeft = true
    /// Hard ceiling this app will not spend past, in provider units.
    var monthlyUnitCap = 600
    /// Optional extra poll two hours before departure, for delay warning.
    var preDepartureCheck = false
}

/// Units spent this calendar month. Reset happens on the month boundary.
struct QuotaLedger: Codable, Equatable {
    var monthKey: String
    var units: Int

    static func key(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    static func empty(at date: Date) -> QuotaLedger {
        QuotaLedger(monthKey: key(for: date), units: 0)
    }

    mutating func rollIfNeeded(at date: Date) {
        let key = Self.key(for: date)
        if key != monthKey { self = QuotaLedger(monthKey: key, units: 0) }
    }

    func resetDate(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        return cal.date(byAdding: .month, value: 1, to: start) ?? now
    }
}

struct PersistedState: Codable {
    var trackedNumber: String?
    var snapshot: FlightSnapshot?
    /// The specific date the user picked, as the origin-local YYYY-MM-DD key the
    /// dated status endpoint expects. Polling re-anchors this leg and only this
    /// leg - the flight is never silently re-resolved to the nearest departure.
    var trackedDate: String?
    /// The scheduled departure of the picked leg, so a re-anchor can pick it out
    /// when a number flies several sectors on the tracked date.
    var trackedDeparture: Date?
    var nextPoll: Date?
    var lastError: String?
    var quota: QuotaLedger
    /// The account's real quota, last reported by the provider (source of truth).
    /// Optional, so decoding older state.json without the key simply yields nil.
    var remoteQuota: RemoteQuota?
    var preferences: Preferences

    static func fresh(now: Date = Date()) -> PersistedState {
        PersistedState(trackedNumber: nil, snapshot: nil, trackedDate: nil, trackedDeparture: nil,
                       nextPoll: nil, lastError: nil, quota: .empty(at: now), remoteQuota: nil,
                       preferences: Preferences())
    }
}

/// JSON on disk in Application Support. The API key is not in here; it lives in
/// the Keychain, because it is a credential.
enum Store {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hatrack", isDirectory: true)
    }()

    static var stateURL: URL { directory.appendingPathComponent("state.json") }

    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: stateURL),
              var state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return .fresh()
        }
        state.quota.rollIfNeeded(at: Date())
        return state
    }

    static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: stateURL.path)
        } catch {
            NSLog("hatrack: could not save state: \(error.localizedDescription)")
        }
    }
}

/// Keychain-backed API key.
enum Credentials {
    private static let service = "com.hatrack.aerodatabox"
    private static let account = "rapidapi"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Does a key exist? Asks for attributes only, never the secret, so this
    /// does not trigger the "wants to use your confidential information" prompt.
    static func exists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    @discardableResult
    static func write(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var insert = base
        insert[kSecValueData as String] = Data(trimmed.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}
