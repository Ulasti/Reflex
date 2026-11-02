import Foundation

/// Lightweight state holder for an incremental (streaming) utterance.
/// Tracks provisional transcript, revision count, finalization, and commit
/// status so the decision layer can reconcile partials with finalization.
public struct TranscriptEventBuffer: Sendable, Equatable {
    public var utteranceID: Int
    public var provisionalTranscript: String
    public var lastCommittedTranscript: String?
    public var revision: Int
    public var isFinalized: Bool
    public var isCommitted: Bool
    public var lastUpdate: Date

    public init(utteranceID: Int = 0) {
        self.utteranceID = utteranceID
        self.provisionalTranscript = ""
        self.lastCommittedTranscript = nil
        self.revision = 0
        self.isFinalized = false
        self.isCommitted = false
        self.lastUpdate = Date()
    }

    public mutating func startNew(utteranceID: Int) {
        self = TranscriptEventBuffer(utteranceID: utteranceID)
    }

    public mutating func update(_ transcript: String) {
        guard transcript != provisionalTranscript else { return }
        provisionalTranscript = transcript
        revision += 1
        lastUpdate = Date()
    }

    public mutating func markCommitted() { isCommitted = true }

    public mutating func finalize() { isFinalized = true }
}

/// Allowlist + helpers for the incremental commit gate (MVP).
public enum IncrementalCommitGate {
    public static let safeTargets: Set<String> = ["open_app", "media_control", "display_control"]

    public static func isEligible(target: String) -> Bool {
        safeTargets.contains(target)
    }
}
