import Foundation

/// The single status-light model for the whole app (Phase C). UI renders the
/// current state as a pulsing LED, mimicking the AirPods/PSP feedback pattern:
/// Red = unavailable, Amber = busy, Green = listening (steady when idle-ready).
public enum StatusLight: Sendable, Equatable {
    case red(reason: String)
    case amber(reason: String)
    case green
    case off

    public var color: String {
        switch self {
        case .red: "red"
        case .amber: "amber"
        case .green: "green"
        case .off: "off"
        }
    }

    /// Maps engine/UI state to a light. `listening` drives green; busy work
    /// (model load, processing, a decision being dispatched) drives amber;
    /// any failure drives red with the reason.
    public static func resolve(
        listening: Bool,
        busy: Bool,
        failure: String?,
        ready: Bool
    ) -> StatusLight {
        if let failure, !failure.isEmpty { return .red(reason: failure) }
        if busy { return .amber(reason: "working") }
        if listening { return .green }
        return ready ? .off : .red(reason: "model not ready")
    }
}
