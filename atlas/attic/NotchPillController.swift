#if os(macOS)
import AppKit
import Combine
import SwiftUI
import ReflexCore

/// Shows the pill-shaped status light just below the notch (or just below the
/// menu bar on displays without one) whenever Reflex is doing something, and
/// hides it again when Reflex goes idle.
///
/// Coexistence with notch apps (Vorssaint, Notchy, …): those apps own a
/// borderless panel around the camera cutout. Drawing over it looks broken
/// whichever of the two windows is on top, so instead of stacking, the pill
/// measures the other island's window through the window server and sits just
/// below it. When the island expands far enough to cover the pill's slot, the
/// pill steps aside entirely until the island shrinks back. The panel ignores
/// mouse events, so it can never steal a click meant for the island or the
/// menu bar.
@MainActor
final class NotchPillController {
    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var hosting: NSHostingView<StatusPillView>?
    private weak var model: AppModel?
    private var observation: AnyCancellable?
    private var pollTimer: Timer?

    /// Gap between the menu bar / other island and the pill, and the furthest
    /// the pill will sit below the menu bar before it decides to step aside.
    private let gap: CGFloat = 4

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        // Menu-bar status items live at `.statusBar`; notch islands sit one
        // level above it. Sharing `.statusBar` keeps us below any island that
        // overlaps the slot, so the neighbor always wins visually.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func start(_ model: AppModel) {
        self.model = model
        observation = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
    }

    private func update() {
        guard let model, model.showNotchPill, model.statusLight != .off else {
            hide()
            return
        }
        guard let screen = notchedScreen() else {
            hide()
            return
        }

        let pill = StatusPillView(light: model.statusLight)
        if let hosting {
            hosting.rootView = pill
            hosting.layoutSubtreeIfNeeded()
        } else {
            let view = NSHostingView(rootView: pill)
            view.sizingOptions = []
            hosting = view
            panel.contentView = view
            view.layoutSubtreeIfNeeded()
        }
        // A hosting view that has not laid out yet reports no size; the fixed
        // fallback keeps the pill visible rather than stuck off-screen.
        let size: CGSize = {
            let measured = hosting?.fittingSize ?? .zero
            return measured.width > 1 && measured.height > 1
                ? measured
                : CGSize(width: 96, height: 26)
        }()

        // Slot: below the menu bar — the notch lives inside it — nudged below
        // a neighbor's island if one is up, or hidden when the island has
        // expanded over the slot itself.
        let menuBar = screen.auxiliaryTopLeftArea?.height ?? 24
        var topFromScreenTop = menuBar + gap
        if let islandBottom = Self.neighborIslandBottom(on: screen) {
            if islandBottom > topFromScreenTop + size.height + gap {
                // The island covers the slot: step aside, but keep polling so
                // the pill returns when the island shrinks back.
                hide(keepPolling: true)
                return
            }
            topFromScreenTop = max(topFromScreenTop, islandBottom + gap)
        }

        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - topFromScreenTop - size.height,
            width: size.width,
            height: size.height
        )
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        startPolling()
    }

    private func hide(keepPolling: Bool = false) {
        if !keepPolling { stopPolling() }
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// The built-in display's notch is the only one macOS reports; fall back
    /// to the main screen so external displays still get the pill under the
    /// menu bar.
    private func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main
    }

    /// Re-check while the pill is up: a neighbor's island expands or collapses
    /// without any change on our side. Stopped by hide() once Reflex is idle.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// The bottom edge of any other app's notch island, measured downward
    /// from the top of `screen`, or nil when nothing is drawn there.
    ///
    /// Reads on-screen windows through `CGWindowListCopyWindowInfo`, which
    /// needs no screen-recording permission for owner, layer and bounds.
    /// Notch islands are small (well under half the screen), sit at the very
    /// top, and live at the status-item window level — the same shape
    /// Vorssaint's `NotchPanel` has.
    private static func neighborIslandBottom(on screen: NSScreen) -> CGFloat? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        // CG global space: origin at the top-left of the primary screen,
        // y growing downward. The top of `screen` sits this far from it.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let screenTop = primaryHeight - screen.frame.maxY

        var bottom: CGFloat = 0
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner != "Reflex",
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  let layer = window[kCGWindowLayer as String] as? Int,
                  (NSWindow.Level.statusBar.rawValue - 7 ... NSWindow.Level.statusBar.rawValue + 2).contains(layer),
                  width < screen.frame.width / 2,
                  x < screen.frame.maxX, x + width > screen.frame.minX,
                  y < screenTop + 200
            else { continue }
            bottom = max(bottom, y + height - screenTop)
        }
        return bottom > 0 ? bottom : nil
    }
}

/// Message helper for Settings: whether another notch app we know how to
/// dodge is running right now.
enum NotchNeighbor {
    static var running: Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains("vorssaint")
        }
    }
}
#endif
