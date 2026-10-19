#if os(macOS)
import SwiftUI
import AppKit
import ReflexCore

/// The menu bar icon as the entire status display. Of the three planned
/// surfaces (notch, floating pill, menu bar) this one has the least room, so it
/// carries no words: color, motion and the glyph do all the work. It is the
/// surface the whole feedback model has to prove itself on first.
///
/// States come from `SignalLight` (one color, one job); the glyph only ever
/// switches between mic and slashed mic, because motion already separates the
/// rest — breathing = resting, level-following = hearing, flash = acted,
/// solid = error.
struct MenuBarIconView: View {
    @EnvironmentObject private var appModel: AppModel

    /// One full dim→bright→dim breath, in seconds.
    private let breathCycle: Double = 4
    /// How long the green "it acted" flash lasts before fading back.
    private let flashDuration: Double = 0.3
    /// Motion frame rate. A light does not need more than 30 fps, and this
    /// keeps the status item's continuous redraw cheap.
    private let frameInterval: Double = 1.0 / 30.0

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: frameInterval)) { context in
            let state = appModel.menuBarLight
            Image(systemName: state == .off ? "mic.slash.fill" : "mic.fill")
                // Palette mode is what makes an explicit color survive on a
                // menu bar label; plain foregroundStyle falls back to the
                // template tint (SO 75856718).
                .symbolRenderingMode(.palette)
                .foregroundStyle(color(for: state), color(for: state))
                .opacity(opacity(for: state, at: context.date))
                .accessibilityLabel(Text("\(state.rawValue) — \(appModel.modelStatus)"))
        }
    }

    /// Adaptive label color, not literal white: a fixed white vanishes in a
    /// light menu bar. Green/amber/red are the system semantic colors so they
    /// track increased-contrast settings too.
    private func color(for state: SignalLight) -> Color {
        switch state {
        case .error: return Color(nsColor: .systemRed)
        case .waiting: return Color(nsColor: .systemOrange)
        case .executed: return Color(nsColor: .systemGreen)
        case .off, .armed, .hearing: return Color(nsColor: .labelColor)
        }
    }

    private func opacity(for state: SignalLight, at date: Date) -> Double {
        switch state {
        case .off, .error:
            return 1
        case .armed:
            return breath(at: date, low: 0.30, high: 0.65)
        case .waiting:
            return breath(at: date, low: 0.50, high: 1.0)
        case .hearing:
            // Voice-following: ~100 ms behind the mic (StreamSegmenter emits a
            // level per window), which is fast enough to read as instant.
            return 0.70 + 0.30 * Double(clampedLevel)
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
