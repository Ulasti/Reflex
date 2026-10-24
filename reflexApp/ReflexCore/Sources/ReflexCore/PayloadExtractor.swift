import Foundation

/// Typed entity candidates extracted from a single transcript — the
/// "select, don't generate" pattern from the Jev reference. Extraction is pure
/// regex/verb work in code; nothing here invents text the user never said:
/// every candidate is cut verbatim from the utterance.
public struct Candidates: Sendable, Equatable {
    /// App to focus/open ("notes" from "open notes", "type hello in notes").
    public var appName: String?
    /// Web-search query. Set for web_search and site-targeted searches.
    public var query: String?
    /// Site host for a site-targeted search ("youtube", "wikipedia", ...).
    public var site: String?
    /// Free text to type for type_text ("buy milk" from "type buy milk").
    public var text: String?
    /// Payload title from "called/titled/named/that says" phrasing.
    public var title: String?
    /// Folder to open (downloads, desktop, documents, ...).
    public var folder: String?
    /// Scroll direction: "up" | "down" | "top" | "bottom".
    public var direction: String?
    /// Scroll amount: "little" | "page" | "a_lot".
    public var amount: String?
    /// Canonical shortcut name from the ShortcutController catalog.
    public var shortcutName: String?
    /// Parsed volume intent (percent / up / down / mute / unmute / max / half).
    public var volumeOp: VolumeOp?
    /// Trailing "and press enter / and hit submit" folded into the command.
    public var submit = false
    /// The app a type/new_item payload should act in ("in notes" strip).
    public var inApp: String?
    /// 0-based link index for "open the first result".
    public var linkIndex: Int?

    public init() {}
}

/// Closed-set volume intent from the transcript. Mirrors the Jev volume table
/// plus the percent step we already supported.
public enum VolumeOp: Sendable, Equatable {
    case percent(Int)
    case up(delta: Int)
    case down(delta: Int)
    case mute
    case unmute
    case max
    case half
}

/// Installed-app resolution, shared by extraction and dispatch so the two
/// never disagree about whether a word is an app. On non-mac builds, nothing
/// resolves and extraction falls back to plain text.
public enum AppResolver {
    public static let aliases: [String: String] = [
        "facetime": "FaceTime", "safari": "Safari", "mail": "Mail", "mail app": "Mail",
        "calendar": "Calendar", "messages": "Messages", "imessage": "Messages",
        "photos": "Photos", "notes": "Notes", "reminders": "Reminders",
        "spotify": "Spotify", "music": "Music", "apple music": "Music",
        "podcasts": "Podcasts", "twitter": "Twitter", "slack": "Slack", "discord": "Discord", "zoom": "Zoom",
        "terminal": "Terminal", "finder": "Finder", "calculator": "Calculator",
        "settings": "System Settings", "system settings": "System Settings",
        "preferences": "System Settings", "system preferences": "System Settings",
        "maps": "Maps", "weather": "Weather", "dictionary": "Dictionary",
        "textedit": "TextEdit", "text edit": "TextEdit", "pages": "Pages",
        "numbers": "Numbers", "keynote": "Keynote", "xcode": "Xcode",
        "visual studio code": "Visual Studio Code", "vs code": "Visual Studio Code", "vscode": "Visual Studio Code",
        "viber": "Viber",
    ]

    /// Where macOS keeps app bundles, most specific first.
    private static let directories = [
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        "/Applications",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Installed app bundles by lowercased name, built once. `url(for:)` used to
    /// rescan six directories twice per call, and `RuleRouter.classify` asks
    /// about every token in a transcript (atlas/docs/audit-2026-10-14.md, N4).
    private static let installedApps: [String: URL] = {
        var index: [String: URL] = [:]
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let base = (entry as NSString).deletingPathExtension.lowercased()
                // First directory wins, so a system app shadows a duplicate.
                if index[base] == nil {
                    index[base] = URL(fileURLWithPath: directory).appendingPathComponent(entry)
                }
            }
        }
        return index
    }()

    /// Resolves a spoken app name to an installed bundle URL: the alias table,
    /// then an exact name, then the spoken name as a whole word ("code" →
    /// "Visual Studio Code"), then a prefix only when it is unambiguous. Names
    /// are sorted, so the pick never depends on directory read order
    /// (atlas/docs/audit-2026-10-14.md, N6).
    public static func url(for name: String) -> URL? {
        #if os(macOS)
        let match = (aliases[name.lowercased()] ?? name).lowercased()
        if let exact = installedApps[match] { return exact }
        let names = installedApps.keys.sorted()
        if let word = names.first(where: { $0.split(separator: " ").contains(Substring(match)) }) {
            return installedApps[word]
        }
        let prefixed = names.filter { $0.count >= 3 && $0.hasPrefix(match) }
        return prefixed.count == 1 ? installedApps[prefixed[0]] : nil
        #else
        return nil
        #endif
    }

    public static func isInstalled(_ name: String) -> Bool {
        url(for: name) != nil
    }

    /// How firmly a spoken name names an app, for confidence grading. 1.0 = an
    /// alias or exact bundle name; 0.5 = the whole-word or unique-prefix guess
    /// ("note" → Notes); 0 = it resolves to nothing. `url(for:)` deliberately
    /// stays permissive for dispatch, but a *decisive* rule (one that skips
    /// Laya) must know the difference: "go to the forward page" resolves to
    /// nothing and used to be dispatched anyway, then failed as "Execute
    /// failed".
    public static func matchQuality(_ name: String) -> Double {
        #if os(macOS)
        let match = (aliases[name.lowercased()] ?? name).lowercased()
        if installedApps[match] != nil { return 1.0 }
        let names = installedApps.keys.sorted()
        if names.contains(where: { $0.split(separator: " ").contains(Substring(match)) }) { return 0.5 }
        let prefixed = names.filter { $0.count >= 3 && $0.hasPrefix(match) }
        return prefixed.count == 1 ? 0.5 : 0
        #else
        return 0
        #endif
    }
}

/// The single source of entity extraction. Every dispatcher parses by reading
/// `Candidates`, never by re-slicing the raw transcript.
public enum PayloadExtractor {
    // MARK: - URLs, sites

    public static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "co", "me", "app", "dev", "ai", "tv", "cc",
        "gg", "xyz", "site", "online", "info", "biz", "cloud", "tech", "pro", "live",
    ]
    public static let knownSiteNames: Set<String> = [
        "youtube", "google", "wikipedia", "github", "reddit", "maps", "amazon",
        "imdb", "netflix", "twitter", "x", "spotify", "instagram", "facebook",
        "linkedin", "news", "translate", "gmail", "drive", "docs", "calendar",
        "chatgpt", "claude", "notion", "hackernews", "twitch",
        "figma", "perplexity", "whatsapp", "pinterest", "tumblr",
    ]

    public static let webVerbs = ["search for", "search", "google for", "google", "look up", "look for", "find me", "find"]

    /// Bare site names resolved to a real host. Without this "go to github"
    /// opens https://github, which does not resolve (plan Phase 3.3).
    public static let siteDomains: [String: String] = [
        "github": "github.com", "google": "google.com",
        "youtube": "youtube.com", "wikipedia": "wikipedia.org",
    ]
    public static let openVerbs = ["open up", "open", "launch", "start", "go to", "bring up", "pull up",
                                   "show me", "show", "run", "visit"]

    /// One-pass extraction. `target` sharpens interpretation when several
    /// extractions could be the payload (type_text wants text, open_app the app).
    /// Phase 3.1 intent normalization: strips spoken filler that carries no
    /// command meaning (leading "hey/ok/okay/um/uh", a trailing "please")
    /// before routing and extraction. Case stays as spoken; only the filler
    /// goes, so the same text can still be typed verbatim.
    /// Train-only mishearings. Each entry has to be a mistake that cannot
    /// change meaning anywhere else, and it may only be justified by a *train*
    /// clip — heldout phrasings judge the table, they never build it. Kept
    /// deliberately tiny; the rejected candidates ("no" → mute, "who" → visit,
    /// "that mode", "taste" → paste, single-clip guesses) are listed in
    /// atlas/evidence/alias-table.md.
    public static let mishearings: [String: String] = [
        "skull": "scroll",
        "pulse": "pause",
        "under": "undo",
        "lover": "louder",
    ]

    /// Rewrites known mishearings word by word. Dictation is exempt: those
    /// words are the user's payload, not a command ("type this under the
    /// heading" must stay as spoken).
    private static func applyMishearings(_ text: String) -> String {
        let lower = text.lowercased()
        for dictation in ["type ", "write ", "dictate ", "note down "] where lower.hasPrefix(dictation) {
            return text
        }
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var changed = false
        for (index, word) in words.enumerated() {
            if let fixed = mishearings[word.lowercased()] {
                words[index] = fixed
                changed = true
            }
        }
        return changed ? words.joined(separator: " ") : text
    }

    public static func normalizeIntent(_ transcript: String) -> String {
        var t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t.,!?;"))
        let lower = t.lowercased()
        for filler in ["hey ", "okay ", "ok ", "um ", "uh "] where lower.hasPrefix(filler) {
            t = String(t.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        for suffix in [", please", " please"] where t.lowercased().hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t.,!?;"))
            break
        }
        return applyMishearings(t)
    }

    public static func extract(from transcript: String, target: String?) -> Candidates {
        var c = Candidates()
        let t = normalizeIntent(transcript)
        let cleaned = t
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ";", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))

        c.submit = Self.detectSubmit(in: lower)
        c.linkIndex = Self.extractLinkIndex(in: lower)
        c.title = Self.extractTitle(cleaned)

        if let textExtract = Self.extractText(cleaned, lower: lower) {
            c.text = textExtract.text
            c.inApp = textExtract.app
        }

        if let queryExtract = Self.extractQuery(cleaned, lower: lower) {
            c.query = queryExtract.query
            c.site = queryExtract.site
        }
        if c.site == nil { c.site = Self.extractSite(from: cleaned) }

        c.volumeOp = Self.extractVolume(in: lower)
        c.folder = Self.extractFolder(in: lower)
        c.direction = Self.extractDirection(in: lower)
        c.amount = Self.extractAmount(in: lower)

        if let app = Self.extractAppName(cleaned) { c.appName = app }
        c.shortcutName = ShortcutController.canonicalName(in: lower)

        // Route-aware fallbacks: a valid verb payload for the chosen action.
        if let target {
            switch target {
            case "type_text":
                if c.text == nil { c.text = Self.verbPayload(cleaned) }
            case "web_search":
                if c.query == nil { c.query = Self.verbPayload(cleaned) }
            case "new_item":
                if c.title == nil, let rest = Self.afterLabels(cleaned, labels: ["called ", "titled ", "named "]) {
                    c.title = rest
                }
            case "open_app":
                if c.appName == nil, let candidate = Self.afterVerbs(cleaned) {
                    c.appName = candidate
                }
            default:
                break
            }
        }

        return c
    }

    // MARK: - Text

    /// Free-text payload: after "type/write/paste/dictate", a quoted span, or a
    /// trailing "for/about/of/on" span. Any trailing in-app target is stripped
    /// into `app` and a trailing submit phrase is dropped (flag stays on `c`.
    private static func extractText(_ t: String, lower: String) -> (text: String, app: String?)? {
        if let quoted = Self.firstQuoted(t) {
            return Self.stripTargeting(quoted)
        }
        for verb in ["type out ", "type in ", "type ", "write out ", "write ", "dictate ", "input ", "paste "] {
            guard lower.hasPrefix(verb) else { continue }
            let rest = Self.trimSubmit(String(t.dropFirst(verb.count)), lower: String(t.dropFirst(verb.count)).lowercased())
            return Self.stripTargeting(rest)
        }
        return nil
    }

    /// Any leading-verb payload, used as a per-route fallback.
    private static func verbPayload(_ t: String) -> String? {
        if let quoted = Self.firstQuoted(t) { return Self.stripTargeting(quoted).text }
        guard let rest = Self.afterVerbs(t) else { return nil }
        return Self.stripTargeting(rest).text
    }

    private static func afterVerbs(_ t: String) -> String? {
        for verb in webVerbs + openVerbs + ["type ", "write ", "dictate "]
        where t.lowercased().hasPrefix(verb) {
            let rest = String(t.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    private static func afterLabels(_ t: String, labels: [String]) -> String? {
        let lower = t.lowercased()
        for label in labels {
            guard let range = lower.range(of: label) else { continue }
            let rest = String(t[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
            if !rest.isEmpty { return rest }
        }
        return nil
    }

    private static func firstQuoted(_ t: String) -> String? {
        let pattern = #""([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = t as NSString
        guard let match = regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a trailing "in/<into>/<inside> the <real-app>" off the payload
    /// only when the candidate literally resolves to an installed app, so "type
    /// hello in the morning" is typed whole while "type hello in notes" targets
    /// Notes. Also drops a trailing submit phrase ("and press enter").
    public static func stripTargeting(_ raw: String) -> (text: String, app: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var app: String?
        let markers = [" into the ", " into ", " in the ", " in ", " inside the ", " inside ", " within "]
        outer: for marker in markers {
            guard let range = text.lowercased().range(of: marker) else { continue }
            let candidate = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
            // only accept an app-looking word that is actually installed
            if AppResolver.isInstalled(cleaned) {
                app = cleaned
                text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            break outer
        }
        text = Self.trimSubmit(text, lower: text.lowercased())
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, app)
    }

    private static func trimSubmit(_ rest: String, lower: String) -> String {
        let tails = [
            " and press enter", " then press enter", " and hit enter", " then hit enter",
            " and press return", " then press return", " press enter", " hit enter",
            " and submit", " then submit", " press return",
        ]
        for tail in tails where lower.hasSuffix(tail) {
            return String(rest.dropLast(tail.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Query

    private static func extractQuery(_ t: String, lower: String) -> (query: String, site: String?)? {
        var text = t.trimmingCharacters(in: .whitespacesAndNewlines)
        var strippedVerb = false
        for verb in webVerbs where text.lowercased().hasPrefix(verb) {
            text = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            strippedVerb = true
            break
        }
        for tail in [" on the web", " in the browser", " on the internet",
                     " and copy", " then copy", " and paste", " on the "] where text.lowercased().hasSuffix(tail) {
            text = String(text.dropLast(tail.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
        guard !text.isEmpty else { return nil }

        if let quoted = Self.firstQuoted(text) {
            return (Self.trimSubmit(quoted, lower: quoted.lowercased()), nil)
        }

        // "<site> search <query>"
        if let parsed = Self.siteSearch(in: text), let query = parsed.query {
            return (query, parsed.host)
        }

        // "<verb>... <query> on <site>"
        if strippedVerb || text.lowercased().hasPrefix("search "),
           let m = text.lowercased().range(of: " on ") {
            let site = String(text[m.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isSiteToken(site) {
                let query = String(text[..<m.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
                if !query.isEmpty { return (query, site) }
            }
        }

        var parts = text.split(separator: " ")
        while let first = parts.first?.lowercased(), ["this", "the", "a", "an", "my", "for"].contains(first) {
            parts.removeFirst()
        }
        let cleaned = parts.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;"))
        return cleaned.isEmpty ? nil : (cleaned, nil)
    }

    // MARK: - Site

    /// "<site> search <query>" — "youtube.com search selfie" or
    /// "open youtube search this" — host is a leading site token before
    /// "search", query is everything after.
    public struct SiteSearch: Sendable, Equatable {
        public let host: String
        public let query: String?
    }

    public static func siteSearch(in text: String) -> SiteSearch? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard let m = lower.range(of: " search ") else { return nil }
        let before = String(lower[..<m.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        // strip a leading open-verb so "open youtube search x" still works
        var candidateHost = before
        for verb in openVerbs where candidateHost.hasPrefix(verb) {
            candidateHost = String(candidateHost.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard !candidateHost.isEmpty else { return nil }
        let query = String(lower[m.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
        return SiteSearch(host: candidateHost, query: query.isEmpty ? nil : query)
    }

    private static func extractSite(from t: String) -> String? {
        if let parsed = Self.siteSearch(in: t) { return parsed.host }
        return nil
    }

    public static func isSiteToken(_ token: String) -> Bool {
        let t = token
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
        guard !t.isEmpty, !t.contains(" ") else { return false }
        // spoken-domain normalization: "youtube dot com" → "youtube.com"
        let normalized = normalizeSpokenDomain(t)
        if knownSiteNames.contains(normalized) || knownSiteNames.contains(t) { return true }
        let components = normalized.split(separator: ".").map(String.init)
        if components.count >= 2, let last = components.last {
            return commonTLDs.contains(last)
        }
        return false
    }

    /// "youtube dot com" → "youtube.com", "open github dot com" → already domain.
    public static func normalizeSpokenDomain(_ text: String) -> String {
        var t = text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        t = t.replacingOccurrences(of: " dot com", with: ".com")
            .replacingOccurrences(of: " dot org", with: ".org")
            .replacingOccurrences(of: " dot net", with: ".net")
            .replacingOccurrences(of: " dot io", with: ".io")
        let hasSpokenSegments = t.contains(" dot ")
        if hasSpokenSegments {
            t = t.split(separator: " ").map { $0 == "dot" ? "." : String($0) }
                .joined(separator: "")
        }
        return siteDomains[t] ?? t
    }

    // MARK: - App

    private static func extractAppName(_ t: String) -> String? {
        var text = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for verb in openVerbs where text.lowercased().hasPrefix(verb) {
            text = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        for boundary in [" and ", " in ", " to ", " then ", " so that ", " with ", " for ", ", "] {
            if let range = text.lowercased().range(of: boundary) {
                text = String(text[..<range.lowerBound])
                break
            }
        }
        for suffix in [" application", " app", ".app"] where text.lowercased().hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            break
        }
        var parts = text.split(separator: " ")
        while let first = parts.first?.lowercased(), ["the", "a", "an", "my", "open"].contains(first) {
            parts.removeFirst()
        }
        let name = parts.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
        return name.isEmpty ? nil : name
    }

    // MARK: - Folder

    public static let folderAliases: [(phrase: String, canonical: String)] = [
        ("downloads folder", "Downloads"), ("downloads", "Downloads"),
        ("desktop folder", "Desktop"), ("my desktop", "Desktop"), ("desktop", "Desktop"),
        ("documents folder", "Documents"), ("my documents", "Documents"), ("documents", "Documents"),
        ("pictures folder", "Pictures"), ("my pictures", "Pictures"), ("pictures", "Pictures"),
        ("music folder", "Music"), ("my music", "Music"),
        ("movie folder", "Movies"), ("movies folder", "Movies"), ("movies", "Movies"),
        ("home folder", "Home"), ("home directory", "Home"), ("my home", "Home"), ("home", "Home"),
        ("applications folder", "Applications"), ("applications", "Applications"),
        ("trash", "Trash"), ("recent", "Recent"),
    ]

    private static func extractFolder(in lower: String) -> String? {
        for (phrase, canonical) in folderAliases where lower.contains(phrase) {
            return canonical
        }
        return nil
    }

    // MARK: - Volume

    private static func extractVolume(in lower: String) -> VolumeOp? {
        guard lower.contains("volume") || lower.contains("mute") || lower.contains("louder")
            || lower.contains("quieter") || lower.contains("turn up") || lower.contains("turn down")
            || lower.contains("turn the volume") || lower.contains("turn it up") || lower.contains("turn it down")
            || lower.contains("too loud") || lower.contains("silence") || lower.contains("crank it up")
        else { return nil }
        if lower.contains("max") || lower.contains("all the way up") || lower.contains("full volume") {
            return .max
        }
        if lower.contains("half") || lower.contains("medium volume") || lower.contains("moderate") {
            return .half
        }
        if lower.contains("unmute") || lower.contains("sound back on") {
            return .unmute
        }
        if lower.contains("mute") || lower.contains("silence") || lower.contains("volume off")
            || lower.contains("sound off") { return .mute }
        if let percent = Self.extractPercent(in: lower) {
            if percent == 0 { return .mute }
            return .percent(percent)
        }
        // "turn up" has to match at the start of a transcript too, not only with
        // a leading space ("turn up the volume" is the common phrasing).
        if lower.contains("louder") || lower.contains("turn up") || lower.contains("turn it up")
            || lower.contains("volume up") || lower.contains("increase") || lower.contains("raise")
            || lower.contains("higher") || lower.contains("crank it up") {
            return .up(delta: 15)
        }
        if lower.contains("quieter") || lower.contains("turn down") || lower.contains("turn it down")
            || lower.contains("volume down") || lower.contains("decrease") || lower.contains("lower")
            || lower.contains("too loud") || lower.contains("less loud") {
            return .down(delta: 15)
        }
        return nil
    }

    private static func extractPercent(in lower: String) -> Int? {
        let patterns = [#"(\d{1,3})\s*(?:%|percent)"#, #"to\s+(\d{1,3})\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = lower as NSString
            if let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: match.range(at: 1))
                if let percent = Int(value) { return min(100, max(0, percent)) }
            }
        }
        return nil
    }

    // MARK: - Scroll

    private static func extractDirection(in lower: String) -> String? {
        if lower.contains("to the top") || lower.contains("jump to top") || lower.contains("scroll to top")
            || lower.contains("go to the top") || lower.contains("top of the page") {
            return "top"
        }
        if lower.contains("to the bottom") || lower.contains("jump to bottom") || lower.contains("scroll to bottom")
            || lower.contains("go to the bottom") || lower.contains("bottom of the page") {
            return "bottom"
        }
        if lower.contains("scroll up") || lower.contains("back up") || lower.contains("up the page")
            || lower.contains("page up") || lower.contains("go up") || lower.contains("move up")
            || lower.contains("more up") {
            return "up"
        }
        if lower.contains("scroll down") || lower.contains("further down") || lower.contains("down the page")
            || lower.contains("lower on the page") || lower.contains("page down") || lower.contains("go down")
            || lower.contains("move down") || lower.contains("more down") {
            return "down"
        }
        return nil
    }

    private static func extractAmount(in lower: String) -> String? {
        if lower.contains("a little") || lower.contains("a bit") || lower.contains("a few")
            || lower.contains("little") || lower.contains("few") || lower.contains("slightly") {
            return "little"
        }
        if lower.contains("a lot") || lower.contains("way down") || lower.contains("way up")
            || lower.contains("far") || lower.contains("lots") || lower.contains("all the way")
            || lower.contains("much") {
            return "a_lot"
        }
        if lower.contains("one screen") || lower.contains("a screen") || lower.contains("screen")
            || lower.contains("a page") || lower.contains("page") {
            return "page"
        }
        return nil
    }

    // MARK: - Link ordinal

    private static func extractLinkIndex(in lower: String) -> Int? {
        let words = ["first": 0, "second": 1, "third": 2, "fourth": 3,
                     "fifth": 4, "sixth": 5, "seventh": 6, "eighth": 7,
                     "ninth": 8, "tenth": 9, "eleventh": 10, "twelfth": 11,
                     "next": 1]
        for (word, index) in words {
            if lower.contains(" \(word) ") || lower.hasPrefix("\(word) ") {
                return index
            }
        }
        let ns = lower as NSString
        if let m = try? NSRegularExpression(pattern: #"\b(\d+)(st|nd|rd|th)\b"#, options: [.caseInsensitive]).firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) {
            if m.numberOfRanges > 1 {
                let num = ns.substring(with: m.range(at: 1))
                if let n = Int(num) { return max(0, n - 1) }
            }
        }
        if lower.contains("the link") || lower.contains("the top result")
            || lower.contains("the top link") || lower.contains("the top website")
            || lower.contains("the first website") || lower.contains("the first result") {
            return 0
        }
        return nil
    }

    // MARK: - Title

    private static func extractTitle(_ t: String) -> String? {
        // "called/titled/named/that says" + quoted span or a bare run.
        // The payload must be its own capture group: reading a group index the
        // pattern does not have raises an NSException that terminates the app.
        let pattern = #"(?:called|titled|named|that says|that is called)\s+(?:"([^"]+)"|([^.,!?;]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = t as NSString
        guard let match = regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let quoted = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ""
        let bare = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : ""
        let result = (!quoted.isEmpty ? quoted : bare)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
        return result.isEmpty ? nil : result
    }

    // MARK: - Submit

    private static func detectSubmit(in lower: String) -> Bool {
        ["press enter", "hit enter", "and submit", "then submit", "press return", "hit return",
         "and press enter", "and hit enter", "submit "].contains { lower.contains($0) }
    }
}
