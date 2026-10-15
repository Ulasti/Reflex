import AVFoundation
import CoreML
import Foundation
import ReflexCore

@main
struct ReflexCLI {
    static func main() async {
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "--mel" {
            do {
                let samples = try AudioFileLoader.loadSamples16kMono(url: URL(fileURLWithPath: args[2]))
                let mel = try WhisperMel(nMel: args.count > 4 ? Int(args[4]) ?? 80 : 80)
                let values = mel.logMel(samples: samples)
                try Data(bytes: values, count: values.count * MemoryLayout<Float>.size)
                    .write(to: URL(fileURLWithPath: args[3]))
                print("wrote \(values.count) mel floats -> \(args[3])")
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 3, args[1] == "--record" {
            let seconds = Double(args[2]) ?? 3
            let capture = AudioCaptureManager()
            do {
                try capture.start()
                print("recording \(seconds)s...")
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                let samples = capture.stop()
                print("captured \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / 16000))s)")
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 3, args[1] == "--tokenize" {
            do {
                let tokenizer = try LayaTokenizer()
                let text = args[2...].joined(separator: " ")
                let ids = tokenizer.encode(text)
                print(ids.map(String.init).joined(separator: ","))
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 3, args[1] == "--laya" {
            let transcript = args[2...].joined(separator: " ")
            do {
                let router = try makeLayaRouter()
                let routing = try await router.route(transcript: transcript)
                printRouting(routing)
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 3, args[1] == "--laya-bench" {
            let iterations = Int(args[2]) ?? 5
            let transcript = args.count > 3 ? args[3...].joined(separator: " ") : "open safari"
            do {
                let router = try makeLayaRouter()
                try await router.preload()
                let start = Date()
                for _ in 0..<iterations { _ = try await router.route(transcript: transcript) }
                let ms = Date().timeIntervalSince(start) * 1000
                print(String(format: "%d routes in %.1f ms (%.1f ms/route)", iterations, ms, ms / Double(iterations)))
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 3, args[1] == "--laya-ref" {
            do {
                try await runLayaReference(path: args[2])
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 2, args[1] == "--verify" {
            let modelsDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : defaultModelsDirectory()
            do {
                let manager = ModelManager(modelDirectory: modelsDir)
                print("verifying all packages...")
                try await manager.verifyCompilation()
                print("verify OK")
            } catch {
                // Exit non-zero: this command is the project's build-blocking
                // verification step, so a script must be able to trust it.
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }

        if args.count >= 3, args[1] == "--pipeline" {
            let runRequested = args.contains("--run")
            let positionals = args.dropFirst(3).filter { $0 != "--run" }
            let variant = positionals.count >= 1 ? positionals[0] : "base"
            let modelsDir = positionals.count >= 2 ? URL(fileURLWithPath: positionals[1]) : defaultModelsDirectory()
            do {
                let samples = try AudioFileLoader.loadSamples16kMono(url: URL(fileURLWithPath: args[2]))
                guard let kind = ReflexModelKind(rawValue: "whisper-\(variant)") else {
                    print("unknown variant"); return
                }
                let manager = ModelManager(modelDirectory: modelsDir)
                let transcriber = try WhisperTranscriber(modelDirectory: modelsDir)
                let layaRouter = try LayaRouter(modelDirectory: modelsDir)
                let engine = ReflexSystemEngine(
                    modelManager: manager,
                    transcriber: transcriber,
                    layaRouter: layaRouter
                )
                print("running pipeline...")
                let decision = try await engine.resolveCommandStream(
                    samples: samples, modelKind: kind, forcedLanguage: "en"
                )
                print("transcript: \(decision.transcript)")
                print("target: \(decision.actionTarget.identifier)")
                if runRequested {
                    do {
                        let result = try ActionDispatcher().dispatch(decision)
                        print("result: \(result.summary)")
                    } catch {
                        print("result: error: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 4, args[1] == "--action" {
            let target = args[2]
            let transcript = args[3...].joined(separator: " ")
            do {
                // Explicit manual test: run the action regardless of the
                // automatic confidence floor (the floor is still applied to
                // real routed decisions via the arbiter's confidenceValue).
                let decision = ReflexDecision(
                    actionTarget: ReflexChoice(target),
                    urgencyScore: ReflexScore(0),
                    confidence: ReflexNoul(lowerBound: 0, upperBound: 0),
                    transcript: transcript,
                    confidenceValue: 1.0,
                    addressed: 1.0
                )
                let result = try ActionDispatcher().dispatch(decision)
                print("result: \(result.summary)")
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 2, args[1] == "--shortcuts" {
            // B1 sanity: dump the catalog + canonical-name resolution for a
            // transcript (defaults to printing every mapped criteria phrase).
            let transcript = args.count > 2 ? args[2...].joined(separator: " ") : ""
            if !transcript.isEmpty {
                if let name = ShortcutController.canonicalName(in: transcript) {
                    print("shortcut: \(name)")
                } else {
                    print("shortcut: none")
                }
                return
            }
            for shortcut in ShortcutController.catalog {
                let code = shortcut.keyCode.map { "code \($0)" } ?? shortcut.keyChar.map { "char \"\($0)\"" } ?? "?"
                print("\(shortcut.name): \(code)\(shortcut.modifiers.isEmpty ? "" : " \(shortcut.modifiers.joined(separator: "+"))")")
            }
            return
        }

        if args.count >= 3, args[1] == "--plan" {
            // A2/A4: route a transcript like the engine does (rule+Laya arbiter)
            // and print the typed CommandPlan the dispatcher would execute.
            let transcript = args[2...].joined(separator: " ")
            do {
                let decision = try await routedDecision(transcript)
                let plan = CommandPlan.make(
                    target: decision.actionTarget.identifier,
                    transcript: decision.transcript
                )
                print("transcript: \(plan.transcript)")
                print("action: \(plan.action) (conf \(String(format: "%.2f", decision.confidenceValue)), addressed \(String(format: "%.2f", decision.addressed)))")
                print("submit: \(plan.submit), inApp: \(plan.candidates.inApp ?? "-")")
                let args = plan.args.sorted { $0.key < $1.key }
                if args.isEmpty {
                    print("args: none")
                } else {
                    for (key, value) in args { print("  \(key): \(value)") }
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 3, args[1] == "--compound" {
            // A4: split an utterance and route each clause independently.
            let transcript = args[2...].joined(separator: " ")
            do {
                let normalized = TranscriptNormalizer.normalize(transcript)
                let parts = CompoundRouter.isCompound(normalized) ? CompoundRouter.split(normalized) : [.init(transcript: normalized, submit: false)]
                print("\(parts.count) clause(s)")
                for (index, part) in parts.enumerated() {
                    let decision = try await routedDecision(part.transcript)
                    let plan = CommandPlan.make(
                        target: decision.actionTarget.identifier,
                        transcript: decision.transcript
                    )
                    var line = "[\(index + 1)] \(part.transcript) -> \(plan.action) (conf \(String(format: "%.2f", decision.confidenceValue)))"
                    if part.submit { line += " +submit" }
                    print(line)
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 2, args[1] == "--diagnose" {
            runDiagnose()
            return
        }

        if args.count >= 2, args[1] == "--rule" {
            let transcript = args[2...].joined(separator: " ")
            let normalized = TranscriptNormalizer.normalize(transcript)
            print("normalized: \(normalized)")
            if let rule = RuleRouter().classify(normalized) {
                print("rule: \(rule.target) (conf \(rule.confidence))")
            } else {
                print("rule: none")
            }
            return
        }

        if args.count >= 2, args[1] == "--listen" {
            let runRequested = args.contains("--run")
            let useWK = args.contains("--wk")
            let rest = args.dropFirst(2).filter { $0 != "--run" && $0 != "--wk" }
            let variant = rest.first ?? "small"
            do {
                if useWK {
                    try await runListenWK(variant: variant, runRequested: runRequested)
                } else {
                    try await runListen(variant: variant, runRequested: runRequested)
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 3, args[1] == "--vlive" {
            let runRequested = args.contains("--run")
            let useWK = args.contains("--wk")
            let rest = args.dropFirst(3).filter { $0 != "--run" && $0 != "--wk" }
            let variant = rest.first ?? "small"
            do {
                let samples = try AudioFileLoader.loadSamples16kMono(url: URL(fileURLWithPath: args[2]))
                let engine = try makeEngine()
                let segmenter = StreamSegmenter()
                nonisolated(unsafe) var segments: [[Float]] = []
                segmenter.onSegment = { segments.append($0) }

                if useWK {
                    try await runVliveWK(
                        samples: samples,
                        engine: engine,
                        runRequested: runRequested,
                        variant: variant,
                        segmenter: segmenter
                    )
                } else {
                    let kind = try kind(for: variant)
                    let chunk = 4096
                    var offset = 0
                    while offset < samples.count {
                        segmenter.feed(Array(samples[offset..<min(offset + chunk, samples.count)]))
                        offset += chunk
                    }
                    segmenter.flush()
                    print("\(segments.count) speech segment(s) found")
                    for (index, segment) in segments.enumerated() {
                        print("[\(index + 1)] running pipeline on \(String(format: "%.2f", Double(segment.count) / 16000))s…")
                        try await runSegment(engine, segment, kind, runRequested: runRequested)
                    }
                    if segments.isEmpty { print("no speech detected in file") }
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 2, args[1] == "--wk-install" {
            let rest = args.dropFirst(2)
            let variant = rest.first ?? "small"
            let modelsDir = rest.count > 1 ? rest[1] : defaultModelsDirectory().path
            do {
                try runWKInstall(variant: variant, modelsDir: modelsDir)
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        if args.count >= 2, args[1] == "--dispatch" {
            let transcript = args[2...].joined(separator: " ")
            do {
                let routing = try await makeLayaRouter().route(transcript: transcript)
                guard let action = routing.answer("action"), case let .choice(label, _) = action.value else {
                    print("no action choice"); return
                }
                let (target, conf, addressed, trace) = DecisionArbiter().decide(
                    layaTarget: label,
                    layaConfidence: action.confidence,
                    transcript: transcript
                )
                print("target: \(target) (laya: \(trace.layaTarget), rule: \(trace.ruleTarget ?? "-"))")
                if trace.ambiguous { print("note: ambiguous — confirm before executing") }
                let decision = ReflexDecision(
                    actionTarget: ReflexChoice(target),
                    urgencyScore: ReflexScore(0),
                    confidence: ReflexNoul(lowerBound: 0, upperBound: 0),
                    transcript: transcript,
                    trace: trace,
                    confidenceValue: conf,
                    addressed: addressed
                )
                let result = try ActionDispatcher().dispatch(decision)
                print("result: \(result.summary)")
            } catch {
                print("error: \(error.localizedDescription)")
            }
            return
        }

        guard args.count >= 2, args[1] != "--help" else {
            print("""
            usage: reflex-cli <audio-file> [base|small|large-v3-turbo] [models-dir]
                   reflex-cli --pipeline <audio-file> [variant] [models-dir]
                   reflex-cli --laya <transcript...>
                   reflex-cli --dispatch <transcript...>
                   reflex-cli --action <target> <transcript...>
                   reflex-cli --laya-bench <iterations> [transcript...]
                   reflex-cli --laya-ref <reference.json>
                   reflex-cli --vlive <audio-file> [variant] [--run] [--wk]
                   reflex-cli --listen [variant] [--run] [--wk]
                   reflex-cli --wk-install [variant] [models-dir]
                   reflex-cli --tokenize <text...>
                   reflex-cli --rule <transcript...>
                   reflex-cli --mel <wav> <out.bin> [n_mels]
                   reflex-cli --record <seconds>
                   reflex-cli --verify [models-dir]
            """)
            return
        }

        let audioURL = URL(fileURLWithPath: args[1])
        let variant = args.count > 2 ? args[2] : "base"
        let modelsDir = args.count > 3
            ? URL(fileURLWithPath: args[3])
            : defaultModelsDirectory()

        guard let kind = ReflexModelKind(rawValue: "whisper-\(variant)") else {
            print("unknown variant '\(variant)'")
            return
        }

        do {
            let samples = try AudioFileLoader.loadSamples16kMono(url: audioURL)
            print("audio: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / 16000))s), model: \(kind.displayName)")

            let transcriber = try WhisperTranscriber(modelDirectory: modelsDir)
            let start = Date()
            let text = try await transcriber.transcribe(samples: samples, modelKind: kind)
            let elapsed = Date().timeIntervalSince(start)

            print("transcript: \(text.isEmpty ? "<empty>" : text)")
            print(String(format: "elapsed: %.0f ms", elapsed * 1000))
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    static func kind(for variant: String) throws -> ReflexModelKind {
        guard let kind = ReflexModelKind(rawValue: "whisper-\(variant)") else {
            throw CLIError(message: "unknown variant '\(variant)'")
        }
        return kind
    }

    static func runSegment(
        _ engine: ReflexSystemEngine,
        _ samples: [Float],
        _ kind: ReflexModelKind,
        runRequested: Bool
    ) async throws {
        let decision = try await engine.resolveCommandStream(
            samples: samples, modelKind: kind, forcedLanguage: "en"
        )
        print("  transcript: \(decision.transcript)")
        print("  target: \(decision.actionTarget.identifier)")
        if let trace = decision.trace {
            let rule = trace.ruleTarget ?? "-"
            print("  trace: Laya=\(trace.layaTarget) rule=\(rule)\(trace.ambiguous ? " (ambiguous)" : "")")
        }
        if runRequested {
            let result = try ActionDispatcher().dispatch(decision)
            print("  result: \(result.summary)")
        }
    }

    static func runListen(variant: String, runRequested: Bool) async throws {
        let kind = try kind(for: variant)
        let transcriber = try WhisperTranscriber(modelDirectory: defaultModelsDirectory())
        let layaRouter = try LayaRouter(modelDirectory: defaultModelsDirectory())
        let engine = ReflexSystemEngine(
            modelManager: ModelManager(modelDirectory: defaultModelsDirectory()),
            transcriber: transcriber,
            layaRouter: layaRouter
        )
        let monitor = MicMonitor()
        monitor.onSegment = { segment in
            Task {
                do {
                    try await runSegment(engine, segment, kind, runRequested: runRequested)
                } catch {
                    print("  segment error: \(error.localizedDescription)")
                }
            }
        }
        try monitor.start()
        print("listening… speak a command; Ctrl-C to stop (\(runRequested ? "auto-firing actions" : "dry-run"))")

        let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        stop.setEventHandler {
            monitor.stop()
            exit(0)
        }
        stop.resume()
        while monitor.isRunning {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Diagnostics

    /// `--diagnose`: probes permissions, models and browser automation before a
    /// single command is spoken, so TCC denials surface up front with fixes
    /// instead of failing mid-command at the moment of execution.
    static func runDiagnose() {
        print("Reflex health check\n")
        let report = SystemDiagnostics.run(probeMic: true)
        for check in report.checks {
            switch check.status {
            case .ok:
                print("  ✓ \(check.name)")
            case .warn(let detail):
                print("  ⚠︎ \(check.name): \(detail)")
            case .fail(let detail):
                print("  ✗ \(check.name): \(detail)")
            case .info(let detail):
                print("  … \(check.name): \(detail)")
            }
            if let fix = check.howToFix {
                print("      → \(fix)")
            }
        }
        print("")
        if report.ready {
            print("Ready. No blocking issues.")
        } else {
            print("\(report.blockingCount) blocking issue(s) — fix them above, then re-run `reflex-cli --diagnose`.")
        }
    }

    // MARK: - WhisperKit live paths

    /// Builds the shared engine (Whisper transcriber + Laya router).
    static func makeEngine() throws -> ReflexSystemEngine {
        let dir = defaultModelsDirectory()
        return ReflexSystemEngine(
            modelManager: ModelManager(modelDirectory: dir),
            transcriber: try WhisperTranscriber(modelDirectory: dir),
            layaRouter: try LayaRouter(modelDirectory: dir)
        )
    }

    /// Routes a transcript through Laya + the arbiter, identical to the engine,
    /// and returns the gated decision (used by --plan / --compound).
    static func routedDecision(_ transcript: String) async throws -> ReflexDecision {
        let router = try makeLayaRouter()
        let routing = try await router.route(transcript: transcript)
        guard let action = routing.answer("action"), case let .choice(label, _) = action.value else {
            throw CLIError(message: "no action choice")
        }
        let (target, confidence, addressed, trace) = DecisionArbiter().decide(
            layaTarget: label,
            layaConfidence: action.confidence,
            transcript: transcript
        )
        return ReflexDecision(
            actionTarget: ReflexChoice(target),
            urgencyScore: ReflexScore(0),
            confidence: ReflexNoul(lowerBound: 0, upperBound: 0),
            transcript: TranscriptNormalizer.normalize(transcript),
            trace: trace,
            confidenceValue: confidence,
            addressed: addressed
        )
    }

    /// Maps short variant names onto WhisperKit's Hugging Face folder names
    /// (mirrors tools/download_whisperkit_models.py).
    static func whisperkitVariant(for requested: String) -> String {
        switch requested {
        case "t", "tiny": "openai_whisper-tiny"
        case "tiny.en": "openai_whisper-tiny.en"
        case "b", "base": "openai_whisper-base"
        case "base.en": "openai_whisper-base.en"
        case "s", "small": "openai_whisper-small"
        case "small.en": "openai_whisper-small.en"
        case "small.compressed": "openai_whisper-small_216MB"
        case "m", "medium": "openai_whisper-medium"
        case "medium.en": "openai_whisper-medium.en"
        case "turbo": "openai_whisper-large-v3-v20240930_turbo"
        default: requested
        }
    }

    static func whisperkitFolder(for variant: String) -> URL {
        ReflexWhisperKit.modelFolder(in: defaultModelsDirectory(), variant: whisperkitVariant(for: variant))
    }

    static func consumeLiveUpdates(_ live: LiveTranscriber) -> Task<Void, Never> {
        Task {
            for await update in live.updates {
                if update.isFinal {
                    let shown = update.text.isEmpty ? "<empty>" : update.text
                    print("  final: \(shown)")
                } else if !update.text.isEmpty {
                    print("  … \(update.text)")
                }
            }
        }
    }

    /// A finalized live transcript: normalize, Laya, arbiter, optional dispatch.
    static func runSegmentTranscript(
        _ engine: ReflexSystemEngine,
        _ text: String,
        runRequested: Bool
    ) async throws {
        let decision = try await engine.resolveLiveTranscript(text)
        print("  transcript: \(decision.transcript)")
        print("  target: \(decision.actionTarget.identifier)")
        if let trace = decision.trace {
            let rule = trace.ruleTarget ?? "-"
            print("  trace: Laya=\(trace.layaTarget) rule=\(rule)\(trace.ambiguous ? " (ambiguous)" : "")")
        }
        if runRequested {
            let result = try ActionDispatcher().dispatch(decision)
            print("  result: \(result.summary)")
        }
    }

    static func runListenWK(variant: String, runRequested: Bool) async throws {
        let canonical = whisperkitVariant(for: variant)
        guard ReflexWhisperKit.isInstalled(in: defaultModelsDirectory(), variant: canonical) else {
            print("no WhisperKit pack installed for '\(variant)'. Install it with:\n  reflex-cli --wk-install \(variant)")
            return
        }
        let live = try await LiveTranscriber(modelFolder: whisperkitFolder(for: variant))
        await live.warmup()
        let engine = try makeEngine()
        let printTask = consumeLiveUpdates(live)
        defer { printTask.cancel() }

        let monitor = MicMonitor()
        monitor.onPartial = { partial in
            Task { await live.consumePartial(partial) }
        }
        monitor.onSegment = { segment in
            Task {
                do {
                    let text = try await live.finalizeUtterance()
                    if text.isEmpty {
                        print("  no speech")
                        return
                    }
                    try await runSegmentTranscript(engine, text, runRequested: runRequested)
                } catch {
                    print("  segment error: \(error.localizedDescription)")
                }
            }
        }
        try monitor.start()
        print("listening (WhisperKit live)… speak a command; Ctrl-C to stop (\(runRequested ? "auto-firing actions" : "dry-run"))")

        let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        stop.setEventHandler {
            monitor.stop()
            exit(0)
        }
        stop.resume()
        while monitor.isRunning {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Offline replay through the exact live path: VAD partial windows feed the
    /// transcriber at ~real-time pacing so stabilized partials are visible,
    /// then each finalized segment routes once.
    static func runVliveWK(
        samples: [Float],
        engine: ReflexSystemEngine,
        runRequested: Bool,
        variant: String,
        segmenter: StreamSegmenter
    ) async throws {
        let canonical = whisperkitVariant(for: variant)
        guard ReflexWhisperKit.isInstalled(in: defaultModelsDirectory(), variant: canonical) else {
            print("no WhisperKit pack installed for '\(variant)'. Install it with:\n  reflex-cli --wk-install \(variant)")
            return
        }
        let live = try await LiveTranscriber(modelFolder: whisperkitFolder(for: variant))
        await live.warmup()
        let printTask = consumeLiveUpdates(live)
        defer { printTask.cancel() }

        segmenter.onPartial = { partial in
            Task { await live.consumePartial(partial) }
        }
        nonisolated(unsafe) var spoken = 0
        nonisolated(unsafe) var processed = 0
        segmenter.onSegment = { _ in
            spoken += 1
            Task {
                do {
                    let text = try await live.finalizeUtterance()
                    if text.isEmpty {
                        print("  no speech detected in segment")
                    } else {
                        try await runSegmentTranscript(engine, text, runRequested: runRequested)
                    }
                } catch {
                    print("  segment error: \(error.localizedDescription)")
                }
                processed += 1
            }
        }

        let chunk = 1600
        var offset = 0
        while offset < samples.count {
            segmenter.feed(Array(samples[offset..<min(offset + chunk, samples.count)]))
            try await Task.sleep(nanoseconds: 60_000_000)
            offset += chunk
        }
        segmenter.flush()

        print("\(spoken) speech segment(s) found")
        while processed < spoken {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if spoken == 0 { print("no speech detected in file") }
    }

    static func runWKInstall(variant: String, modelsDir: String) throws {
        let script = try locateDownloadScript()
        print("installing WhisperKit model '\(variant)' -> \(modelsDir)/whisperkit/ …")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, variant, modelsDir]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CLIError(message: "installer exited with status \(process.terminationStatus)")
        }
    }

    static func locateDownloadScript() throws -> String {
        if !CommandLine.arguments.isEmpty {
            var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = directory
                    .appendingPathComponent("tools/download_whisperkit_models.py")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.path
                }
                directory = directory.deletingLastPathComponent()
            }
        }
        let home = defaultModelsDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("tools/download_whisperkit_models.py")
        if FileManager.default.fileExists(atPath: home.path) {
            return home.path
        }
        throw CLIError(message: "could not locate tools/download_whisperkit_models.py")
    }

    static func printRouting(_ routing: LayaRouting) {
        for answer in routing.answers {
            let value: String
            switch answer.value {
            case .choice(let label, let index): value = "\(label) [\(index)]"
            case .score(let expected): value = String(format: "%.3f", expected)
            case .noul(let probability): value = String(format: "%.3f", probability)
            }
            let probs = answer.probabilities.map { String(format: "%.3f", $0) }.joined(separator: ",")
            let logits = answer.logits.map { String(format: "%.4f", $0) }.joined(separator: ",")
            print(String(
                format: "%@ (%@) = %@  conf=%.3f  act=%.3f  t=%.3f  p=[%@]  z=[%@]",
                answer.id, answer.type.rawValue, value,
                answer.confidence, answer.actProbability, answer.temperature, probs, logits
            ))
        }
    }

    static func runLayaReference(path: String) async throws {
        let tolerance = 0.02  // fp16 CoreML vs fp32 PyTorch ground truth
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let file = try JSONDecoder().decode(LayaReferenceFile.self, from: data)
        let router = try makeLayaRouter()
        let tokenizer = try LayaTokenizer()

        var checks = 0
        var failures = 0
        for testCase in file.cases {
            let stateIds = tokenizer.encode(testCase.transcript)
            checks += 1
            if stateIds != testCase.state_ids {
                failures += 1
                print("  state_ids mismatch for \(testCase.transcript)!")
                print("    ref: \(testCase.state_ids)")
                print("    got: \(stateIds)")
            }

            let tensors = router.inputTensors(transcript: testCase.transcript)
            let comparisons: [(String, Bool)] = [
                ("input_ids", tensors.inputIds == testCase.input_ids.flatMap { $0 }.map(Int32.init)),
                ("attention_mask", tensors.attentionMask == testCase.attention_mask.flatMap { $0 }.map(Int32.init)),
                ("marker_pos", tensors.markerPos == testCase.marker_pos.flatMap { $0 }.map(Int32.init)),
                ("marker_mask", tensors.markerMask == testCase.marker_mask.flatMap { $0 }.map(Int32.init)),
                ("qtype", tensors.qtype == testCase.qtype.map(Int32.init)),
            ]
            for (name, ok) in comparisons {
                checks += 1
                if !ok {
                    failures += 1
                    print("  \(name) mismatch for \(testCase.transcript)!")
                }
            }

            let routing = try await router.route(transcript: testCase.transcript)
            for expected in testCase.decision {
                guard let got = routing.answer(expected.id) else {
                    failures += 1
                    print("  missing answer \(expected.id)")
                    continue
                }
                checks += 3
                if !close(got.probabilities, expected.probabilities, tolerance: tolerance) {
                    failures += 1
                    print("  \(expected.id) probabilities mismatch for \(testCase.transcript)!")
                    print("    ref: \(expected.probabilities)")
                    print("    got: \(got.probabilities)")
                }
                if abs(got.confidence - expected.confidence) > tolerance {
                    failures += 1
                    print("  \(expected.id) confidence \(got.confidence) vs \(expected.confidence)")
                }
                if abs(got.actProbability - expected.act_probability) > tolerance {
                    failures += 1
                    print("  \(expected.id) act \(got.actProbability) vs \(expected.act_probability)")
                }
                checks += 1
                if !matches(got.value, expected.value, tolerance: tolerance) {
                    failures += 1
                    print("  \(expected.id) value mismatch: \(got.value) vs \(expected.value)")
                }
            }
            print("  ok \(testCase.transcript) -> \(routing.answers.map(\.id).joined(separator: ","))")
        }
        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }

    static func close(_ lhs: [Double], _ rhs: [Double], tolerance: Double) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func matches(_ lhs: LayaAnswerValue, _ rhs: LayaReferenceValue, tolerance: Double) -> Bool {
        switch (lhs, rhs) {
        case (.choice(let label, _), .string(let expected)): label == expected
        case (.score(let expected), .number(let reference)): abs(expected - reference) <= tolerance
        case (.noul(let probability), .number(let reference)): abs(probability - reference) <= tolerance
        default: false
        }
    }

    static func makeLayaRouter() throws -> LayaRouter {
        let units: MLComputeUnits = switch ProcessInfo.processInfo.environment["REFLEX_COMPUTE"] {
        case "cpu": .cpuOnly
        case "gpu": .cpuAndGPU
        case "ane": .cpuAndNeuralEngine
        case "all": .all
        default: .cpuAndGPU
        }
        return try LayaRouter(modelDirectory: defaultModelsDirectory(), computeUnits: units)
    }

    /// Delegates to `ReflexWhisperKit.defaultModelsDirectory` so the CLI, the
    /// app, and `--diagnose` can never disagree about where the models are.
    static func defaultModelsDirectory() -> URL {
        ReflexWhisperKit.defaultModelsDirectory
    }
}

struct LayaReferenceFile: Decodable {
    let cases: [LayaReferenceCase]
}

struct LayaReferenceCase: Decodable {
    let transcript: String
    let state_ids: [Int]
    let input_ids: [[Int]]
    let attention_mask: [[Int]]
    let marker_pos: [[Int]]
    let marker_mask: [[Int]]
    let qtype: [Int]
    let decision: [LayaReferenceDecision]
}

struct LayaReferenceDecision: Decodable {
    let id: String
    let type: String
    let temperature: Double
    let probabilities: [Double]
    let confidence: Double
    let value: LayaReferenceValue
    let act_probability: Double
}

enum LayaReferenceValue: Decodable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }
}

struct CLIError: LocalizedError, CustomStringConvertible {
    let message: String
    var errorDescription: String? { message }
    var description: String { message }
}
