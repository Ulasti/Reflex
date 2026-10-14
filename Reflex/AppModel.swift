import Foundation
import SwiftUI
#if os(macOS)
import CoreAudio
#endif
import AVFoundation
import ReflexCore
#if os(macOS)
import Carbon.HIToolbox
#endif

enum ModelLoadState: Equatable {
    case idle
    case loading(ReflexModelKind)
    case ready
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isReady: Bool { self == .ready }
}

@MainActor
final class AppModel: ObservableObject {
    private static let modelDefaultsKey = "activeModel"

    @Published var activeModel: ReflexModelKind = .whisperSmall
    @Published var forcedEnglish = true
    @Published var modelStatus = "Starting up…"
    @Published var loadState: ModelLoadState = .idle
    @Published var lastTranscript = ""
    @Published var lastDecision: ReflexDecision?
    @Published var lastResult: ReflexActionResult?
    @Published var isListening = false
    @Published var liveLevel: Float = 0
    @Published var isSpeaking = false
    @Published var liveText = ""
    #if os(macOS)
    @Published var micDevices: [MicDevice] = []
    @Published var selectedMicID: String?
    #endif

    /// Verbose mode: log every decision + action of a session as it happens.
    @Published var verboseLogging: Bool {
        didSet { UserDefaults.standard.set(verboseLogging, forKey: Self.verboseKey) }
    }
    /// Phase C feedback: play a short ding when an action completes/fails.
    @Published var shouldPlayFeedbackSounds: Bool {
        didSet { UserDefaults.standard.set(shouldPlayFeedbackSounds, forKey: Self.feedbackKey) }
    }
    /// Mute input while media is playing so system audio doesn't get dictated.
    /// Best-effort: polls NowPlaying for the active source's play state.
    @Published var suppressWhileMediaPlaying: Bool {
        didSet { UserDefaults.standard.set(suppressWhileMediaPlaying, forKey: Self.mediaSuppressKey) }
    }
    /// Completed sessions, newest first (persisted on disk).
    @Published var sessions: [SessionLog] = []
    /// The most recently completed session (what "copy last session" copies).
    var lastSession: SessionLog? { sessions.first }

    private static let verboseKey = "verboseLogging"
    private static let feedbackKey = "feedbackSounds"
    private static let mediaSuppressKey = "suppressWhileMediaPlaying"

    private let modelManager: ModelManager
    private let engine: ReflexSystemEngine
    private var micMonitor: MicMonitor?
    private var liveTranscriber: LiveTranscriber?
    private var liveUpdatesTask: Task<Void, Never>?
    private var processing = false
    private var currentSession: SessionLog?
    private var lastActionTime: Date?
    private let feedbackCooldown: TimeInterval = 1.0

    #if os(macOS)
    private var hotKeyID: UInt32 = 1
    #endif

    /// True while the active model is loading. Drives UI gating so the user
    /// can't switch models or listen mid-load.
    var isBusy: Bool { loadState.isLoading }

    /// Phase C status light: feeds the pulsing LED and the settings page.
    var statusLight: StatusLight {
        let failure: String?
        switch loadState {
        case .failed(let reason): failure = reason
        default: failure = nil
        }
        return StatusLight.resolve(
            listening: isListening,
            busy: isBusy || processing || (lastResult != nil && !isListening),
            failure: failure,
            ready: loadState.isReady
        )
    }

    init() {
        let dir = ReflexEnvironment.modelDirectory()
        modelManager = ModelManager(computeUnits: .cpuAndNeuralEngine, modelDirectory: dir)
        let transcriber = try? WhisperTranscriber(modelDirectory: dir)
        let layaRouter = try? LayaRouter(modelDirectory: dir)
        engine = ReflexSystemEngine(
            modelManager: modelManager,
            transcriber: transcriber,
            layaRouter: layaRouter
        )

        let saved = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
        activeModel = saved.flatMap(ReflexModelKind.init(rawValue:)) ?? .whisperSmall
        verboseLogging = UserDefaults.standard.bool(forKey: Self.verboseKey)
        shouldPlayFeedbackSounds = UserDefaults.standard.object(forKey: Self.feedbackKey) == nil
            ? true : UserDefaults.standard.bool(forKey: Self.feedbackKey)
        suppressWhileMediaPlaying = UserDefaults.standard.object(forKey: Self.mediaSuppressKey) == nil
            ? true : UserDefaults.standard.bool(forKey: Self.mediaSuppressKey)
        sessions = SessionLogStore.load()

        #if os(macOS)
        micDevices = MicPicker.list()
        #endif

        let kind = activeModel
        Task { await loadModel(kind) }

        #if os(macOS)
        _ = HotKeyCenter.register(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(cmdKey),
            id: hotKeyID
        ) { [weak self] in
            Task { @MainActor in self?.killSwitch() }
        }
        #endif

        if let path = ProcessInfo.processInfo.environment["REFLEX_SELFTEST"] {
            Task { await runSelfTest(path: path) }
        }
    }

    /// Called by the UI when the model picker changes. Persists the choice and
    /// begins loading the new variant into memory.
    func modelSelectionChanged(_ kind: ReflexModelKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: Self.modelDefaultsKey)
        guard !loadState.isLoading else { return }
        Task { await loadModel(kind) }
    }

    /// Compiles + warms `kind` into memory, updating `loadState` so the UI can
    /// show progress and block interaction until it's ready.
    func loadModel(_ kind: ReflexModelKind) async {
        loadState = .loading(kind)
        modelStatus = "Loading \(kind.displayName) into memory…"
        do {
            try await engine.preload(modelKind: kind)
            guard activeModel == kind else { return }
            loadState = .ready
            modelStatus = "Ready"
        } catch {
            loadState = .failed(error.localizedDescription)
            modelStatus = "Model load failed: \(error.localizedDescription)"
        }
    }

    private func runSelfTest(path: String) async {
        FileHandle.standardError.write("SELFTEST: loading \(path)\n".data(using: .utf8)!)
        do {
            let samples = try AudioFileLoader.loadSamples16kMono(url: URL(fileURLWithPath: path))
            FileHandle.standardError.write("SELFTEST: \(samples.count) samples, transcribing \(activeModel.displayName)\n".data(using: .utf8)!)
            let decision = try await engine.resolveCommandStream(
                samples: samples, modelKind: activeModel, forcedLanguage: "en"
            )
            FileHandle.standardError.write("SELFTEST: transcript=\(decision.transcript)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("SELFTEST error: \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    func verifyModels() async {
        do {
            try await modelManager.verifyCompilation()
            modelStatus = "All model packages compile cleanly"
        } catch {
            modelStatus = "Conversion required: \(error.localizedDescription)"
        }
    }

    // MARK: - Listening mode

    /// Mechanical kill switch, wired to ⌘P (global Carbon hotkey). Turns
    /// listening off; pressing again re-arms it.
    func killSwitch() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    func startListening() {
        guard loadState.isReady else {
            modelStatus = loadState.isLoading
                ? "Loading \(activeModel.displayName) into memory…"
                : "Model not ready"
            return
        }
        guard !isListening else { return }
        Task {
            let granted = await requestMicrophoneAccess()
            guard granted else {
                modelStatus = "Microphone access denied"
                return
            }

            if liveTranscriber == nil {
                let dir = ReflexEnvironment.modelDirectory()
                if ReflexWhisperKit.isInstalled(in: dir) {
                    liveTranscriber = try? await LiveTranscriber(
                        modelFolder: ReflexWhisperKit.modelFolder(in: dir)
                    )
                    await liveTranscriber?.warmup()
                } else {
                    modelStatus = "WhisperKit live not installed (run: reflex-cli --wk-install) — segmented mode"
                }
            }

            let usingLive = liveTranscriber != nil
            if usingLive {
                if let live = liveTranscriber {
                    liveUpdatesTask?.cancel()
                    liveUpdatesTask = Task { [weak self] in
                        for await update in live.updates {
                            self?.liveText = update.text
                        }
                    }
                }
            }

            let monitor: MicMonitor
            #if os(macOS)
            let selectedID: UInt32? = selectedMicID.flatMap(UInt32.init)
            monitor = MicMonitor(deviceID: selectedID)
            #else
            monitor = MicMonitor()
            #endif
            monitor.onSegment = { [weak self] samples in
                Task { @MainActor in self?.handleSegment(samples) }
            }
            monitor.onLevel = { [weak self] level, speaking in
                Task { @MainActor in
                    self?.liveLevel = level
                    self?.isSpeaking = speaking
                }
            }
            if usingLive {
                monitor.onPartial = { [weak self] partial in
                    Task { await self?.liveTranscriber?.consumePartial(partial) }
                }
            }
            do {
                try monitor.start()
                micMonitor = monitor
                isListening = true
                if verboseLogging {
                    currentSession = SessionLog(id: UUID(), startedAt: Date(), endedAt: nil, entries: [])
                }
                modelStatus = usingLive
                    ? "Listening (live as-you-speak) — ⌘P to kill"
                    : "Listening (segmented; install live: reflex-cli --wk-install) — ⌘P to kill"
            } catch {
                modelStatus = "Capture error: \(error.localizedDescription)"
            }
        }
    }

    func stopListening() {
        micMonitor?.stop()
        micMonitor = nil
        isListening = false
        isSpeaking = false
        liveLevel = 0
        liveText = ""
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil

        var logged = 0
        if let session = currentSession {
            var finished = session
            finished.endedAt = Date()
            if !finished.entries.isEmpty {
                logged = finished.entries.count
                sessions.insert(finished, at: 0)
                if sessions.count > 30 { sessions = Array(sessions.prefix(30)) }
                SessionLogStore.save(sessions)
            }
            currentSession = nil
        }
        modelStatus = logged > 0
            ? "Stopped — logged \(logged) entr\(logged == 1 ? "y" : "ies") — ⌘P to re-arm"
            : "Stopped — ⌘P to re-arm"
    }

    /// A finalized speech segment arrived. Runs it through the pipeline and
    /// auto-executes the resulting action. Segments heard while a prior one is
    /// still being processed are dropped; the mic keeps listening regardless.
    private func handleSegment(_ samples: [Float]) {
        if let t = lastActionTime, Date().timeIntervalSince(t) < feedbackCooldown {
            modelStatus = "Cooldown, ignoring feedback"
            return
        }
#if os(macOS)
        // System audio (Music, Safari, YouTube) is loud enough to trip the
        // VAD and gets dictated as "bell dings" etc. When media is actually
        // playing, drop the segment rather than route it.
        if suppressWhileMediaPlaying, NowPlaying.status().isPlaying {
            modelStatus = "Media playing, ignoring system audio"
            return
        }
#endif
        guard !processing else {
            modelStatus = "Busy, dropped a segment"
            return
        }
        processing = true
        modelStatus = "Deciding…"
        Task {
            do {
                if let live = liveTranscriber {
                    // Live mode: WhisperKit finalized the text already; route
                    // once here (partials shown in the UI are never routed).
                    let text = try await live.finalizeUtterance()
                    if text.isEmpty {
                        modelStatus = "No speech detected"
                    } else {
                        await resolveLiveTranscript(text)
                    }
                } else {
                    let decisions = try await engine.resolveCommandStreamCompound(
                        samples: samples,
                        modelKind: activeModel,
                        forcedLanguage: forcedEnglish ? "en" : "auto"
                    )
                    for decision in decisions {
                        lastTranscript = decision.transcript
                        lastDecision = decision
                        await dispatch(decision, mode: .segmented)
                        if case .stopped = lastResult { break }
                    }
                }
            } catch {
                modelStatus = "Pipeline: \(error.localizedDescription)"
            }
            processing = false
            if isListening {
                modelStatus = "Listening — ⌘P to kill"
            }
        }
    }

    /// Routes a WhisperKit-finalized transcript through Laya and executes.
    /// Compound utterances ("new note ... then open ...") expand into one gated
    /// decision per clause (A4) and execute in order.
    private func resolveLiveTranscript(_ text: String) async {
        do {
            let decisions = try await engine.resolveCompoundTranscript(text)
            for decision in decisions {
                lastTranscript = decision.transcript
                lastDecision = decision
                await dispatch(decision, mode: .live)
                if case .stopped = lastResult { break }
            }
        } catch {
            modelStatus = "Pipeline: \(error.localizedDescription)"
        }
    }

    /// Runs the macOS `ActionDispatcher` for a decision, surfaces the result,
    /// and — in verbose mode — records the whole decision + outcome into the
    /// current session log.
    private func dispatch(_ decision: ReflexDecision, mode: SessionLog.Mode) async {
        #if os(macOS)
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                return (try ActionDispatcher().dispatch(decision), nil) as (ReflexActionResult?, String?)
            } catch {
                return (nil, error.localizedDescription)
            }
        }.value
        let (result, failure) = outcome
        // Phase C feedback: a short ding on done, a lower tone on failure so
        // the user knows (without watching the screen) whether it acted.
        if let result {
            lastResult = result
            modelStatus = result.summary
            if shouldPlayFeedbackSounds, result.summary != "Stopped listening" {
                lastActionTime = Date()
                Self.playFeedbackDone()
            } else if result.summary != "Stopped listening" {
                lastActionTime = Date()
            }
        } else {
            modelStatus = "Execute failed: \(failure ?? "unknown error")"
            lastActionTime = Date()
            if shouldPlayFeedbackSounds {
                Self.playFeedbackFail()
            }
        }

        guard verboseLogging, var session = currentSession else { return }
        let outcomeText = result?.summary ?? "Execute failed: \(failure ?? "unknown error")"
        session.entries.append(SessionLog.Entry(
            id: UUID(),
            time: Date(),
            mode: mode,
            transcript: decision.transcript,
            target: decision.actionTarget.identifier,
            urgency: decision.urgencyScore.rawValue,
            confidenceLow: decision.confidence.lowerBound,
            confidenceHigh: decision.confidence.upperBound,
            layaTarget: decision.trace?.layaTarget,
            ruleTarget: decision.trace?.ruleTarget,
            chosen: decision.trace?.chosen,
            ambiguous: decision.trace?.ambiguous ?? false,
            result: outcomeText
        ))
        currentSession = session
        #else
        modelStatus = "Action dispatch is macOS-only for now"
        #endif
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    #if os(macOS)
    /// Phase C feedback tones: "Glass" (done) and "Sosumi" (failure) — the
    /// system sound list, no bundled assets needed.
    ///
    /// The input device is muted for the duration of the tone so the mic
    /// cannot hear its own feedback (MicMute). A software cooldown alone is
    /// not enough: the bell is loud enough to trip the VAD even through the
    /// cooldown, and a long cooldown makes the app feel sluggish.
    private static func playFeedbackDone() {
        MicMute.withInputMuted(nil) { NSSound(named: "Glass")?.play() }
    }

    private static func playFeedbackFail() {
        MicMute.withInputMuted(nil) { NSSound(named: "Sosumi")?.play() }
    }
    #else
    // iOS: silent feedback for now (no haptics wired in this pass).
    private static func playFeedbackDone() {}
    private static func playFeedbackFail() {}
    #endif
}
