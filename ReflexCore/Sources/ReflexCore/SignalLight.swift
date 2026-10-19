import Foundation

/// The feedback-light model behind the (eventual) whole UI: one color, one job.
///
/// - white (`armed`/`hearing`) — the mic is live, nothing needs you
/// - green (`executed`) — it acted, a transient event rather than a state
/// - amber (`waiting`) — the model is loading; you have to wait before it can listen
/// - red (`error`) — something is actually wrong (mic denied, model failed), kept
///   rare on purpose so seeing it means look now
/// - off — the mic is not live
///
/// Distinct from `StatusLight`, which still drives the notch pill and Settings.
public enum SignalLight: String, Sendable, Equatable {
    case off
    case armed
    case hearing
    case executed
    case waiting
    case error

    /// Priority order is the whole contract: a failure outranks a load, a load
    /// outranks a flash, and a flash outranks the resting listening state (so
    /// the "stop listening" command still confirms with a green flash before
    /// the light settles to `off`).
    public static func resolve(
        failure: String?,
        loading: Bool,
        flashActive: Bool,
        listening: Bool,
        hearing: Bool
    ) -> SignalLight {
        if let failure, !failure.isEmpty { return .error }
        if loading { return .waiting }
        if flashActive { return .executed }
        guard listening else { return .off }
        return hearing ? .hearing : .armed
    }
}
