import Foundation
import ReflexCore

/// Corpus replay harness (Live Demo v1, plan Phase 0.4).
///
/// Feeds recorded clips through the exact live path — StreamSegmenter VAD at
/// real-time pace, LiveTranscriber partials, one final decode per segment, one
/// compound routing pass — and records stage timestamps. It never dispatches:
/// the routed action is scored against the clip's command id, not executed.
///
/// Truth comes from the file name (`<command_id>__<phrase_id>__take<N>.wav`)
/// and is scored at the level the dispatcher acts on: target plus the payload
/// the plan carries (volume op, brightness op, system op, app, site, shortcut).
enum ReplayHarness {
    struct Clip {
        let url: URL
        let split: String
        let commandID: String
        let phraseID: String
        let take: String
    }

    struct Row {
        let file, split, commandID, phraseID, transcript: String
        let segments: Int
        let expected, ruleSig, layaSig, hybridSig: String
        let ruleConfidence, layaConfidence, hybridConfidence: Double
        let correctRules, correctLaya, correctHybrid: Bool
        let hearingMs, partial1Ms, decodeMs, emitToRouteMs, routeMs: Double
    }

    // MARK: - Entry

    static func run(corpusDir: String, variant: String, limit: Int?, csvPath: String?) async throws {
        var clips = loadClips(corpusDir: corpusDir)
        if let limit { clips = Array(clips.prefix(limit)) }
        guard !clips.isEmpty else {
            throw CLIError(message: "no clips under \(corpusDir) (expected train/ and heldout/ subfolders)")
        }

        let canonical = ReflexCLI.whisperkitVariant(for: variant)
        guard ReflexWhisperKit.isInstalled(in: ReflexCLI.defaultModelsDirectory(), variant: canonical) else {
            throw CLIError(message: "no WhisperKit pack for '\(variant)' — install: reflex-cli --wk-install \(variant)")
        }
        print("loading \(canonical)…")
        let live = try await LiveTranscriber(modelFolder: ReflexCLI.whisperkitFolder(for: variant))
        await live.warmup()
        let engine = try ReflexCLI.makeEngine()
        let partials = PartialClock()
        let updateTask = Task {
            for await update in live.updates where !update.isFinal {
                if !update.text.isEmpty { partials.note() }
            }
        }
        let queue = PartialQueue()
        let pumpTask = Task {
            while !Task.isCancelled {
                if let window = queue.take() {
                    await live.consumePartial(window)
                    queue.finished()
                } else {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            }
        }
        defer { updateTask.cancel(); pumpTask.cancel() }
        print("replaying \(clips.count) clip(s)\n")

        // First decode of the process pays CoreML's cold-start cost; run the
        // first clip once and throw it away so timings are steady-state.
        partials.restart()
        _ = await replay(clips[0], live: live, engine: engine, partials: partials, queue: queue)

        var rows: [Row] = []
        for (index, clip) in clips.enumerated() {
            partials.restart()
            let row = await replay(clip, live: live, engine: engine, partials: partials, queue: queue)
            rows.append(row)
            let mark = row.correctHybrid ? "ok  " : "MISS"
            let want = row.correctHybrid ? "" : "  want \(row.expected) got \(row.hybridSig)"
            print("\(mark) \(index + 1)/\(clips.count) \(clip.commandID)/\(clip.phraseID)/\(clip.take)  \(Int(row.routeMs)) ms  \"\(row.transcript)\"\(want)")
        }

        summarize(rows)
        if let csvPath {
            writeCSV(rows, to: csvPath)
            print("\nwrote \(csvPath)")
        }
    }

    // MARK: - One clip

    private final class SegmentState: @unchecked Sendable {
        var segments: [[Float]] = []
        var emitTimes: [Date] = []
        var lastVoiced: Date?
    }

    /// Serial partial pump. The live app spawns one Task per VAD window, so an
    /// older window can land last and roll the transcriber back to a 100 ms
    /// prefix — short utterances then decode empty. The harness pumps in FIFO
    /// order so the routing baseline is deterministic; the app-side fix is
    /// plan Phase 1.
    private final class PartialQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [[Float]] = []
        private var inflight = false

        func push(_ samples: [Float]) { lock.withLock { pending.append(samples) } }

        func take() -> [Float]? {
            lock.withLock {
                guard !pending.isEmpty else { return nil }
                inflight = true
                return pending.removeFirst()
            }
        }

        func finished() { lock.withLock { inflight = false } }

        func idle() -> Bool { lock.withLock { pending.isEmpty && !inflight } }
    }

    private static func replay(
        _ clip: Clip,
        live: LiveTranscriber,
        engine: ReflexSystemEngine,
        partials: PartialClock,
        queue: PartialQueue
    ) async -> Row {
        let samples = (try? AudioFileLoader.loadSamples16kMono(url: clip.url)) ?? []
        let state = SegmentState()
        let segmenter = StreamSegmenter()
        segmenter.onPartial = { queue.push($0) }
        segmenter.onSegment = { segment in
            state.segments.append(segment)
            state.emitTimes.append(Date())
        }
        segmenter.onLevel = { _, speaking in
            if speaking { state.lastVoiced = Date() }
        }

        let start = Date()
        var firstVoiced: Date?
        var offset = 0
        while offset < samples.count {
            segmenter.feed(Array(samples[offset..<min(offset + 1600, samples.count)]))
            offset += 1600
            if firstVoiced == nil, let voiced = state.lastVoiced { firstVoiced = voiced }
            // Real-time pace: one 100 ms window per 100 ms.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        segmenter.flush()

        // One final decode per emitted segment; score the first non-empty one.
        var transcript = ""
        var decisions: [ReflexDecision] = []
        var emitAt: Date?
        var finalAt: Date?
        var routeAt: Date?
        // Let the FIFO pump finish this clip's windows before the final decode.
        while !queue.idle() { try? await Task.sleep(nanoseconds: 2_000_000) }
        for (index, _) in state.segments.enumerated() {
            let text = (try? await live.finalizeUtterance()) ?? ""
            if finalAt == nil { emitAt = state.emitTimes[index]; finalAt = Date() }
            if transcript.isEmpty, !text.isEmpty {
                transcript = text
                if emitAt == nil { emitAt = state.emitTimes[index] }
                decisions = (try? await engine.resolveCompoundTranscript(text)) ?? []
                routeAt = Date()
            }
        }

        let decision = decisions.first
        let hybridTarget = decision?.actionTarget.identifier ?? "none"
        let text = decision?.transcript ?? transcript
        let expected = expectations[clip.commandID] ?? []
        let rule = RuleRouter().classify(text)
        let ruleSig = rule.map { signature(target: $0.target, transcript: text) } ?? "none"
        let layaTarget = decision?.trace?.layaTarget
        let layaSig = layaTarget.map { signature(target: $0, transcript: text) } ?? "none"
        let hybridSig = signature(target: hybridTarget, transcript: text)
        let lastVoiced = state.lastVoiced ?? start
        let routeAtValue = routeAt ?? finalAt ?? start

        return Row(
            file: clip.url.lastPathComponent,
            split: clip.split,
            commandID: clip.commandID,
            phraseID: clip.phraseID,
            transcript: text,
            segments: state.segments.count,
            expected: expected.first ?? "—",
            ruleSig: ruleSig,
            layaSig: layaSig,
            hybridSig: hybridSig,
            ruleConfidence: rule?.confidence ?? 0,
            layaConfidence: decision?.layaConfidence ?? 0,
            hybridConfidence: decision?.confidenceValue ?? 0,
            correctRules: matches(ruleSig, expected),
            correctLaya: matches(layaSig, expected),
            correctHybrid: matches(hybridSig, expected),
            hearingMs: ms(from: start, to: firstVoiced ?? start),
            partial1Ms: partials.first().map { ms(from: firstVoiced ?? start, to: $0) } ?? -1,
            decodeMs: ms(from: emitAt ?? start, to: finalAt ?? start),
            emitToRouteMs: ms(from: emitAt ?? start, to: routeAtValue),
            routeMs: ms(from: lastVoiced, to: routeAtValue)
        )
    }

    // MARK: - Scoring

    /// What the command must do: target plus the payload the plan carries.
    /// `open.github` also accepts `web.github` — opening the site is the action,
    /// whichever lane gets there (the Phase 3 rule decides which one ships).
    static let expectations: [String: [String]] = [
        "volume_up": ["volume.up"],
        "volume_down": ["volume.down"],
        "volume_mute": ["volume.mute"],
        "play_pause": ["media.play", "media.pause", "media.toggle"],
        "next_track": ["media.next"],
        "prev_track": ["media.previous"],
        "scroll_up": ["scroll.up"],
        "scroll_down": ["scroll.down"],
        "screenshot": ["screenshot"],
        "dark_mode": ["system.darkMode(true)"],
        "show_desktop": ["system.showDesktop"],
        "copy": ["shortcut.copy"],
        "paste": ["shortcut.paste"],
        "undo": ["shortcut.undo"],
        "brightness_up": ["brightness.up"],
        "brightness_down": ["brightness.down"],
        "open_safari": ["open.Safari"],
        "open_terminal": ["open.Terminal"],
        "open_notes": ["open.Notes"],
        "open_music": ["open.Music"],
        "open_calendar": ["open.Calendar"],
        "go_github": ["open.github", "web.github"],
        "go_youtube": ["open.youtube", "web.youtube"],
        "go_wikipedia": ["open.wikipedia", "web.wikipedia"],
        "go_google": ["open.google", "web.google"],
    ]

    /// The action the dispatcher would take, as a comparable signature. Reuses
    /// the dispatcher's own pure parses so scoring cannot drift from execution.
    static func signature(target: String, transcript: String) -> String {
        let plan = CommandPlan.make(target: target, transcript: transcript)
        switch target {
        case "media_control":
            if let op = plan.candidates.volumeOp {
                switch op {
                case .percent(let p): return "volume.percent(\(p))"
                case .up: return "volume.up"
                case .down: return "volume.down"
                case .mute: return "volume.mute"
                case .unmute: return "volume.unmute"
                case .max: return "volume.max"
                case .half: return "volume.half"
                }
            }
            return "media.\(ActionDispatcher.mediaOperation(for: transcript))"
        case "display_control":
            switch ActionDispatcher.brightnessOperation(for: transcript) {
            case .percent(let p): return "brightness.percent(\(p))"
            case .maximum: return "brightness.max"
            case .minimum: return "brightness.min"
            case .up: return "brightness.up"
            case .down: return "brightness.down"
            case nil: return "brightness.unknown"
            }
        case "system_control":
            guard let op = ActionDispatcher.systemOperation(for: transcript) else { return "system.none" }
            return "system.\(op)"
        case "scroll":
            // Scroll-to-top scrolls up; the payload name is not the action.
            let raw = plan.args["direction"] ?? "page"
            let direction = raw == "top" ? "up" : (raw == "bottom" ? "down" : raw)
            return "scroll.\(direction)"
        case "shortcut":
            return "shortcut.\(plan.args["shortcutName"] ?? "?")"
        case "open_app":
            let entity = plan.args["appName"] ?? plan.args["site"] ?? "?"
            return "open.\(canonicalEntity(entity))"
        case "web_search":
            return "web.\(plan.args["site"] ?? plan.args["query"] ?? "?")"
        default:
            return target
        }
    }

    static func matches(_ actual: String, _ expected: [String]) -> Bool {
        let a = norm(actual)
        return expected.contains { norm($0) == a }
    }

    /// "Open Note" and "open notes" are the same installed app; "github.com"
    /// and "github" are the same site. Scoring compares what the dispatcher
    /// would actually open (AppResolver / normalizeSpokenDomain).
    static func canonicalEntity(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = AppResolver.url(for: lowered) {
            return url.deletingPathExtension().lastPathComponent.lowercased()
        }
        var e = lowered.replacingOccurrences(of: "www.", with: "")
        for tld in [".com", ".org", ".net", ".io", ".co"] where e.hasSuffix(tld) {
            e = String(e.dropLast(tld.count))
            break
        }
        return e
    }

    /// Case, dots and spaces are noise ("open.Safari" == "open.safari" ==
    /// "opensafari"); the words and payload are not.
    static func norm(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    private static func ms(from start: Date, to end: Date) -> Double {
        max(0, end.timeIntervalSince(start) * 1000)
    }

    // MARK: - Corpus + report

    static func loadClips(corpusDir: String) -> [Clip] {
        let root = URL(fileURLWithPath: corpusDir, isDirectory: true)
        var clips: [Clip] = []
        for split in ["train", "heldout"] {
            let dir = root.appendingPathComponent(split, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files where ["wav", "m4a"].contains(url.pathExtension.lowercased()) {
                let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "__")
                guard parts.count >= 2 else { continue }
                clips.append(Clip(
                    url: url,
                    split: split,
                    commandID: parts[0],
                    phraseID: parts[1],
                    take: parts.count > 2 ? parts[2] : ""
                ))
            }
        }
        return clips.sorted {
            ($0.split, $0.commandID, $0.phraseID, $0.take, $0.url.lastPathComponent)
                < ($1.split, $1.commandID, $1.phraseID, $1.take, $1.url.lastPathComponent)
        }
    }

    private static func summarize(_ rows: [Row]) {
        print("\n== Accuracy ==")
        for (name, key) in [("rules only", \Row.correctRules), ("laya only", \Row.correctLaya), ("rules + laya", \Row.correctHybrid)] {
            let hits = rows.filter { $0[keyPath: key] }.count
            print("  \(pad(name, 13)) \(String(format: "%3d/%3d", hits, rows.count))  \(String(format: "%5.1f%%", Double(hits) / Double(rows.count) * 100))")
        }

        print("\n== Latency (ms) ==")
        for (name, key) in [
            ("hearing", \Row.hearingMs),
            ("first partial", \Row.partial1Ms),
            ("decode", \Row.decodeMs),
            ("emit→route", \Row.emitToRouteMs),
            ("last word→route", \Row.routeMs),
        ] {
            let values = rows.map { $0[keyPath: key] }.filter { $0 >= 0 }.sorted()
            print("  \(pad(name, 16)) p50 \(String(format: "%5.0f", percentile(values, 0.5)))   p95 \(String(format: "%5.0f", percentile(values, 0.95)))")
        }

        let misses = rows.filter { !$0.correctHybrid }
        if !misses.isEmpty {
            print("\n== Misses (\(misses.count)) ==")
            for row in misses.prefix(40) {
                print("  \(row.commandID)/\(row.phraseID): \"\(row.transcript)\" want \(row.expected) got \(row.hybridSig) [rule \(row.ruleSig) / laya \(row.layaSig)]")
            }
            if misses.count > 40 { print("  … and \(misses.count - 40) more (see CSV)") }
        }
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))
        return sorted[index]
    }

    private static func writeCSV(_ rows: [Row], to path: String) {
        var lines = ["file,split,command_id,phrase_id,segments,transcript,expected,rule_sig,laya_sig,hybrid_sig,rule_conf,laya_conf,hybrid_conf,correct_rules,correct_laya,correct_hybrid,hearing_ms,partial1_ms,decode_ms,emit_to_route_ms,last_word_to_route_ms"]
        for row in rows {
            let fields = [
                row.file, row.split, row.commandID, row.phraseID, String(row.segments),
                row.transcript, row.expected, row.ruleSig, row.layaSig, row.hybridSig,
                String(format: "%.3f", row.ruleConfidence),
                String(format: "%.3f", row.layaConfidence),
                String(format: "%.3f", row.hybridConfidence),
                row.correctRules ? "1" : "0",
                row.correctLaya ? "1" : "0",
                row.correctHybrid ? "1" : "0",
                String(format: "%.0f", row.hearingMs),
                row.partial1Ms < 0 ? "" : String(format: "%.0f", row.partial1Ms),
                String(format: "%.0f", row.decodeMs),
                String(format: "%.0f", row.emitToRouteMs),
                String(format: "%.0f", row.routeMs),
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func csvEscape(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : value
    }

    /// Tracks the first non-empty partial of the current clip. The update
    /// stream is shared across clips, so a decode still in flight from the
    /// previous clip can win this timing.
    /// shortcut: per-clip partial timing can be off by one clip, upgrade when
    /// partial cadence itself becomes the metric (Phase 1 measures throttle).
    final class PartialClock: @unchecked Sendable {
        private let lock = NSLock()
        private var firstAt: Date?

        func restart() { lock.withLock { firstAt = nil } }
        func note() { lock.withLock { if firstAt == nil { firstAt = Date() } } }
        func first() -> Date? { lock.withLock { firstAt } }
    }
}
