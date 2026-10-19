#if os(macOS)
import SwiftUI
import AppKit
import ReflexCore

/// The menu bar icon as the entire status display. Of the three planned
/// surfaces (notch, floating pill, menu bar) this one has the least room, so it
/// carries no words: color, motion and the glyph do all the work.
///
/// The glyph is drawn as an explicit `NSImage` rather than a SwiftUI
/// `Image(systemName:)`. A symbol placed directly in a `MenuBarExtra` label is
/// auto-sized and template-tinted by the system; anything less trivial than a
/// bare image (a `TimelineView`, an animated opacity) loses that sizing and the
/// symbol falls back to body-text size — a few unreadable pixels. Drawing the
/// symbol ourselves with an explicit point size and `isTemplate = false` pins
/// both the size and the color, and nothing about it depends on the label
/// being simple.
struct MenuBarIconView: View {
    @EnvironmentObject private var appModel: AppModel

    /// One full dim→bright→dim breath, in seconds.
    private let breathCycle: Double = 4
    /// How long the green "it acted" flash lasts before fading back.
    private let flashDuration: Double = 0.3
    /// Menu bar glyph point size. The bar itself is ~24 pt tall on an external
    /// display and ~38 pt under the notch.
    private let glyphSize: CGFloat = 16

    /// 30 fps is plenty for a light and keeps the redraw cheap.
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// Redrawn only when the state or the appearance changes, not per frame.
    @State private var glyph = NSImage()
    private let blankGlyph = NSImage(size: NSSize(width: 1, height: 1))

    @Environment(\.colorScheme) private var colorScheme
    @State private var now = Date()

    private var state: SignalLight { appModel.menuBarLight }

    var body: some View {
        Image(nsImage: glyph)
            .opacity(opacity(at: now))
            .onAppear { glyph = draw(state) }
            .onChange(of: state) { _, new in glyph = draw(new) }
            .onChange(of: colorScheme) { _, _ in glyph = draw(state) }
            .onReceive(timer) { now = $0 }
            .accessibilityLabel(Text("\(state.rawValue) — \(appModel.modelStatus)"))
    }

    // MARK: - Glyph

    private func draw(_ state: SignalLight) -> NSImage {
        let name = state == .off ? "mic.slash.fill" : "mic.fill"
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return blankGlyph
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [nsColor(for: state)]))
        guard let tinted = base.withSymbolConfiguration(configuration) else { return base }
        // Without this the status bar re-tints the glyph to the menu bar's label
        // color and every state looks identical.
        tinted.isTemplate = false
        return tinted
    }

    /// System semantic colors, so increased-contrast settings are respected.
    /// The neutral states use the adaptive label color rather than literal
    /// white, which would vanish against a light menu bar.
    private func nsColor(for state: SignalLight) -> NSColor {
        switch state {
        case .error: return .systemRed
        case .waiting: return .systemOrange
        case .executed: return .systemGreen
        case .off, .armed, .hearing: return .labelColor
        }
    }

    // MARK: - Motion

    private func opacity(at date: Date) -> Double {
        switch state {
        case .off, .error:
            return 1
        case .armed:
            return breath(at: date, low: 0.30, high: 0.65)
        case .waiting:
            return breath(at: date, low: 0.50, high: 1.0)
        case .hearing:
            // Voice-following: one level per capture chunk (tens of ms), so the
            // 30 fps redraw is what limits how fast the light reacts.
            return 0.70 + 0.30 * clampedLevel
        case .executed:
            guard let start = appModel.actionFlashStart else { return 1 }
            let progress = min(1, max(0, date.timeIntervalSince(start) / flashDuration))
            return 1 - 0.45 * progress
        }
    }

    /// Smooth 0→1→0 sine over `breathCycle`, so the resting state reads as a
    /// slow breath rather than a blink.
    private func breath(at date: Date, low: Double, high: Double) -> Double {
        let phase = 0.5 - 0.5 * cos(2 * .pi * date.timeIntervalSinceReferenceDate / breathCycle)
        return low + (high - low) * phase
    }

    private var clampedLevel: Double {
        Double(min(1, max(0, appModel.liveLevel)))
    }
}
#endif
