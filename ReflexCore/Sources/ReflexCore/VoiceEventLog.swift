import Foundation

/// Append-only, monotonic event log for voice-command lifecycle observability.
/// Uses ContinuousClock (monotonic) for all durations; wall-clock is stored
/// separately for human correlation only.
public struct VoiceEvent: Sendable, Codable, Equatable {
    public let sessionID: UUID
    public let utteranceID: Int
    public let commandID: UUID
    public let eventType: String
    public let monotonicNanos: UInt64
    public let wallClock: Date
    public let executionPath: String?
    public let transcriptRevision: Int?
    public let detail: String?

    // Phase 0 canonical schema additions (all optional for backward compat).
    public let stage: String?
    public let latencyMs: Double?
    public let correlationId: UUID?
    public let outcome: String?

    public init(
        sessionID: UUID,
        utteranceID: Int,
        commandID: UUID,
        eventType: String,
        monotonicNanos: UInt64,
        wallClock: Date = Date(),
        executionPath: String? = nil,
        transcriptRevision: Int? = nil,
        detail: String? = nil,
        stage: String? = nil,
        latencyMs: Double? = nil,
        correlationId: UUID? = nil,
        outcome: String? = nil
    ) {
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.commandID = commandID
        self.eventType = eventType
        self.monotonicNanos = monotonicNanos
        self.wallClock = wallClock
        self.executionPath = executionPath
        self.transcriptRevision = transcriptRevision
        self.detail = detail
        self.stage = stage
        self.latencyMs = latencyMs
        self.correlationId = correlationId
        self.outcome = outcome
    }
}

/// Buffered, append-only event sink. Thread-safe via a serial queue.
public final class VoiceEventLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "reflex.voiceevent", qos: .utility)
    private var events: [VoiceEvent] = []
    private let clock = ContinuousClock()

    public init() {}

    private let baseline = ContinuousClock.now

    public func monotonicNanos() -> UInt64 {
        let elapsed = baseline.duration(to: ContinuousClock.now)
        let comps = elapsed.components
        return UInt64(comps.seconds) * 1_000_000_000 + UInt64(comps.attoseconds / 1_000_000_000)
    }

    public func record(_ event: VoiceEvent) {
        queue.async { self.events.append(event) }
    }

    public func snapshot() -> [VoiceEvent] {
        queue.sync { events }
    }

    public func clear() { queue.async { self.events.removeAll() } }
}
