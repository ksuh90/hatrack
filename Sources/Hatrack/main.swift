import AppKit
import SwiftUI
import Combine

/// Diagnostics go to a file: NSLog through a pipe has proved unreliable when
/// the app is launched detached.
func diag(_ message: String) {
    guard ProcessInfo.processInfo.environment["HATRACK_DIAG"] == "1" else { return }
    // Not /tmp: it is world-writable, so a predictable name there can be
    // pre-created as a symlink pointing somewhere else.
    let path = ProcessInfo.processInfo.environment["HATRACK_DIAG_FILE"]
        ?? Store.directory.appendingPathComponent("diagnostics.log").path
    let url = URL(fileURLWithPath: path)
    let line = Data("\(Date()) \(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    } else {
        try? line.write(to: url)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate var statusItem: NSStatusItem!
    private var panel: PanelController!
    private let coordinator = Coordinator()
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    /// How much detail has been dropped to keep the item on screen.
    /// 0 full, 1 no readout, 2 no airport codes, 3 route only.
    private var shedLevel = 0 {
        didSet { coordinator.reportShedLevel(shedLevel) }
    }
    private var fitCheckPending = false
    private var nextRestoreAttempt = Date.distantPast
    private var restoreBackoff: TimeInterval = 60
    private var fitCheckRetries = 0
    /// When we last changed the item ourselves, so our own redraws are not
    /// mistaken for the menu bar rearranging around us.
    private var lastSelfChange = Date.distantPast
    private var moveObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["HATRACK_DEMO"] == "1" {
            coordinator.providerOverride = DemoProvider()
            // Exercise the real flow: resolve the days, then commit today's leg.
            Task {
                await coordinator.resolve("NH7")
                if let today = coordinator.candidates?.first { coordinator.commit(today) }
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        // Anything the user does themselves re-opens the question of how much
        // detail fits, starting from full.
        coordinator.onUserChange = { [weak self] in self?.resetShedding() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resetShedding() }
        }

        panel = PanelController(coordinator: coordinator)
        panel.anchorProvider = { [weak self] in self?.placedFrame() }

        // Redraw whenever the model changes, and whenever the bar's appearance
        // flips, since a non-template image has to pick its own palette.
        coordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refresh()
                // The panel grows and shrinks with the flight's state; keep it
                // hanging from the same point under the menu bar.
                if self.panel.isOpen { self.panel.layout() }
            }
            .store(in: &cancellables)

        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }

        // The item slides when anything else joins or leaves the menu bar - the
        // screen recording indicator being the common one. That is the moment
        // to reconsider how much detail fits, rather than waiting out a timer.
        moveObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: statusItem.button?.window,
            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.menuBarRearranged() }
        }

        installMainMenu()
        coordinator.start()
        refresh()

        if ProcessInfo.processInfo.environment["HATRACK_DIAG"] == "1" {
            diag("launch: diagnostics active")
            let button = statusItem.button
            diag("launch: item visible=\(statusItem.isVisible) image=\(String(describing: button?.image?.size)) window=\(String(describing: button?.window?.frame))")

            // Again once the bar has laid out: an item that does not fit is
            // dropped by macOS, and that only shows up after placement.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                let button = self.statusItem.button
                diag("placed: frame=\(String(describing: button?.window?.frame)) image=\(String(describing: button?.image?.size))")
                if let screen = button?.window?.screen ?? NSScreen.main {
                    diag("screen: \(screen.frame) auxRight=\(String(describing: screen.auxiliaryTopRightArea))")
                    if let frame = button?.window?.frame, let aux = screen.auxiliaryTopRightArea {
                        diag("fit: roomToNotch=\(frame.maxX - aux.minX) needed=\(frame.width) shedLevel=\(self.shedLevel)")
                    }
                }
            }
        }
    }

    /// A menu-bar-only app has no menu bar of its own, so the standard editing
    /// shortcuts have nothing to dispatch to and Cmd-V does nothing in the
    /// panel's text fields. Installing an Edit menu restores them.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Hatrack", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private var palette: BarPalette {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        let image = BarRenderer.image(for: shedding(coordinator.barContent),
                                      palette: palette,
                                      height: NSStatusBar.system.thickness)

        // Applied immediately, panel open or not: toggling an option should
        // show up in the menu bar as you toggle it. The panel is a window we
        // place ourselves and does not chase the item, so a resize behind it
        // no longer drags it sideways the way the old popover did.
        button.image = image
        button.toolTip = tooltip
        lastSelfChange = Date()
        scheduleFitCheck()
    }

    /// A menu bar with no room left pushes an oversized item under the notch,
    /// where it is simply invisible. Drop detail until it fits: readout first,
    /// then the airport codes, then the flight number. The track and the
    /// aircraft are the last things standing.
    private func shedding(_ content: BarContent) -> BarContent {
        var content = content
        if shedLevel >= 1 { content.showReadout = false }
        if shedLevel >= 2 { content.showAirports = false }
        if shedLevel >= 3 { content.showFlightNumber = false }
        return content
    }

    /// macOS reports a placeholder frame for a status item until it lays the
    /// menu bar out - offscreen, at negative y. Shedding on it, or anchoring the
    /// panel to it, is what threw both into the corner. Returns nil until the
    /// item is genuinely placed in the menu bar.
    fileprivate func placedFrame() -> NSRect? {
        guard let window = statusItem.button?.window,
              let screen = window.screen ?? NSScreen.main else { return nil }
        let frame = window.frame
        guard frame.width > 1, frame.height > 1, frame.origin.y > 0,
              frame.maxY >= screen.frame.maxY - 1 else { return nil }
        return frame
    }

    /// Something else in the menu bar appeared or disappeared. Our own redraws
    /// move the item too, so ignore anything that follows one closely.
    private func menuBarRearranged() {
        guard shedLevel > 0 else { return }
        guard Date().timeIntervalSince(lastSelfChange) > 1.5 else { return }
        resetShedding()
    }

    /// Back to full detail, then measure again.
    private func resetShedding() {
        shedLevel = 0
        restoreBackoff = 60
        nextRestoreAttempt = .distantPast
        refresh()
    }

    private func scheduleFitCheck() {
        guard !fitCheckPending else { return }
        fitCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.fitCheckPending = false
            self?.checkFit()
        }
    }

    /// Spilling left of the notch is the signal that we do not fit. On screens
    /// without a notch there is nothing to measure against, so trust macOS.
    private func checkFit() {
        guard let window = statusItem.button?.window,
              let screen = window.screen ?? NSScreen.main,
              let rightArea = screen.auxiliaryTopRightArea else { return }

        // A shrunk item that reads as fitting is exactly the stuck case above,
        // so let the restore timer run rather than trusting the reading.
        guard let frame = placedFrame() else {
            // Not placed yet: look again rather than judging a placeholder.
            if fitCheckRetries < 20 {
                fitCheckRetries += 1
                scheduleFitCheck()
            }
            return
        }
        fitCheckRetries = 0

        let spilling = frame.minX < rightArea.minX - 0.5
        let now = Date()

        if spilling {
            if shedLevel < 3 {
                // Shedding straight after a restore means the space really is
                // gone; wait longer before trying again.
                if now < nextRestoreAttempt + 3 {
                    // Backing off too far leaves the item shrunk long after the
                    // space came back, which reads as broken. Five minutes max.
                    restoreBackoff = min(restoreBackoff * 2, 300)
                }
                nextRestoreAttempt = now.addingTimeInterval(restoreBackoff)
                shedLevel += 1
                diag("shed to level \(shedLevel) (frame \(frame), notch right edge \(rightArea.minX))")
                refresh()
            }
        } else if shedLevel > 0, now >= nextRestoreAttempt {
            // Reset to full detail rather than stepping down one level.
            //
            // macOS keeps a status item in the slot it first placed it, so once
            // we have shrunk, the placement reading stays the same and stepping
            // down never gets a chance to run - the item stays shrunk long
            // after the space came back. Going back to full width forces a
            // re-layout; if it still does not fit, the next check sheds again.
            nextRestoreAttempt = now.addingTimeInterval(restoreBackoff)
            shedLevel = 0
            refresh()
        }
    }

    private var tooltip: String {
        guard let s = coordinator.snapshot else { return "Hatrack" }
        return "\(s.number)  \(s.origin.iata) to \(s.destination.iata)"
    }

    @objc private func togglePanel() {
        panel.toggle()
    }


}

// MARK: - entry point

/// `NSApplication.delegate` is weak; without this the delegate would deallocate.
nonisolated(unsafe) var delegateRetain: AnyObject?

/// `--render-states <path.png>` draws every bar state to one image without
/// launching the UI, so the drawing can be checked without a flight or a key.
if let index = CommandLine.arguments.firstIndex(of: "--render-states") {
    let output = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "hatrack-states.png"
    StateSheet.write(to: output)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-iconset") {
    let output = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "Hatrack.iconset"
    _ = NSApplication.shared
    AppIcon.writeIconset(to: output)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-icon") {
    let output = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "hatrack-icon.png"
    _ = NSApplication.shared
    AppIcon.writePreview(to: output)
    exit(0)
}

if CommandLine.arguments.contains("--self-check") {
    exit(SelfCheck.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--render-panel") {
    let output = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "hatrack-panel.png"
    _ = NSApplication.shared            // AppKit needs to exist to lay out views
    MainActor.assumeIsolated { PanelSheet.write(to: output) }
    exit(0)
}

// Top-level code is nonisolated, so step onto the main actor explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    delegateRetain = delegate               // NSApplication holds this weakly
    app.run()
}
