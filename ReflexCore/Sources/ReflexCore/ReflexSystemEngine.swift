import Foundation
import CoreML
import AVFoundation

/// System 1 orchestration layer. Runs the full sub-50ms pipeline:
/// Whisper transcription with hardcoded language token constraints,
/// then a single-pass Laya structural evaluation.
public actor ReflexSystemEngine {
    private let modelManager: ModelManager
    private let transcriber: WhisperTranscriber?
    private let layaRouter: LayaRouter?

    public init(
        modelManager: ModelManager,
        transcriber: WhisperTranscriber?,
        layaRouter: LayaRouter? = nil
    ) {
        self.modelManager = modelManager
        self.transcriber = transcriber
        self.layaRouter = layaRouter
    }

    /// Warms the active Whisper pair into memory (plus the Laya router, best
    /// effort) so the next `resolveCommandStream` skips the load cost.
    public func preload(modelKind: ReflexModelKind) async throws {
        guard let transcriber else {
            throw ReflexSystemEngineError.transcriberUnavailable
        }
        try await transcriber.preload(modelKind)
        try? await layaRouter?.preload()
    }

    /// Executes the primary text-resolution pipeline.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono float PCM captured from the audio tap.
    ///   - modelKind: Active Whisper variant (hot-swappable based on power mode).
    ///   - forcedLanguage: ISO-639-1 code. Passing "en" bypasses the LID
    ///     forward pass, fixing the start tokens for deterministic syntax.
    public func resolveCommandStream(
        samples: [Float],
        modelKind: ReflexModelKind,
        forcedLanguage: String
    ) async throws -> ReflexDecision {
        let textResult = try await runCoreMLWhisper(
            samples: samples,
            modelKind: modelKind,
            languageCode: forcedLanguage
        )
        let decisions = try await resolveCompoundTranscript(textResult)
        return decisions.first ?? ReflexDecision(
            actionTarget: ReflexChoice("general_query"),
            urgencyScore: ReflexScore(0),
            confidence: ReflexNoul(lowerBound: 0, upperBound: 0),
            transcript: textResult
        )
    }

    /// Segmented-path compound variant: transcribes the audio, then expands the
    /// utterance into one decision per clause (A4) exactly like the live path.
    public func resolveCommandStreamCompound(
        samples: [Float],
        modelKind: ReflexModelKind,
        forcedLanguage: String
    ) async throws -> [ReflexDecision] {
        let textResult = try await runCoreMLWhisper(
            samples: samples,
            modelKind: modelKind,
            languageCode: forcedLanguage
        )
        return try await resolveCompoundTranscript(textResult)
    }

    /// Live-listening path: the transcript was already produced incrementally
    /// by `LiveTranscriber`, so only Laya + the arbiter remain. Must be called
    /// once per finalized utterance, never on partial text.
    public func resolveLiveTranscript(_ transcript: String) async throws -> ReflexDecision {
        let normalized = TranscriptNormalizer.normalize(transcript)
        guard !normalized.isEmpty else {
            throw ReflexSystemEngineError.emptyTranscript
        }
        guard !Self.isSilenceMarker(normalized) else {
            throw ReflexSystemEngineError.silenceDetected
        }
        return try await runCoreMLLaya(text: normalized)
    }

    /// A4 compound expansion: splits an utterance on "and then"/"then"/"and"/
    /// "and also" into independent clauses, routes *each* clause through Laya +
    /// the arbiter, and returns one gated decision per clause (executed in
    /// order by the dispatcher). A non-compound transcript yields a single
    /// decision, so callers replace `resolveLiveTranscript` with this without
    /// changing single-command behavior.
    public func resolveCompoundTranscript(_ transcript: String) async throws -> [ReflexDecision] {
        let normalized = TranscriptNormalizer.normalize(transcript)
        guard !normalized.isEmpty else {
            throw ReflexSystemEngineError.emptyTranscript
        }
        guard !Self.isSilenceMarker(normalized) else {
            throw ReflexSystemEngineError.silenceDetected
        }
        guard CompoundRouter.isCompound(normalized) else {
            return [try await runCoreMLLaya(text: normalized)]
        }
        let parts = CompoundRouter.split(normalized)
        var decisions: [ReflexDecision] = []
        for part in parts {
            let clause = TranscriptNormalizer.normalize(part.transcript)
            guard !clause.isEmpty, !Self.isSilenceMarker(clause) else { continue }
            let decision = try await runCoreMLLaya(text: clause)
            decisions.append(decision)
        }
        if decisions.isEmpty {
            throw ReflexSystemEngineError.emptyTranscript
        }
        return decisions
    }

    private func runCoreMLWhisper(
        samples: [Float],
        modelKind: ReflexModelKind,
        languageCode: String
    ) async throws -> String {
        guard let transcriber else {
            throw ReflexSystemEngineError.transcriberUnavailable
        }
        let language = languageCode == "auto" ? "en" : languageCode
        return try await transcriber.transcribe(
            samples: samples,
            modelKind: modelKind,
            language: language
        )
    }

    private func runCoreMLLaya(text: String) async throws -> ReflexDecision {
        // Phase 3 latency short-circuit: a strong rule decides on its own, so
        // the Laya forward pass (a CoreML run the arbiter would only confirm)
        // never happens. Measured route stage 227 ms -> microseconds; the
        // baseline showed Laya rescuing 0 of 145 rule misses, so nothing is
        // lost for a rule that already fires at >= 0.9.
        // REFLEX_FORCE_LAYA=1 disables the skip so the ablation can still
        // measure the Laya lane; it is a measurement switch, not a runtime mode.
        let forceLaya = ProcessInfo.processInfo.environment["REFLEX_FORCE_LAYA"] != nil
        if !forceLaya, let rule = RuleRouter().classify(text), rule.isDecisive {
            return ruleDecision(rule, text: text)
        }
        guard let layaRouter else {
            throw ReflexSystemEngineError.layaUnavailable
        }
        let routing = try await layaRouter.route(transcript: text)

        guard
            let action = routing.answer("action"),
            case let .choice(layaTarget, _) = action.value
        else {
            throw ReflexSystemEngineError.missingChoice
        }

        let arbiter = DecisionArbiter()
        let (target, confidence, addressed, trace) = arbiter.decide(
            layaTarget: layaTarget,
            layaConfidence: action.confidence,
            transcript: text
        )

        var urgency = 0
        if let answer = routing.answer("urgency"), case let .score(expected) = answer.value {
            let levels = max(1, answer.probabilities.count - 1)
            urgency = Int((expected / Double(levels) * 100).rounded())
        }

        let top1 = action.probabilities.max() ?? action.confidence
        let bounds = ReflexNoul(
            lowerBound: min(top1, action.confidence),
            upperBound: max(top1, action.confidence)
        )

        // A3: confidence floor + addressed gate at engine level for live paths
        if !arbiter.shouldExecute(confidence: confidence, addressed: addressed) {
            return ReflexDecision(
                actionTarget: ReflexChoice("general_query"),
                urgencyScore: ReflexScore(0),
                confidence: bounds,
                transcript: text,
                trace: trace,
                confidenceValue: confidence,
                addressed: addressed,
                layaConfidence: action.confidence
            )
        }

        return ReflexDecision(
            actionTarget: ReflexChoice(target),
            urgencyScore: ReflexScore(urgency),
            confidence: bounds,
            transcript: text,
            trace: trace,
            confidenceValue: confidence,
            addressed: addressed,
            layaConfidence: action.confidence
        )
    }

    /// A rule-only decision: the rule's target at its own confidence, no Laya
    /// forward pass, nothing left ambiguous (the rule is deterministic).
    private func ruleDecision(_ rule: RuleDecision, text: String) -> ReflexDecision {
        let trace = RoutingTrace(
            layaTarget: "skipped",
            ruleTarget: rule.target,
            chosen: rule.target,
            ambiguous: false
        )
        return ReflexDecision(
            actionTarget: ReflexChoice(rule.target),
            urgencyScore: ReflexScore(0),
            confidence: ReflexNoul(lowerBound: rule.confidence, upperBound: rule.confidence),
            transcript: text,
            trace: trace,
            confidenceValue: rule.confidence,
            addressed: 1.0,
            layaConfidence: 0
        )
    }

    /// Whisper's silence/music placeholder tokens — "[Silence]",
    /// "[BLANK_AUDIO]", "[Music]", "[ _blank_]", etc. — are emitted as literal
    /// bracketed text and must never be routed as a command. Anything in
    /// square brackets with no command-like payload is treated as non-speech.
    /// Bare words like "music" are intentionally NOT filtered ("play some
    /// music" is a real command).
    static func isSilenceMarker(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = cleaned.lowercased()
        let bracketed = cleaned.hasPrefix("[") && cleaned.hasSuffix("]")
        // The utterance must *be* the marker: "silence it" is mute, not silence.
        let bare = lowered.trimmingCharacters(in: CharacterSet(charactersIn: " ().,!?;"))
        let highSignal = ["silence", "silent", "no speech", "inaudible", "applause"].contains(bare)
        return bracketed || highSignal
    }
}

public enum ReflexSystemEngineError: LocalizedError {
    case transcriberUnavailable
    case layaUnavailable
    case missingChoice
    case emptyTranscript
    case silenceDetected

    public var errorDescription: String? {
        switch self {
        case .transcriberUnavailable: "Whisper transcriber could not be initialized."
        case .layaUnavailable: "Laya router could not be initialized."
        case .missingChoice: "Laya produced no action-target choice."
        case .emptyTranscript: "Whisper returned an empty transcript."
        case .silenceDetected: "That was silence, not a command — nothing dispatched."
        }
    }
}
