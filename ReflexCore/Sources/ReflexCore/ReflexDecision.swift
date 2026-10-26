import Foundation

/// `Choice` primitive: a category identifier string produced by the Laya
/// evaluation heads. Strongly typed so routing is switch-friendly.
public struct ReflexChoice: Hashable, Sendable {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }
}

/// `Score` primitive: an integer out of 100 representing urgency or the
/// bounds of a UI layout scale.
public struct ReflexScore: Hashable, Sendable {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// `Noul` primitive: an exact continuous confidence range in [0, 1].
public struct ReflexNoul: Hashable, Sendable {
    public let lowerBound: Double
    public let upperBound: Double

    public init(lowerBound: Double, upperBound: Double) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var midpoint: Double {
        (lowerBound + upperBound) / 2
    }
}

/// The composed output of a single Reflex evaluation pass, mirroring the
/// Laya single-pass matrix selection: one `Choice`, one `Score`, one `Noul`.
public struct ReflexDecision: Sendable {
    public let actionTarget: ReflexChoice
    public let urgencyScore: ReflexScore
    public let confidence: ReflexNoul
    public let transcript: String
    public let trace: RoutingTrace?
    /// The arbiter's final executed confidence (rule ≥0.9 overrides a weak
    /// Laya call). Drives the no-op gate.
    public let confidenceValue: Double
    /// Continuous "is the user talking to Reflex?" confidence from the arbiter.
    public let addressed: Double
    /// Laya's raw action confidence, before the arbiter's rule override and
    /// the execute gate. Only the replay harness's ablation reads this.
    public let layaConfidence: Double

    public init(
        actionTarget: ReflexChoice,
        urgencyScore: ReflexScore,
        confidence: ReflexNoul,
        transcript: String,
        trace: RoutingTrace? = nil,
        confidenceValue: Double? = nil,
        addressed: Double? = nil,
        layaConfidence: Double = 0
    ) {
        self.actionTarget = actionTarget
        self.urgencyScore = urgencyScore
        self.confidence = confidence
        self.transcript = transcript
        self.trace = trace
        self.confidenceValue = confidenceValue ?? confidence.midpoint
        self.addressed = addressed ?? self.confidenceValue
        self.layaConfidence = layaConfidence
    }
}
