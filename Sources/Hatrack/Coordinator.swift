import Foundation
import Combine

/// Owns the tracked flight, decides when a call is worth spending, and hands the
/// bar a ready-made model. The countdown moves off the clock; the API is only
/// ever asked to re-anchor departure and arrival.
@MainActor
final class Coordinator: ObservableObject {

    @Published private(set) var state: PersistedState
    @Published private(set) var now: Date = Date()
    @Published private(set) var isPolling = false
    /// How much detail the menu bar item is currently dropping to fit, so the
    /// panel can say why a checked option is not showing up.
    @Published private(set) var fitShedLevel = 0
    /// Read lazily: touching the keychain prompts when the app's signature has
    /// changed, so it is only read when a call is actually about to be made.
    private var cachedKey: String?
    private var keyLoaded = false

    private var timer: Timer?
    private let clock: () -> Date

    /// Overridable so --render-states and demo mode can run without a key.
    var providerOverride: FlightProvider?

    /// Called when the user changes something themselves, so the menu bar item
    /// can re-evaluate how much detail it can show rather than staying shrunk.
    var onUserChange: () -> Void = {}

    /// Preview construction: fixed state, no disk, no network. Used by
    /// --render-panel so the dropdown can be checked without a live flight.
    init(preview state: PersistedState, now: Date) {
        self.clock = { now }
        self.state = state
        self.cachedKey = ""  // shows the key field, so renders cover that row too
        self.keyLoaded = true
        self.now = now
        self.providerOverride = DemoProvider()
    }

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        self.state = Store.load()
        self.now = clock()
    }

    var preferences: Preferences {
        get { state.preferences }
        set { state.preferences = newValue; persist(); onUserChange() }
    }

    var snapshot: FlightSnapshot? { state.snapshot }
    var quota: QuotaLedger { state.quota }
    var lastError: String? { state.lastError }

    /// Whether a key exists, without reading its value - and so without a
    /// keychain prompt. Demo mode never touches the keychain at all.
    var hasAPIKey: Bool {
        if providerOverride != nil { return true }
        if keyLoaded { return !(cachedKey ?? "").isEmpty }
        return Credentials.exists()
    }

    var apiKey: String {
        if !keyLoaded {
            cachedKey = Credentials.read() ?? ""
            keyLoaded = true
        }
        return cachedKey ?? ""
    }

    var provider: FlightProvider? {
        if let providerOverride { return providerOverride }
        let key = apiKey                    // reads the keychain, once, on demand
        guard !key.isEmpty else { return nil }
        return AeroDataBoxProvider(apiKey: key)
    }

    /// True once the month's ceiling is reached. The bar keeps interpolating,
    /// it just stops claiming the numbers are verified.
    var quotaExhausted: Bool {
        state.quota.units >= state.preferences.monthlyUnitCap
    }

    var unverified: Bool {
        guard let snapshot else { return false }
        // Estimates go stale once we could not re-anchor when we meant to.
        guard let due = state.nextPoll else { return quotaExhausted }
        return quotaExhausted && now >= due && snapshot.phase(at: now) != .landed
    }

    func reportShedLevel(_ level: Int) {
        guard fitShedLevel != level else { return }
        fitShedLevel = level
    }

    // MARK: lifecycle

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    func tick() async {
        now = clock()
        state.quota.rollIfNeeded(at: now)

        // A landed flight clears itself half an hour after touchdown.
        if let snapshot, snapshot.phase(at: now) == .landed,
           now.timeIntervalSince(snapshot.arrival) > 30 * 60 {
            clearFlight()
            return
        }

        if let due = state.nextPoll, now >= due, state.trackedNumber != nil {
            await poll()
        }
    }

    func track(_ number: String) async {
        let cleaned = number.uppercased().replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return }
        state.trackedNumber = cleaned
        state.snapshot = nil
        state.lastError = nil
        state.nextPoll = clock()
        persist()
        onUserChange()
        await poll()
    }

    func clearFlight() {
        state.trackedNumber = nil
        state.snapshot = nil
        state.nextPoll = nil
        state.lastError = nil
        persist()
        onUserChange()
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedKey = trimmed
        keyLoaded = true
        Credentials.write(trimmed)
    }

    // MARK: polling

    func poll(force: Bool = false) async {
        guard let number = state.trackedNumber, let provider else { return }
        guard !isPolling else { return }
        let cost = provider.unitsPerLookup
        if !force, cost > 0, state.quota.units + cost > state.preferences.monthlyUnitCap {
            state.lastError = "Monthly API units spent."
            persist()
            return
        }

        isPolling = true
        defer { isPolling = false }

        do {
            let snapshot = try await provider.lookup(number: number, now: clock())
            state.quota.units += cost
            state.snapshot = snapshot
            state.lastError = nil
            now = clock()
            state.nextPoll = Self.nextPoll(after: snapshot, now: now,
                                           preDepartureCheck: state.preferences.preDepartureCheck)
        } catch {
            state.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case ProviderError.notFound = error {
                state.snapshot = nil
                state.nextPoll = nil
            } else {
                // Transient: back off rather than hammering a paid endpoint.
                state.quota.units += cost
                state.nextPoll = clock().addingTimeInterval(15 * 60)
            }
        }
        persist()
    }

    /// The whole polling policy, in one readable place.
    ///
    /// Flights do not leave early, so nothing is spent before the scheduled time.
    /// A delay simply moves the next wake-up instead of starting a cadence.
    nonisolated static func nextPoll(after snapshot: FlightSnapshot, now: Date,
                                     preDepartureCheck: Bool) -> Date? {
        switch snapshot.phase(at: now) {
        case .landed, .notFound:
            return nil

        case .scheduled, .delayed:
            let departure = snapshot.departure
            if preDepartureCheck {
                let warning = departure.addingTimeInterval(-2 * 3600)
                if now < warning { return warning }
            }
            // Give the airline ten minutes past the scheduled time to publish
            // the change; asking sooner usually just buys a stale answer.
            let due = departure.addingTimeInterval(10 * 60)
            if now < due { return due }

            // Overdue: the scheduled time has passed and the airline still has
            // not confirmed departure. Check every ten minutes, not every
            // minute - a flight that is merely late being updated would
            // otherwise spend 120 units an hour.
            return now.addingTimeInterval(10 * 60)

        case .inFlight:
            let remaining = snapshot.arrival.timeIntervalSince(now)
            if remaining <= 0 {
                // Overdue: confirm touchdown, cheaply.
                return now.addingTimeInterval(10 * 60)
            }
            if remaining <= 45 * 60 {
                return now.addingTimeInterval(20 * 60)
            }
            // Never sleep straight through the approach window.
            let cruise = now.addingTimeInterval(90 * 60)
            let approach = snapshot.arrival.addingTimeInterval(-45 * 60)
            return min(cruise, approach)
        }
    }

    // MARK: presentation

    var barContent: BarContent {
        var content = BarContent()
        content.showFlightNumber = state.preferences.showFlightNumber
        content.showReadout = state.preferences.showTimeLeft

        guard let number = state.trackedNumber else { return content }

        guard let snapshot else {
            content.phase = .notFound
            content.flightNumber = number
            content.origin = "-"
            content.destination = "-"
            content.readout = state.lastError == nil ? "Looking up" : "Not found"
            return content
        }

        let phase = snapshot.phase(at: now)
        content.phase = phase
        content.flightNumber = snapshot.number.isEmpty ? number : snapshot.number
        content.origin = snapshot.origin.iata
        content.destination = snapshot.destination.iata
        content.progress = snapshot.progress(at: now)
        content.unverified = unverified

        switch phase {
        case .scheduled:
            content.readout = Format.untilDeparture(snapshot.departure.timeIntervalSince(now))
        case .delayed:
            content.readout = Format.untilDeparture(snapshot.departure.timeIntervalSince(now))
            content.delayNote = "+\(snapshot.delayMinutes)"
        case .inFlight:
            let remaining = snapshot.arrival.timeIntervalSince(now)
            content.readout = (content.unverified ? "~" : "") + Format.untilArrival(remaining)
        case .landed:
            content.readout = ""          // the green track is the message
        case .notFound:
            content.readout = "Not found"
        }
        return content
    }

    private func persist() { Store.save(state) }
}
