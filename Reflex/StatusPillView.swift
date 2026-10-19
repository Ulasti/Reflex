#if os(macOS)
import SwiftUI
import ReflexCore

/// The pill-shaped status light: a capsule holding a pulsing LED and the state
/// in words, so the state is never carried by color alone. Used near the notch
/// and in the Settings window.
struct StatusPillView: View {
    let light: StatusLight
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(pulse ? 0.9 : 0.25), radius: pulse ? 5 : 1)
                .opacity(brightness)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(.thinMaterial))
        .overlay(Capsule().strokeBorder(.separator))
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = light != .off }
        .onChange(of: light) { _, new in pulse = new != .off }
        .help(helpText)
    }

    private var color: Color {
        switch light {
        case .red: .red
        case .amber: .orange
        case .green: .green
        case .off: .secondary
        }
    }

    private var title: String {
        switch light {
        case .red: "Error"
        case .amber: "Busy"
        case .green: "Listening"
        case .off: "Idle"
        }
    }

    private var brightness: Double {
        switch light {
        case .off: 0.45
        case .green: pulse ? 1.0 : 0.6
        default: 1.0
        }
    }

    private var helpText: String {
        switch light {
        case .red(let reason): "Unavailable: \(reason)"
        case .amber(let reason): "Busy: \(reason)"
        case .green: "Listening"
        case .off: "Idle"
        }
    }
}
#endif
