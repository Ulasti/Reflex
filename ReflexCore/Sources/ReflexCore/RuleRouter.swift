import Foundation

/// How the final target was reached, for debugging and the UI.
public struct RoutingTrace: Sendable, Equatable {
    public let layaTarget: String
    public let ruleTarget: String?
    public let chosen: String
    public let ambiguous: Bool

    public init(layaTarget: String, ruleTarget: String?, chosen: String, ambiguous: Bool) {
        self.layaTarget = layaTarget
        self.ruleTarget = ruleTarget
        self.chosen = chosen
        self.ambiguous = ambiguous
    }
}

/// A high-precision, verb-driven classifier over the *normalized* transcript.
///
/// These are exact patterns the model was not trained on (OS commands) and
/// where rule matching is more reliable than Laya. `confidence` is the rule's
/// trust; rules that fire with confidence >= 0.9 override a low-confidence
/// Laya call via the arbiter.
public struct RuleRouter: Sendable {
    private struct Rule {
        let target: String
        let confidence: Double
    }

    public init() {}

    /// Rules ordered most-specific to most-general. The first match wins, so
    /// "play some jazz" hits media (not web), "open the first link" hits the
    /// browser (not the app), etc.
    public func classify(_ raw: String) -> RuleDecision? {
        let t = PayloadExtractor.normalizeIntent(raw).lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ";", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))

        // Display brightness — must fire before media's "turn up/down" words.
        if t.contains("brightness") || t.contains("dimmer") || t.contains("brighten")
            || t.contains("darker") || t.contains("brighter") || t.contains("more light")
            || t.contains("less light") || (t.contains("screen") && (t.contains("brighter") || t.contains("lighter")))
        {
            return RuleDecision(target: "display_control", confidence: 0.95)
        }

        // Media — fire first: "play some jazz" also contains generic verbs.
        let volumePhrases = ["change the volume", "turn it up", "turn it down", "turn up",
                             "turn down", "crank it up", "too loud", "quieter", "louder",
                             "volume", "mute", "silence"]
        if let phrase = volumePhrases.first(where: { t.contains($0) }) {
            return RuleDecision(target: "media_control", confidence: Self.graded(t, phrase, base: 0.9))
        }
        let playbackPhrases = ["next song", "previous song", "next track", "previous track",
                               "last song", "last one", "previous one", "playback",
                               "stop the music", "stop playing", "stop for a", "play music",
                               "listen to", "resume", "pause", "skip", "continue"]
        if let phrase = playbackPhrases.first(where: { t.contains($0) }) {
            return RuleDecision(target: "media_control", confidence: Self.graded(t, phrase, base: 0.9))
        }
        if t.containsWord("play") || t == "next" || t == "previous" {
            return RuleDecision(target: "media_control", confidence: Self.graded(t, t, base: 0.9))
        }

        // Typing — "type hello" belongs to the frontmost/focused app.
        // "paste that / put it here / drop it in here" are clipboard shortcuts
        // (shortcut catalog); "paste <free text>" still types the text.
        if t.hasPrefix("type ") || t.hasPrefix("type in ") || t.hasPrefix("type out ")
            || t.hasPrefix("write out ") || t.hasPrefix("input ")
            || t.hasPrefix("dictate ")
            || (t.hasPrefix("paste ") && !Self.isClipboardPaste(t)) {
            return RuleDecision(target: "type_text", confidence: 0.95)
        }

        // Browser commands — in-page link clicking and tab/page navigation.
        // "Open the first result/website/link" is a browser click, never an app;
        // so are tab and page navigations. Must precede the open-app rule.
        let navWords = ["next tab", "previous tab", "last tab", "close the tab", "close tab",
                        "new tab", "go back", "go forward", "refresh", "reload",
                        "previous page", "next page", "back a page", "forward a page", "last page"]
        if let phrase = navWords.first(where: { t.contains($0) }) {
            return RuleDecision(target: "browser_command", confidence: Self.graded(t, phrase, base: 0.9))
        }
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth",
                        "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "next"]
        let linkNouns = ["link", "website", "site", "webpage", "web page", "page",
                         "result", "search result", "video", "article", "post", "story"]
        let hitsOrdinal = ordinals.contains { t.contains(" \($0)") || t.hasPrefix("\($0) ") } ||
            (t.range(of: #"\b\d+(st|nd|rd|th)\b"#, options: .regularExpression) != nil)
        let hitsLinkNoun = linkNouns.contains { t.contains(" \($0)") || t.hasSuffix(" \($0)") }
        if hitsLinkNoun {
            let wantsClick = (hitsOrdinal || t.contains("the top"))
                && (t.contains("open the") || t.hasPrefix("open ") || t.contains("click"))
            let directLink = (t.contains("link") || t.contains("result"))
                && (t.contains("open the") || t.contains(" click"))
            if wantsClick || directLink {
                return RuleDecision(target: "browser_command", confidence: 0.9)
            }
        }

        // Scrolling — real scroll events, not just the old browser fallback.
        // "scroll down a little", "jump to the top", "scroll up a lot".
        let scrollPhrases = ["jump to the top", "jump to the bottom", "scroll to top",
                             "scroll to bottom", "take me to the top", "take me to the bottom",
                             "go up", "go down", "move up", "move down", "more up", "more down",
                             "page up", "page down", "scroll"]
        if let phrase = scrollPhrases.first(where: { t.contains($0) }) {
            return RuleDecision(target: "scroll", confidence: Self.graded(t, phrase, base: 0.92))
        }

        // Site-targeted search — "youtube.com search selfie" is web_search but
        // must bypass the generic web words below and still be recognized when
        // the transcript does not start with "search".
        if Self.isSiteSearch(t) {
            return RuleDecision(target: "web_search", confidence: 0.9)
        }

        // Quit — "quit calculator", "close finder", "quit the mail app". The
        // named app must actually resolve, so the generic "quit the app" (a
        // Cmd-Q shortcut) still falls through to the shortcut catalog.
        if let app = Self.quitAppName(from: t), AppResolver.isInstalled(app) {
            return RuleDecision(target: "quit", confidence: 0.9)
        }

        // File operations — before web_search so local searches win.
        if (t.contains("create") || t.contains("make") || t.contains("new"))
            && (t.contains("folder") || t.contains("directory")) {
            return RuleDecision(target: "file_operation", confidence: 0.95)
        }
        if t.contains("move ") && (t.contains(" into ") || t.contains(" to the ")) {
            return RuleDecision(target: "file_operation", confidence: 0.9)
        }
        // The copy-a-path half shares the dispatcher's predicate, so the router
        // can never advertise a "find X and copy the path" phrase that the
        // dispatcher then refuses to run (atlas/docs/audit-2026-10-14.md, S5).
        if Self.isFileCopyRequest(t) {
            return RuleDecision(target: "file_operation", confidence: 0.9)
        }
        if t.contains("search") || t.contains("find") || t.contains("locate") {
            let localMarkers = ["folder", "directory", "desktop", "documents", " mac",
                                "disk", "drive", "finder", "library", "partition"]
            if localMarkers.contains(where: { t.contains($0) }) {
                return RuleDecision(target: "file_operation", confidence: 0.9)
            }
        }

        // System ops — lock/sleep/show desktop/dark mode/empty trash. Runs before
        // the folder rule so "show desktop" is the system gesture rather than the
        // Desktop folder, and before open-app so "lock the screen" never tries to
        // open an app.
        if t.containsWord("lock") && (t.contains("screen") || t.contains("mac")) {
            return RuleDecision(target: "system_control", confidence: 0.95)
        }
        if t.contains("sleep the display") || t.contains("sleep display") || t.contains("display to sleep")
            || t.contains("put the display to sleep") || t.contains("turn off the screen")
            || t.contains("turn off the display") {
            return RuleDecision(target: "system_control", confidence: 0.9)
        }
        let desktopPhrases = ["show the desktop", "reveal the desktop", "go to the desktop",
                              "go to desktop", "show me the desktop", "clear the screen",
                              "minimize everything", "show desktop"]
        if let phrase = desktopPhrases.first(where: { t.contains($0) }) {
            return RuleDecision(target: "system_control", confidence: Self.graded(t, phrase, base: 0.9))
        }
        if t == "desktop" {
            return RuleDecision(target: "system_control", confidence: 0.9)
        }
        let darkPhrases = ["dark mode", "light mode", "dark theme", "light theme", "night mode",
                           "switch to dark", "make it dark", "switch to light"]
        if darkPhrases.contains(where: { t.contains($0) }) {
            // Deliberately below decisive: "dark mode" in a video or podcast is
            // not a command, so this one always gets a second opinion.
            return RuleDecision(target: "system_control", confidence: 0.85)
        }
        if t.contains("empty the trash") || t.contains("empty trash") || t.contains("clear the trash")
            || t.contains("empty the bin") {
            return RuleDecision(target: "system_control", confidence: 0.95)
        }

        // Folders — "open the downloads folder" / "show me my documents".
        if Self.isFolderOpen(t) {
            return RuleDecision(target: "open_folder", confidence: 0.93)
        }

        // New item — "new window/document/note/file" in the frontmost or named
        // app ("new note in notes", "new document called q3 report").
        if t.contains("new window") || t.contains("new document") || t.contains("new note")
            || t.contains("new file") || t.contains("new email") || t.contains("new message") {
            return RuleDecision(target: "new_item", confidence: 0.93)
        }

        // Screenshot.
        let screenshotPhrases = ["screen capture", "screen shot", "screen grab", "screenshot",
                                 "capture the screen", "take a screen", "grab the screen",
                                 "picture of the screen"]
        if let phrase = screenshotPhrases.first(where: { t.contains($0) }) {
            return RuleDecision(target: "screenshot", confidence: Self.graded(t, phrase, base: 0.95))
        }

        // Stop — "stop listening", "go to sleep mode", explicit shutdown words.
        if t.contains("stop listening") || t == "stop" || t == "halt"
            || t.contains("stop taking commands") || t.contains("go to sleep mode")
            || t.contains("turn yourself off") {
            return RuleDecision(target: "stop", confidence: 0.95)
        }

        // Generic keyboard shortcuts — exact criteria phrases beat everything
        // else ("copy that", "undo", "zoom in", "fullscreen", ...). Runs after
        // the browser links/scroll/system rules that can contain those words.
        if let phrase = ShortcutController.matchedPhrase(in: t) {
            // "paste hello world" is dictation, not the paste shortcut.
            if t.hasPrefix("paste "), !Self.isClipboardPaste(t) { return nil }
            return RuleDecision(target: "shortcut", confidence: Self.graded(t, phrase, base: 0.9))
        }

        // Environment setup — "ssh", servers, running tools/scripts.
        if t.contains("ssh") || t.contains(" server") || t.contains("deploy")
            || t.contains("restart the") || (t.contains("run ") && (t.contains("tool")
                || t.contains("script") || t.contains("command") || t.contains("terminal")))
            || t.contains("in the terminal") || t.contains("open a terminal") {
            return RuleDecision(target: "environment_setup", confidence: 0.9)
        }

        // Web search — explicit web words, plus bare "search <topic>". A leading
        // launch verb wins over the bare "google" token, so "open google chrome"
        // is an app launch, not a web search (S8).
        let opensApp = ["open ", "open up ", "launch ", "start ", "bring up ", "pull up ",
                        "go to ", "visit "]
            .contains { t.hasPrefix($0) }
        // Bare entity — "safari", "calendar", "youtube.com", "github dot com": a
        // one-word phrase that is exactly a known app or site is a launch, not a
        // query. Spoken domains are normalized first so the space in "dot com"
        // does not disqualify them.
        let bareEntity = PayloadExtractor.normalizeSpokenDomain(t.trimmingCharacters(in: .whitespacesAndNewlines))
        if !bareEntity.contains(" "), bareEntity.count > 1,
           PayloadExtractor.isSiteToken(bareEntity) || AppResolver.isInstalled(bareEntity) {
            return RuleDecision(target: "open_app", confidence: Self.entityConfidence(bareEntity))
        }

        if t.contains("on the web") || t.contains("online") || t.contains("internet")
            || t.contains("browser") || (t.contains("google") && !opensApp) || t.hasPrefix("search ")
            || t.hasPrefix("look up ") {
            return RuleDecision(target: "web_search", confidence: 0.85)
        }

        // Open app — leading verb + a name.
        let openVerbs = ["open up ", "open ", "launch ", "start ", "go to ", "bring up ",
                         "pull up ", "show me ", "open the ", "launch the ", "facetime ",
                         "open app ", "visit "]
        if let verb = openVerbs.first(where: { t.hasPrefix($0) }), t.count > verb.count + 1 {
            return RuleDecision(target: "open_app", confidence: Self.openConfidence(t))
        }

        // General query — knowledge-seeking phrasing.
        if t.hasPrefix("what is ") || t.hasPrefix("what's ") || t.hasPrefix("who is ")
            || t.hasPrefix("when is ") || t.contains("capital of") || t.hasPrefix("how do ")
            || t.hasPrefix("definition of") || t.contains("explain") || t.contains("tell me about") {
            return RuleDecision(target: "general_query", confidence: 0.7)
        }

        return nil
    }

    /// Confidence for a rule that matched `phrase` inside the utterance. An
    /// exact whole-utterance match to a catalog phrasing is certain; a phrase
    /// that merely contains it is a keyword hit. Rule hits used to all report
    /// the same P (plan: grade the confidence, do not flatten it).
    private static func graded(_ t: String, _ phrase: String, base: Double) -> Double {
        t == phrase ? 0.95 : base
    }

    /// Open/launch rules grade on whether the entity actually resolves. Only an
    /// exact app alias or a known site is decisive (0.95); a fuzzy app match
    /// ("open note" → Notes) is 0.85, and an entity that resolves to nothing
    /// ("go to the forward page", "open the third page") is 0.8 — below the
    /// decisive threshold, so Laya and the 0.4 abstention see it instead of a
    /// confident launch that fails as "Execute failed".
    private static func entityConfidence(_ entity: String) -> Double {
        if PayloadExtractor.isSiteToken(PayloadExtractor.normalizeSpokenDomain(entity.lowercased())) {
            return 0.95
        }
        let quality = AppResolver.matchQuality(entity)
        if quality >= 1.0 { return 0.95 }
        return quality > 0 ? 0.85 : 0.8
    }

    /// The entity an open/launch rule is about: what the shared extractor takes
    /// out of the utterance, else the words after the verb.
    private static func openConfidence(_ t: String) -> Double {
        let extracted = PayloadExtractor.extract(from: t, target: "open_app").appName ?? ""
        if !extracted.isEmpty { return entityConfidence(extracted) }
        if let verb = PayloadExtractor.openVerbs.first(where: { t.hasPrefix($0) }) {
            let rest = String(t.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return entityConfidence(rest) }
        }
        return 0.8
    }

    /// Whether the whole phrase is one of the paste shortcut's own criteria
    /// ("paste that", "drop it in here"). Longer "paste <text>" is dictation.
    private static func isClipboardPaste(_ t: String) -> Bool {
        ShortcutController.shortcut(named: "paste")?.criteria.contains(t) == true
    }

    /// `open the downloads folder` / `show me my documents` — an open/show verb
    /// plus a folder alias.
    private static func isFolderOpen(_ t: String) -> Bool {
        let opensWithVerb = ["open ", "open up ", "show me ", "show ", "go to "].contains { t.hasPrefix($0) }
        guard opensWithVerb else { return false }
        return PayloadExtractor.folderAliases.contains { t.contains($0.phrase) }
    }

    /// `youtube.com search selfie` / `search selfie on youtube — a bare site
    /// token immediately before/after "search" that looks like a domain.
    private static func isSiteSearch(_ t: String) -> Bool {
        if let parsed = PayloadExtractor.siteSearch(in: t) {
            _ = parsed
            return true
        }
        if t.hasPrefix("search "), let m = t.range(of: " on ") {
            let site = t[m.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if PayloadExtractor.isSiteToken(site) { return true }
        }
        return false
    }

    /// Extracts a named app from a quit phrase: "quit calculator", "quit the
    /// mail app", "close finder". Returns nil when the phrase has no app name
    /// ("quit the app", "quit this") — those are Cmd-Q shortcuts instead.
    private static func quitAppName(from t: String) -> String? {
        let markers = ["quit ", "close the ", "close "]
        for marker in markers where t.hasPrefix(marker) {
            var rest = t.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
            // "quit the mail app" → strip the pointless article.
            if rest.lowercased().hasPrefix("the ") {
                rest = String(rest.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !rest.isEmpty else { continue }
            // "quit the app" / "quit this app" are generic, not a named target.
            if rest == "app" || rest == "the app" || rest == "this app"
                || rest == "application" || rest == "the application" || rest == "it" {
                continue
            }
            return rest
        }
        return nil
    }

    /// Whether a transcript asks for the "find X and copy the path" file op.
    /// Pure, and the one predicate both sides use, so the router can never
    /// advertise a phrase the dispatcher then refuses to run
    /// (atlas/docs/audit-2026-10-14.md, S5). Lives here rather than on
    /// `ActionDispatcher` because that type is macOS-only and this router is not.
    public static func isFileCopyRequest(_ transcript: String) -> Bool {
        let lower = transcript.lowercased()
        let finds = lower.contains("search") || lower.contains("find") || lower.contains("locate")
        let wantsPath = lower.contains("path") || lower.contains("clipboard") || lower.contains("copy")
        return finds && wantsPath
    }
}

public struct RuleDecision: Sendable, Equatable {
    public let target: String
    public let confidence: Double

    public init(target: String, confidence: Double) {
        self.target = target
        self.confidence = confidence
    }

    /// Strong enough to decide alone, without Laya (DecisionArbiter.strongRule).
    public var isDecisive: Bool { confidence >= DecisionArbiter().strongRule }
}

/// Picks the target the dispatcher should act on: a high-confidence rule
/// beats a shaky Laya call; otherwise Laya wins. The trace tells the UI what
/// happened so ambiguity stays visible instead of silently executing.
public struct DecisionArbiter: Sendable {
    public let strongRule = 0.9
    public let strongLaya = 0.55

    /// Actions to act on need at least this confidence (Jev's
    /// `ACTION_MIN_CONFIDENCE`). Below it, the result is a no-op, never a wild
    /// dispatch — this is the gate that stops "50 times 20" landing in
    /// file_operation at P(6–29%).
    public let minConfidence = 0.4

    public init() {}

    public func decide(
        layaTarget: String,
        layaConfidence: Double,
        transcript: String
    ) -> (target: String, confidence: Double, addressed: Double, trace: RoutingTrace) {
        let rule = RuleRouter().classify(transcript)
        var target = layaTarget
        var ambiguous = false
        var confidence = layaConfidence
        var addressed = layaConfidence

        if let rule {
            if rule.target == layaTarget {
                target = rule.target
                confidence = max(confidence, rule.confidence)
                addressed = 1.0
            } else if rule.confidence >= strongRule, layaConfidence < strongLaya {
                target = rule.target
                confidence = rule.confidence
                addressed = 1.0
            } else if rule.confidence >= strongRule {
                target = rule.target
                confidence = rule.confidence
                addressed = 1.0
                ambiguous = true
            } else if layaConfidence < strongLaya {
                target = rule.target
                confidence = rule.confidence
                addressed = rule.confidence >= 0.7 ? 1.0 : 0.5
                ambiguous = rule.confidence >= 0.7
            } else {
                target = layaTarget
                confidence = layaConfidence
                addressed = rule.confidence >= 0.7 ? 0.9 : 0.5
                ambiguous = rule.confidence >= 0.7
            }
        }

        let trace = RoutingTrace(layaTarget: layaTarget, ruleTarget: rule?.target, chosen: target, ambiguous: ambiguous)
        return (target, confidence, addressed, trace)
    }

    /// The execution gate: a decision is actionable when its confidence clears
    /// the floor (or it came from a piping-hot rule that may carry confidence
    /// below the floor — but those get 1.0 addressed above).
    public func shouldExecute(confidence: Double, addressed: Double) -> Bool {
        confidence >= minConfidence && addressed >= 0.5
    }
}
