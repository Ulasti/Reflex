import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

/// One live transcription event. `.partial` events carry the stabilized
/// half-decoded transcript while the user is still speaking; `.final` is the
/// committed text for an utterance and is the only event that should be
/// routed to Laya + the action dispatcher.
public struct LiveTextUpdate: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Locates WhisperKit's packed CoreML variants on disk, mirroring how
/// `tools/download_whisperkit_models.py` lays them out:
/// `<models>/whisperkit/<variant>/`.
public enum ReflexWhisperKit {
    public static let defaultVariant = "openai_whisper-small"

    /// The models root directory, honoring `REFLEX_MODELS` if set. The app
    /// target and diagnostics should use this so `--diagnose` checks the very
    /// same folder the live path will load from.
    ///
    /// Resolution order, first hit wins:
    /// 1. `REFLEX_MODELS`, so the CLI, the app, and the Python toolchain can
    ///    all be pointed at one directory.
    /// 2. `Models/` next to the repository root, derived from this file's
    ///    compile-time location (`#filePath`). A fresh clone resolves
    ///    correctly on the first rebuild.
    ///
    /// Never derive this from `$HOME`. The project has been relocated before
    /// and a home-relative path silently pointed at a directory that no longer
    /// existed, which made `--diagnose` report a missing model that was
    /// present. See Atlas Doctor D17.
    public static var defaultModelsDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["REFLEX_MODELS"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true).standardizedFileURL
        }
        #if os(macOS)
        // Sources/ReflexCore/ -> Sources/ -> ReflexCore/ -> repo root.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/ReflexCore/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // ReflexCore/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Models", isDirectory: true)
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #endif
    }

    public static func modelFolder(
        in modelsDirectory: URL,
        variant: String = defaultVariant
    ) -> URL {
        modelsDirectory
            .appendingPathComponent("whisperkit", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    public static func isInstalled(
        in modelsDirectory: URL,
        variant: String = defaultVariant
    ) -> Bool {
        let folder = modelFolder(in: modelsDirectory, variant: variant)
        let markers = ["config.json", "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        return markers.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}

/// Streaming transcriber built on WhisperKit's CoreML engine.
///
/// Whisper's decoder is incremental, not a state machine, so live partials use
/// the local-agreement policy: during speech the current VAD window is re-decoded
/// continuously (every ~0.35 s, far faster than realtime on Apple silicon) and
/// only the longest *stable* prefix that survives across passes is shown. The
/// audio comes in through Reflex's own `AudioCaptureManager`/`StreamSegmenter`
/// VAD; WhisperKit's recorder and VAD are deliberately not used so the ⌘P
/// kill-switch flow and EOU timing stay ours. `finalizeUtterance()` runs one
/// last decode and yields `.final`; a NE warmup decode at init removes the
/// first-command model load penalty.
public actor LiveTranscriber {
    public enum LiveError: LocalizedError, Equatable {
        case unavailable(String)
        case decodeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let message):
                "WhisperKit live models unavailable: \(message)"
            case .decodeFailed(let message):
                "WhisperKit decode failed: \(message)"
            }
        }
    }

    /// Minimum seconds between partial decodes. 100 ms audio windows arrive
    /// much faster than we want to run the encoder, so consumers feed at
    /// whatever cadence they like and own transcriber throttles.
    public let partialInterval: Double

    private var wk: WhisperKit?
    nonisolated let updatedStream: AsyncStream<LiveTextUpdate>
    nonisolated let updatedContinuation: AsyncStream<LiveTextUpdate>.Continuation

    /// Rolling samples for the current utterance (16 kHz mono float).
    private var rolling: [Float] = []
    /// Text of the most recent stabilized partial (longest common prefix).
    private var stablePartial = ""
    private var lastPartialEmitted = ""
    /// When the last decode pass finished (wall clock, seconds since 2001).
    private var lastDecodeTimestamp: Double = 0
    private var inUtterance = false

    /// Live events. Set up one consumer before calling `consumePartial`.
    public nonisolated var updates: AsyncStream<LiveTextUpdate> { updatedStream }

    public init(
        modelFolder: URL,
        partialInterval: Double = 0.35
    ) async throws {
        self.partialInterval = partialInterval
        (updatedStream, updatedContinuation) = AsyncStream<LiveTextUpdate>.makeStream()

        let markers = ["config.json", "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let missing = markers.filter { !FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw LiveError.unavailable("no pack at \(modelFolder.path) (missing \(missing.joined(separator: ", ")))")
        }

        let instance: WhisperKit
        do {
            instance = try await WhisperKit(
                downloadBase: modelFolder,
                modelFolder: modelFolder.path,
                tokenizerFolder: modelFolder,
                prewarm: true,
                load: true,
                download: false
            )
        } catch {
            throw LiveError.unavailable(error.localizedDescription)
        }
        self.wk = instance
    }

    deinit {
        updatedContinuation.finish()
    }

    // MARK: - Utterance lifecycle

    private var didWarmup = false

    /// One short blank decode to bring the Neural Engine (and full model graph)
    /// out of its cold state. Call once after init; the first partial then
    /// decodes in tens of milliseconds instead of seconds.
    public func warmup() async {
        guard !didWarmup else { return }
        didWarmup = true
        rolling = Array(repeating: 0.0, count: 3200)
        _ = try? await decodeOnce(publishPartial: false)
        rolling = []
        stablePartial = ""
        lastPartialEmitted = ""
        inUtterance = false
        lastDecodeTimestamp = 0
    }

    /// Starts a fresh utterance. Partial windows stream in via `consumePartial`
    /// until the caller's VAD finalizes, then `finalizeUtterance` commits.
    public func beginUtterance() {
        rolling = []
        stablePartial = ""
        lastPartialEmitted = ""
        lastDecodeTimestamp = 0
        inUtterance = true
    }

    /// The VAD's current rolling window for the utterance mid-speech (the
    /// whole speech run so far, bounded by the segmenter's cap).
    public func consumePartial(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        if !inUtterance { beginUtterance() }
        rolling = samples

        // Sub-second clock: floor() quantized this to whole seconds, so the
        // 0.35 s interval actually fired about once per second (plan Phase 1).
        let now = Date().timeIntervalSinceReferenceDate
        guard lastDecodeTimestamp == 0 || now - lastDecodeTimestamp >= partialInterval else {
            return
        }
        _ = try? await decodeOnce(publishPartial: true)
    }

    /// Runs the final decode of the utterance and emits `.final`. Returns the
    /// committed text (may be empty for a rejected/no-speech window).
    @discardableResult
    public func finalizeUtterance() async throws -> String {
        guard inUtterance else { return "" }
        defer { inUtterance = false }
        // Nothing from this utterance may survive it. The VAD can start the
        // next speech run before the app has dispatched this text, and a stale
        // rolling buffer decoded twice is how the previous utterance's words
        // turned up inside the next transcript (live session log: "Open
        // YouTube.com. Open a new tab" arrived as one carried-over line).
        defer {
            rolling = []
            stablePartial = ""
            lastPartialEmitted = ""
        }
        guard !rolling.isEmpty else {
            emitComponent(.init(text: "", isFinal: true))
            return ""
        }

        let text = (try? await decodeOnce(publishPartial: false)) ?? ""

        // If the final decode rejected the audio (no-speech prob high) but the
        // VAD had insisted on speech, prefer the last stabilized partial.
        let committed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty, !lastPartialEmitted.isEmpty {
            let fallback = lastPartialEmitted
            emitComponent(.init(text: fallback, isFinal: true))
            return fallback
        }
        emitComponent(.init(text: committed, isFinal: true))
        return committed
    }

    // MARK: - Decode

    private func decodeOnce(publishPartial: Bool) async throws -> String {
        lastDecodeTimestamp = Date().timeIntervalSinceReferenceDate
        guard let wk else { throw LiveError.unavailable("not loaded") }
        guard !rolling.isEmpty else {
            if publishPartial { emitComponent(.init(text: "", isFinal: false)) }
            return ""
        }

        var options = DecodingOptions(
            verbose: false,
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: false,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true
        )
        options.language = "en"
        let results: [TranscriptionResult]
        do {
            results = try await wk.transcribe(
                audioArray: Self.decodeAudio(rolling),
                decodeOptions: options,
                callback: nil
            )
        } catch {
            throw LiveError.decodeFailed(error.localizedDescription)
        }

        let full = Self.clean((results.first?.text ?? ""))

        if publishPartial {
            // Local-agreement stabilization: only surface text that survives
            // as a prefix of the previous pass, so live output never rewinds.
            stablePartial = longestCommonPrefix(left: stablePartial, right: full)
            let candidate = stablePartial.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate != lastPartialEmitted, !candidate.isEmpty {
                lastPartialEmitted = candidate
                emitComponent(.init(text: candidate, isFinal: false))
            } else if candidate.isEmpty, !full.isEmpty {
                // First pass: nothing stable yet — show the raw text.
                lastPartialEmitted = full
                emitComponent(.init(text: full, isFinal: false))
            }
        }
        return full
    }

    private func longestCommonPrefix(left: String, right: String) -> String {
        let lhs = Array(left)
        let rhs = Array(right)
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count == 0 ? "" : String(lhs[0..<count])
    }

    /// WhisperKit decodes nothing for windows under ~1.1 s (verified: 1.00 s
    /// and 1.05 s return empty, 1.10 s decodes), so short commands like
    /// "copy" or "pause" were silently dropped. Whisper pads to 30 s anyway,
    /// so padding here costs nothing.
    static func decodeAudio(_ window: [Float]) -> [Float] {
        let minimum = 48_000 // 3 s of headroom
        return window.count >= minimum
            ? window
            : window + Array(repeating: 0, count: minimum - window.count)
    }

    /// Whisper emits non-speech markers ("[BLANK_AUDIO]", "[MUSIC]") that are
    /// not transcript; drop them so routing never sees them.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emitComponent(_ update: LiveTextUpdate) {
        updatedContinuation.yield(update)
    }
}
