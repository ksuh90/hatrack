import AppKit
import SwiftUI

/// Borderless panels refuse key status by default, which would stop the text
/// fields taking input.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The dropdown, positioned by hand.
///
/// NSPopover's `show(relativeTo:of:)` cannot resolve a scene-hosted status item
/// (`NSSceneStatusItem`, the macOS 26 menu bar) to screen coordinates: it puts
/// the panel at the screen origin, on top of the menu bar. So the panel is a
/// plain window and we place it ourselves, under the item and below the bar.
@MainActor
final class PanelController {
    private let window: PanelWindow
    private let hosting: NSHostingView<PanelView>
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    /// Where the panel should hang from, in screen coordinates.
    var anchorProvider: () -> NSRect? = { nil }
    var onClose: () -> Void = {}

    var isOpen: Bool { window.isVisible }
    var frameForDiagnostics: NSRect? { window.isVisible ? window.frame : nil }

    init(coordinator: Coordinator) {
        hosting = NSHostingView(rootView: PanelView(coordinator: coordinator))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])

        window = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 296, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.contentView = backdrop
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu           // above windows, below the menu bar
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .utilityWindow
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        layout()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMonitors()
    }

    func close() {
        removeMonitors()
        window.orderOut(nil)
        onClose()
    }

    /// Size to the content and hang it under the anchor, clamped on screen.
    func layout() {
        guard let screen = screenForAnchor() else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window.setContentSize(size)

        let visible = screen.visibleFrame
        let anchor = anchorProvider()
        let centreX = anchor?.midX ?? visible.maxX - size.width / 2 - 12
        let x = min(max(centreX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        // visibleFrame's top edge is exactly the underside of the menu bar
        let y = visible.maxY - size.height - 6
        window.setFrame(NSRect(x: x.rounded(), y: y.rounded(),
                               width: size.width, height: size.height), display: true)
    }

    private func screenForAnchor() -> NSScreen? {
        if let anchor = anchorProvider() {
            if let match = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) { return match }
        }
        return NSScreen.main
    }

    private func installMonitors() {
        removeMonitors()
        // A click anywhere outside this app dismisses it, the way a menu would.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {        // escape
                Task { @MainActor in self?.close() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }
}
