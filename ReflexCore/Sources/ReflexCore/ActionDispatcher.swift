#if os(macOS)
import AppKit
import Foundation

/// What a dispatched decision actually did on the desktop (or why it didn't).
public enum ReflexActionResult: Sendable, Equatable, CustomStringConvertible {
    case launched(app: String)
    case opened(url: URL)
    case openedInBrowser(url: URL, tab: String)
    case searchedWeb(query: String, site: String?)
    case volumeSet(percent: Int)
    case volumeChanged(delta: Int)
    case volumeMuted
    case volumeUnmuted
    case brightnessSet(percent: Int)
    case brightnessChanged(delta: Int)
    case mediaToggled
    case mediaControlled(action: String, app: String)
    case typedText(text: String)
    case browserActed(action: String)
    case copiedToClipboard(text: String)
    case createdFolder(path: String)
    case movedItems(into: String)
    case launchedTerminal(command: String)
    case pressedShortcut(name: String)
    case scrolled(direction: String, amount: String)
    case newItemCreated(kind: String, app: String?)
    case openedFolder(path: String)
    case screenshotTaken(path: String)
    case systemControlOpened(operation: String)
    case quitApp(app: String)
    case stopped
    case noOp(reason: String)
    case failed(error: String)

    /// Whether nothing was done: the gate refused it ("not sure what you
    /// meant"). The feedback light must not flash green for a no-op.
    public var isNoOp: Bool {
        if case .noOp = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .launched(let app): "Launched \(app)"
        case .opened(let url): "Opened \(url.absoluteString)"
        case .openedInBrowser(let url, let tab): "Opened \(url.absoluteString) in \(tab)"
        case .searchedWeb(let query, let site): "Searched the web\(site.map { " on \($0)" } ?? "") for \"\(query)\""
        case .volumeSet(let percent): "Volume set to \(percent)%"
        case .volumeChanged(let delta): delta >= 0 ? "Volume up \(delta)%" : "Volume down \(-delta)%"
        case .volumeMuted: "Volume muted"
        case .volumeUnmuted: "Volume unmuted"
        case .brightnessSet(let percent): "Brightness set to \(percent)%"
        case .brightnessChanged(let delta): delta >= 0 ? "Brightness up \(delta)%" : "Brightness down \(-delta)%"
        case .mediaToggled: "Play/pause toggled"
        case .mediaControlled(let action, let app): "\(action) in \(app)"
        case .typedText(let text): "Typed \"\(text)\""
        case .browserActed(let action): action
        case .copiedToClipboard(let text): "Copied to clipboard: \(text)"
        case .createdFolder(let path): "Created folder at \(path)"
        case .movedItems(let target): "Moved matching items into \(target)"
        case .launchedTerminal(let command): "Ran in Terminal: \(command)"
        case .pressedShortcut(let name): "Pressed \(name)"
        case .scrolled(let direction, let amount): "Scrolled \(direction) (\(amount))"
        case .newItemCreated(let kind, let app): "New \(kind)\(app.map { " in \($0)" } ?? "")"
        case .openedFolder(let path): "Opened folder \(path)"
        case .screenshotTaken(let path): "Screenshot saved to \(path)"
        case .systemControlOpened(let operation): "\(operation)"
        case .quitApp(let app): "Quit \(app)"
        case .stopped: "Stopped listening"
        case .noOp(let reason): "No-op: \(reason)"
        case .failed(let error): "Failed: \(error)"
        }
    }

    public var description: String { summary }
}

public enum ActionExecutionError: LocalizedError {
    case unknownApp(name: String)
    case launchFailed(name: String)
    case unknownAction(String)
    case noQuery
    case noMatchFound(query: String)
    case noClickableLink(index: Int, reason: String)
    case automationDenied(what: String)
    case unexpectedExit(code: Int32, command: String, output: String)
    case parseFailure

    public var errorDescription: String? {
        switch self {
        case .unknownApp(let name): "Could not resolve an app named \"\(name)\"."
        case .launchFailed(let name): "macOS could not launch \"\(name)\"."
        case .unknownAction(let id): "No dispatcher exists for action \"\(id)\"."
        case .noQuery: "Nothing to search for."
        case .noMatchFound(let query): "No file matched \"\(query)\"."
        case .noClickableLink(let index, let reason): "No clickable link #\(index + 1) on the page. \(reason)"
        case .automationDenied(let what):
            "Automation blocked: macOS needs your approval to control \(what). Allow it in System Settings > Privacy & Security > Automation (or click Allow on the prompt), then try again."
        case .unexpectedExit(let code, let command, let output): "\(command) exited \(code): \(output)"
        case .parseFailure: "Could not parse the command."
        }
    }
}

/// Maps a `ReflexDecision` to a real macOS desktop action.
///
/// Pure host-side code: no ML. It reads `CommandPlan` — a typed plan whose
/// candidates were cut out of the transcript by `PayloadExtractor` — so entity
/// extraction and intent stay separate concerns: the router does intent,
/// this does execution, and neither re-parses the raw transcript mid-action.
public struct ActionDispatcher: Sendable {
    public init() {}

    /// Executes a single routed decision: applies the confidence + addressed
    /// gate, then runs the matching action. Compound utterances are expanded
    /// upstream (engine/AppModel) into one decision per clause, each gated here.
    public func dispatch(_ decision: ReflexDecision) throws -> ReflexActionResult {
        let arbiter = DecisionArbiter()
        guard arbiter.shouldExecute(confidence: decision.confidenceValue, addressed: decision.addressed) else {
            return .noOp(reason: "not sure what you meant (confidence \(Int(decision.confidenceValue * 100))%)")
        }
        let plan = CommandPlan.make(
            target: decision.actionTarget.identifier,
            transcript: decision.transcript
        )
        return try dispatchSingle(plan)
    }

    private func dispatchSingle(_ plan: CommandPlan) throws -> ReflexActionResult {
        switch plan.action {
        case "open_app": return try openApp(plan: plan)
        case "open_url": return try openURL(plan: plan)
        case "web_search": return try webSearch(plan: plan)
        case "media_control": return try mediaControl(plan: plan)
        case "display_control": return try brightnessControl(plan: plan)
        case "type_text": return try typeText(plan: plan)
        case "browser_command": return try browserCommand(plan: plan)
        case "file_operation": return try fileOperation(plan: plan)
        case "environment_setup": return try setupEnvironment(plan: plan)
        case "shortcut": return try shortcutAction(plan: plan)
        case "scroll": return try scrollAction(plan: plan)
        case "new_item": return try newItem(plan: plan)
        case "open_folder": return try openFolder(plan: plan)
        case "screenshot": return try screenshot(plan: plan)
        case "system_control": return try systemControl(plan: plan)
        case "quit": return try quitApp(plan: plan)
        case "stop": return .stopped
        case "general_query":
            try Self.pbcopy(plan.transcript)
            return .copiedToClipboard(text: plan.transcript)
        default:
            throw ActionExecutionError.unknownAction(plan.action)
        }
    }

    // MARK: - Actions

    private func openApp(plan: CommandPlan) throws -> ReflexActionResult {
        guard let name = Self.candidateAppName(plan) else {
            throw ActionExecutionError.parseFailure
        }
        // "open youtube.com" is a site, not an app — route it to the browser
        // with the same tab-reuse intelligence as open_url.
        if Self.looksLikeURL(PayloadExtractor.normalizeSpokenDomain(name)) {
            return try openURL(plan: plan)
        }
        guard let url = AppResolver.url(for: name) else {
            throw ActionExecutionError.unknownApp(name: name)
        }
        let ok = NSWorkspace.shared.open(url)
        guard ok else { throw ActionExecutionError.launchFailed(name: name) }
        return .launched(app: url.deletingPathExtension().lastPathComponent)
    }

    /// Opens a site (respecting <site> search <query>) in the front browser tab
    /// when possible, so "open youtube.com" and "search wikipedia …" never pile
    /// up tabs while a blank/new tab is already front and center.
    private func openURL(plan: CommandPlan) throws -> ReflexActionResult {
        let c = plan.candidates
        if let site = c.site ?? Self.candidateSite(plan), let query = c.query ?? Self.candidateQuery(plan) {
            return try Self.openSiteSearch(PayloadExtractor.SiteSearch(host: site, query: query))
        }
        guard let name = Self.candidateAppName(plan) else {
            throw ActionExecutionError.parseFailure
        }
        let normalized = PayloadExtractor.normalizeSpokenDomain(name)
        guard Self.looksLikeURL(normalized) else {
            throw ActionExecutionError.parseFailure
        }
        let url = Self.normalizedURL(for: normalized)
        let tab = try BrowserController.open(url)
        return .openedInBrowser(url: url, tab: tab)
    }

    private func webSearch(plan: CommandPlan) throws -> ReflexActionResult {
        var query = Self.candidateQuery(plan)
        // "<verb> <site> search <query>" was extracted with site set.
        if let site = Self.candidateSite(plan), let q = Self.candidateQuery(plan) {
            return try Self.openSiteSearch(PayloadExtractor.SiteSearch(host: site, query: q))
        }
        query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query, !query.isEmpty else { throw ActionExecutionError.noQuery }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw ActionExecutionError.parseFailure }
        _ = try BrowserController.open(url)
        // No wait here: the "open the first result" clause owns it, and
        // clickLink already retries ~4 s for result links and reports why it
        // failed. This call only burned up to 8 s holding `processing`
        // (atlas/docs/audit-2026-10-14.md, S2).
        return .searchedWeb(query: query, site: nil)
    }

    private func mediaControl(plan: CommandPlan) throws -> ReflexActionResult {
        let lower = plan.transcript.lowercased()

        // Volume — one closed-set VolumeOp, from the extractor. A second table
        // used to live here and could disagree with it
        // (atlas/docs/audit-2026-10-14.md, "also noticed").
        if let op = plan.candidates.volumeOp {
            return try Self.performVolume(op)
        }

        let kind = Self.mediaOperation(for: plan.transcript)

        // An explicit app in the phrase ("play music", "play on spotify")
        // targets that app directly instead of the current now-playing source.
        if let namedApp = Self.namedMediaApp(in: lower) {
            let command: String
            switch kind {
            case .play: command = "play"
            case .pause: command = "pause"
            case .next: command = "next track"
            case .previous: command = "previous track"
            case .toggle: command = "playpause"
            }
            try Self.driveMediaApp(namedApp, command: command)
            return .mediaControlled(action: Self.actionLabel(kind, command: command), app: namedApp)
        }

        // Otherwise the command goes to whatever is *actually* playing right
        // now (the Control Center source — Safari, Music, Spotify, ...).
        let status = NowPlaying.status()
        if status.isHosting {
            let command: NowPlaying.Command
            switch kind {
            case .play: command = .play
            case .pause: command = .pause
            case .next: command = .nextTrack
            case .previous: command = .previousTrack
            case .toggle: command = .togglePlayPause
            }
            if NowPlaying.send(command) {
                return .mediaControlled(
                    action: Self.actionLabel(kind, command: "sent"),
                    app: NowPlaying.appLabel(for: status.bundleIdentifier)
                )
            }
            // MediaRemote saw a host but the send failed — fall through to HID.
        }

        // B3: HID media-key fallback (works for in-browser video, some web
        // apps) when MediaRemote has no host or its send failed.
        if MediaKeyHID.post(kind) {
            return .mediaControlled(action: Self.actionLabel(kind, command: "sent"), app: "system media keys")
        }

        // Nothing playing — fall back to starting Music itself.
        if kind != .pause {
            try Self.driveMediaApp("Music", command: "play")
            return .mediaControlled(action: "Played", app: "Music")
        }
        return .noOp(reason: "nothing is playing")
    }

    public enum BrightnessOperation: Equatable, Sendable {
        case percent(Int)
        case maximum
        case minimum
        case up
        case down
    }

    /// Phrase → brightness op, in the order the executor's chain used. Pure
    /// and separated from execution like `systemOperation(for:)`, so the replay
    /// harness scores the exact op the dispatcher would run.
    public static func brightnessOperation(for transcript: String) -> BrightnessOperation? {
        let lower = transcript.lowercased()
        if let percent = extractPercent(from: transcript) { return .percent(percent) }
        if lower.contains("maximum") || lower.contains("full") || lower.contains("max") { return .maximum }
        if lower.contains("minimum") || lower.contains("lowest") { return .minimum }
        if lower.contains("brighter") || lower.contains("brighten") || lower.contains("up")
            || lower.contains("increase") || lower.contains("raise") || lower.contains("highest")
            || lower.contains("more light") { return .up }
        if lower.contains("dimmer") || lower.contains("dim") || lower.contains("down")
            || lower.contains("decrease") || lower.contains("lower") || lower.contains("darker")
            || lower.contains("reduce") || lower.contains("less light") { return .down }
        return nil
    }

    private func brightnessControl(plan: CommandPlan) throws -> ReflexActionResult {
        switch Self.brightnessOperation(for: plan.transcript) {
        case .percent(let percent): return .brightnessSet(percent: try BrightnessController.set(percent))
        case .maximum: return .brightnessSet(percent: try BrightnessController.set(100))
        case .minimum: return .brightnessSet(percent: try BrightnessController.set(0))
        case .up: return .brightnessChanged(delta: try BrightnessController.adjust(by: +10))
        case .down: return .brightnessChanged(delta: try BrightnessController.adjust(by: -10))
        case nil: throw ActionExecutionError.parseFailure
        }
    }

    private func typeText(plan: CommandPlan) throws -> ReflexActionResult {
        let c = plan.candidates
        let text = c.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let submit = plan.submit || c.submit
        guard !text.isEmpty else { throw ActionExecutionError.parseFailure }

        if let appName = c.inApp ?? Self.candidateInApp(plan), let url = AppResolver.url(for: appName) {
            Self.openAndActivate(url)
        }
        try Self.pasteText(text, withReturn: submit)
        return .typedText(text: text)
    }

    // MARK: - Phase B: browser, shortcut, scroll, new_item, folder, screenshot, system

    /// Browser tab/page navigation and in-page link clicking — the one action
    /// that still owns its own browser-specific verbs because half of them are
    /// shortcut presses and half are JS clickLink calls in the page itself.
    private func browserCommand(plan: CommandPlan) throws -> ReflexActionResult {
        let lower = plan.transcript.lowercased()

        // Tab management / navigation. Prefer BrowserController.navigate —
        // its Back/Forward use real `history.back()` (one hop, layout- and
        // locale-independent) instead of a ⌘[ keystroke that can miss on
        // non-US keyboards. Fall back to the shortcut catalog when Apple
        // Events/JS automation is unavailable.
        func navigate(_ nav: BrowserController.Navigation, shortcut: String, action: String) throws -> ReflexActionResult {
            do {
                try BrowserController.navigate(nav)
            } catch {
                try ShortcutController.press(name: shortcut)
            }
            return .browserActed(action: action)
        }

        if lower.contains("new tab") || lower.contains("open a new tab") {
            return try navigate(.newTab, shortcut: "new_tab", action: "Opened a new tab")
        }
        if lower.contains("close tab") || lower.contains("close the tab") || lower.contains("close window") {
            return try navigate(.closeTab, shortcut: "close_tab", action: "Closed the tab")
        }
        if lower.contains("reopen") || lower.contains("undo close") {
            try ShortcutController.press(name: "reopen_tab")
            return .browserActed(action: "Reopened the last closed tab")
        }
        if lower.contains("next tab") {
            return try navigate(.nextTab, shortcut: "next_tab_page", action: "Moved to the next tab")
        }
        if lower.contains("previous tab") || lower.contains("last tab") || lower.contains("back a tab") {
            return try navigate(.previousTab, shortcut: "previous_tab_page", action: "Moved to the previous tab")
        }
        if lower.contains("go back") || lower.contains("back a page")
            || lower.contains("previous page") || lower.contains("last page") {
            return try navigate(.back, shortcut: "browser_back", action: "Went back a page")
        }
        if lower.contains("go forward") || lower.contains("forward a page") || lower.contains("next page") {
            return try navigate(.forward, shortcut: "browser_forward", action: "Went forward a page")
        }
        if lower.contains("reload") || lower.contains("refresh") {
            return try navigate(.reload, shortcut: "reload", action: "Reloaded the page")
        }

        // In-page link click — "open the first result/link" (ordinal in the plan).
        if let index = plan.candidates.linkIndex {
            let label = try BrowserController.clickLink(at: index)
            return .browserActed(action: "Opened \(label)")
        }

        throw ActionExecutionError.parseFailure
    }

    private func shortcutAction(plan: CommandPlan) throws -> ReflexActionResult {
        let name = plan.candidates.shortcutName ?? Self.candidateShortcut(plan)
        guard let name else { throw ActionExecutionError.parseFailure }
        try ShortcutController.press(name: name)
        return .pressedShortcut(name: name)
    }

    private func scrollAction(plan: CommandPlan) throws -> ReflexActionResult {
        let direction = plan.args["direction"] ?? plan.candidates.direction
        let amount = plan.args["amount"] ?? plan.candidates.amount
        try ScrollController.scroll(direction: direction, amount: amount)
        return .scrolled(direction: direction ?? "page", amount: amount ?? "page")
    }

    private func newItem(plan: CommandPlan) throws -> ReflexActionResult {
        let lower = plan.transcript.lowercased()
        // Browser "new tab" is routed to browser_command already; here a
        // window/document/note/file/email message is a new_item.
        let kind: String
        if lower.contains("new window") {
            kind = "window"
        } else if lower.contains("new email") || lower.contains("new message") {
            kind = "message"
        } else if lower.contains("new note") {
            kind = "note"
        } else if lower.contains("new file") {
            kind = "file"
        } else {
            kind = "document"
        }
        // "new note called buy milk in notes" → title + app.
        let title = plan.candidates.title ?? Self.candidateTitle(plan)
        let appName = Self.candidateInApp(plan)

        if let appName, let url = AppResolver.url(for: appName) {
            Self.openAndActivate(url)
        }
        // ⌘N then (optionally) type the title.
        try ShortcutController.press(name: "new_document")
        if let title, !title.isEmpty {
            try Self.pasteText(title, withReturn: plan.submit)
        }
        return .newItemCreated(kind: kind, app: appName)
    }

    private func openFolder(plan: CommandPlan) throws -> ReflexActionResult {
        let name = plan.candidates.folder ?? Self.candidateFolder(plan)
        guard let name else { throw ActionExecutionError.parseFailure }
        let url = try Self.folderURL(named: name)
        let ok = NSWorkspace.shared.open(url)
        guard ok else { throw ActionExecutionError.launchFailed(name: url.path) }
        return .openedFolder(path: url.path)
    }

    private func screenshot(plan: CommandPlan) throws -> ReflexActionResult {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        // Seconds (and milliseconds) in the name: the old minute-granular style
        // made two shots in the same minute collide and silently overwrite.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let path = dir.appendingPathComponent("Reflex \(formatter.string(from: Date())).png").path
        let output = try Self.runTool("/usr/sbin/screencapture", arguments: ["-x", path])
        guard output.isEmpty || !output.contains("error") else {
            return .failed(error: output)
        }
        return .screenshotTaken(path: path)
    }

    /// What a transcript asks `system_control` to do. Pure and separate from
    /// execution so the routing contract tests can assert that every phrase the
    /// router sends here is actually handleable (atlas/docs/audit-2026-10-14.md, M3).
    public enum SystemOperation: Equatable, Sendable {
        case lockScreen
        case sleepDisplay
        case showDesktop
        case darkMode(Bool)
        case emptyTrash
    }

    /// Phrase to operation, in the original if-chain's order.
    public static func systemOperation(for transcript: String) -> SystemOperation? {
        // Same filler stripping the router applies, so a phrase it matched
        // ("desktop, please") parses here too.
        let lower = PayloadExtractor.normalizeIntent(transcript).lowercased()
        // Word boundaries, not substrings: "unlock the screen" must not lock
        // (and macOS cannot unlock it anyway).
        if lower.containsWord("lock") { return .lockScreen }
        if lower.contains("sleep") || lower.contains("turn off the screen")
            || lower.contains("turn off the display") {
            return .sleepDisplay
        }
        let bare = lower.trimmingCharacters(in: CharacterSet(charactersIn: " \t.,!?;"))
        if lower.contains("show desktop") || lower.contains("show the desktop")
            || lower.contains("reveal the desktop") || lower.contains("go to the desktop")
            || lower.contains("go to desktop") || lower.contains("show me the desktop")
            || lower.contains("clear the screen") || lower.contains("minimize everything")
            || bare == "desktop" {
            return .showDesktop
        }
        if lower.contains("dark mode") || lower.contains("light mode") || lower.contains("dark theme")
            || lower.contains("light theme") || lower.contains("night mode")
            || lower.contains("switch to dark") || lower.contains("make it dark")
            || lower.contains("switch to light") {
            let wantsLight = lower.contains("light mode") || lower.contains("light theme")
                || lower.contains("switch to light")
            return .darkMode(!wantsLight)
        }
        if lower.contains("trash") || lower.contains("bin") { return .emptyTrash }
        return nil
    }

    /// Whether text left over after a launch verb could be a shell command,
    /// rather than a mis-transcription of a normal request. This is the guard on
    /// the one path that hands arbitrary text to a shell (S1).
    static func looksLikeShellCommand(_ command: String) -> Bool {
        guard let first = command.split(separator: " ").first else { return false }
        let articles: Set<String> = ["a", "an", "the", "my", "our", "your", "it", "that", "this"]
        return !articles.contains(first.lowercased())
    }

    private func systemControl(plan: CommandPlan) throws -> ReflexActionResult {
        guard let operation = Self.systemOperation(for: plan.transcript) else {
            throw ActionExecutionError.parseFailure
        }
        switch operation {
        case .lockScreen:
            try ShortcutController.press(name: "lock_screen")
            return .systemControlOpened(operation: "Locked screen")
        case .sleepDisplay:
            _ = try Self.runTool("/usr/bin/pmset", arguments: ["displaysleepnow"])
            return .systemControlOpened(operation: "Display sleeping")
        case .showDesktop:
            try ShortcutController.press(name: "show_desktop")
            return .systemControlOpened(operation: "Showed desktop")
        case .darkMode(let dark):
            let script = """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to \(dark)
                end tell
            end tell
            """
            _ = try Self.runTool("/usr/bin/osascript", arguments: ["-e", script])
            return .systemControlOpened(operation: dark ? "Set dark mode" : "Set light mode")
        case .emptyTrash:
            let script = """
            tell application "Finder"
                empty trash
            end tell
            """
            _ = try Self.runTool("/usr/bin/osascript", arguments: ["-e", script])
            return .systemControlOpened(operation: "Emptied trash")
        }
    }

    /// Quits a named app ("quit calculator") via NSRunningApplication so it
    /// doesn't depend on automation or Accessibility permissions.
    private func quitApp(plan: CommandPlan) throws -> ReflexActionResult {
        guard let queried = Self.appName(fromQuitPhrase: plan.transcript) else {
            throw ActionExecutionError.parseFailure
        }
        guard let url = AppResolver.url(for: queried), let bundleID = Bundle(url: url)?.bundleIdentifier else {
            throw ActionExecutionError.unknownApp(name: queried)
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if apps.isEmpty {
            return .noOp(reason: "\(queried) is not running")
        }
        for app in apps {
            app.terminate()
        }
        return .quitApp(app: queried)
    }

    /// "quit calculator" → "calculator"; strips the leading quit verb.
    private static func appName(fromQuitPhrase transcript: String) -> String? {
        let lower = transcript.lowercased()
        let markers = ["quit ", "close the ", "close "]
        for marker in markers where lower.hasPrefix(marker) {
            let rest = transcript.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { return nil }
            return rest
        }
        return nil
    }

    private func fileOperation(plan: CommandPlan) throws -> ReflexActionResult {
        let lower = plan.transcript.lowercased()

        if lower.contains("folder") || lower.contains("directory") {
            if lower.contains("create") || lower.contains("make") || lower.contains("new") {
                guard let title = plan.candidates.title
                    ?? Self.candidateTitle(plan)
                    ?? Self.phraseBetween(plan.transcript, labels: ["called ", "named ", "name it "]) else {
                    throw ActionExecutionError.parseFailure
                }
                let base = lower.contains("document") ? Self.documents : Self.desktop
                let path = base.appendingPathComponent(Self.sanitizeName(title)).path
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
                return .createdFolder(path: path)
            }
        }

        if lower.contains("move") && lower.contains("into") {
            guard
                let matcher = Self.phraseBetween(plan.transcript, labels: ["move "], upTo: " into")
                    ?? plan.candidates.text,
                let rawTarget = Self.phraseBetween(plan.transcript, labels: ["into "], upTo: nil)
                    ?? Self.candidateTextAfterInto(plan),
                !rawTarget.isEmpty
            else {
                throw ActionExecutionError.parseFailure
            }
            let targetName = Self.sanitizeName(rawTarget)
            let destURL = try Self.ensureFolder(named: targetName)
            let moved = try Self.moveDownloads(matching: matcher, to: destURL)
            guard moved > 0 else {
                return .noOp(reason: "nothing matched \"\(matcher)\" in Downloads")
            }
            return .movedItems(into: destURL.lastPathComponent)
        }

        if RuleRouter.isFileCopyRequest(plan.transcript) {
            guard let query = plan.candidates.query ?? Self.candidateQuery(plan) else {
                throw ActionExecutionError.parseFailure
            }
            let output = try Self.runTool("/usr/bin/mdfind", arguments: ["-onlyin", "/", query])
            let path = output.split(separator: "\n").map(String.init).first { $0.hasPrefix("/") }
            guard let path, !path.isEmpty else {
                throw ActionExecutionError.noMatchFound(query: query)
            }
            try Self.pbcopy(path)
            return .copiedToClipboard(text: path)
        }

        return .noOp(reason: "file operation not recognized")
    }

    private func setupEnvironment(plan: CommandPlan) throws -> ReflexActionResult {
        var command = plan.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        for verb in ["use ", "using ", "run ", "start ", "launch ", "open ", "connect "] where command.lowercased().hasPrefix(verb) {
            command = String(command.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if let ssh = command.lowercased().range(of: "ssh") {
            command = String(command[ssh.lowerBound...])
        }
        // The residual goes straight into Terminal, so refuse anything that is
        // plainly not a command: "open a terminal" reduces to "a terminal" and
        // the shell just prints "command not found" (atlas/docs/audit-2026-10-14.md,
        // S1).
        guard Self.looksLikeShellCommand(command) else {
            return .noOp(reason: "not a command: \"\(command)\"")
        }
        let script = """
        on run
            tell application "Terminal"
                do script "\(command.appleScriptEscaped)"
                activate
            end tell
        end run
        """
        _ = try Self.runTool("/usr/bin/osascript", arguments: ["-e", script])
        return .launchedTerminal(command: command)
    }

    // MARK: - Candidate fallbacks (plan → typed candidates)

    /// read the candidates the extractor already produced, or the flat args.
    private static func candidateAppName(_ plan: CommandPlan) -> String? {
        plan.candidates.appName ?? plan.args["appName"]
    }

    private static func candidateQuery(_ plan: CommandPlan) -> String? {
        plan.candidates.query ?? plan.args["query"]
    }

    private static func candidateSite(_ plan: CommandPlan) -> String? {
        plan.candidates.site ?? plan.args["site"]
    }

    private static func candidateInApp(_ plan: CommandPlan) -> String? {
        plan.candidates.inApp ?? plan.args["inApp"]
    }

    private static func candidateShortcut(_ plan: CommandPlan) -> String? {
        plan.candidates.shortcutName ?? plan.args["shortcutName"]
    }

    private static func candidateTitle(_ plan: CommandPlan) -> String? {
        plan.candidates.title ?? plan.args["title"]
    }

    private static func candidateFolder(_ plan: CommandPlan) -> String? {
        plan.candidates.folder ?? plan.args["folder"]
    }

    private static func candidateTextAfterInto(_ plan: CommandPlan) -> String? {
        Self.phraseBetween(plan.transcript, labels: ["into ", "to the "], upTo: nil)
    }

    private static func candidateSiteSearch(_ plan: CommandPlan) -> PayloadExtractor.SiteSearch? {
        guard let site = candidateSite(plan), let query = candidateQuery(plan) else { return nil }
        return PayloadExtractor.SiteSearch(host: site, query: query)
    }

    // MARK: - Volume

    /// Executes a closed-set volume op. Mute/unmute/max/half are explicit and
    /// never ambiguous — the extractor's VolumeOp is the single input.
    private static func performVolume(_ op: VolumeOp) throws -> ReflexActionResult {
        switch op {
        case .percent(let p):
            try setVolume(p)
            return .volumeSet(percent: p)
        case .up(let delta):
            let applied = try adjustVolume(by: delta)
            return .volumeChanged(delta: applied)
        case .down(let delta):
            let applied = try adjustVolume(by: -delta)
            return .volumeChanged(delta: applied)
        case .mute:
            try setMuted(true)
            return .volumeMuted
        case .unmute:
            try setMuted(false)
            return .volumeUnmuted
        case .max:
            try setVolume(100)
            return .volumeSet(percent: 100)
        case .half:
            try setVolume(50)
            return .volumeSet(percent: 50)
        }
    }

    private static func setVolume(_ percent: Int) throws {
        let clamped = min(100, max(0, percent))
        // Clear the mute flag too, or a level change while muted looks like it
        // did nothing.
        _ = try runTool("/usr/bin/osascript", arguments: [
            "-e", "set volume output muted false",
            "-e", "set volume output volume \(clamped)",
        ])
    }

    /// Mutes or restores output without touching the level, so "unmute" returns
    /// to the volume in use before the mute instead of a hardcoded 50 (S6).
    private static func setMuted(_ muted: Bool) throws {
        _ = try runTool("/usr/bin/osascript", arguments: ["-e", "set volume output muted \(muted)"])
    }

    private static func adjustVolume(by delta: Int) throws -> Int {
        let raw = try runTool("/usr/bin/osascript", arguments: ["-e", "output volume of (get volume settings)"])
        let current = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 50
        let next = min(100, max(0, current + delta))
        let applied = next - current
        if applied != 0 { try setVolume(next) }
        return applied
    }

    /// Drives a named media app (Music/Spotify) directly via AppleScript.
    /// Used when the transcript names the app or no now-playing source exists.
    private static func driveMediaApp(_ app: String, command: String) throws {
        // Only Music & Spotify are scriptable media apps; check presence first
        // so an uninstalled app surfaces a clean error instead of AppleScript's
        // confusing "the variable play is not defined".
        guard AppResolver.isInstalled(app) else {
            throw ActionExecutionError.unknownApp(name: app)
        }
        var lastError: Error?
        do {
            _ = try runTool("/usr/bin/osascript", arguments: ["-e", "tell application \"\(app)\" to \(command)"])
            return
        } catch {
            lastError = error
        }
        if app.caseInsensitiveCompare("Music") == .orderedSame {
            do {
                _ = try runTool("/usr/bin/osascript", arguments: ["-e", "tell application \"Spotify\" to \(command)"])
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ActionExecutionError.parseFailure
    }

    private static func namedMediaApp(in lower: String) -> String? {
        if lower.contains("spotify") { return "Spotify" }
        if lower.contains("apple music") || lower.contains(" music") || lower.contains("itunes") { return "Music" }
        return nil
    }

    public enum MediaKind: Sendable { case play, pause, toggle, next, previous }

    /// Phrase → playback op, in the order the dispatcher's if-chain used. Pure
    /// and separated from execution like `systemOperation(for:)`, so the replay
    /// harness scores the exact op the dispatcher would run
    /// (atlas/docs/live-demo-v1-plan.md, Phase 0.4).
    public static func mediaOperation(for transcript: String) -> MediaKind {
        let lower = transcript.lowercased()
        if lower.contains("pause") || lower.contains("stop the music") { return .pause }
        // Track change before playback verbs: "play the last one" is previous,
        // and "playback" must not read as "back" (word boundary).
        if lower.contains("previous") || lower.contains("last song") || lower.contains("last one")
            || lower.containsWord("back") { return .previous }
        if lower.contains("next") || lower.contains("skip") || lower.contains("forward") { return .next }
        if lower.contains("resume") || lower.contains("play") || lower.contains("continue") { return .play }
        return .toggle
    }

    private static func actionLabel(_ kind: MediaKind, command: String) -> String {
        switch kind {
        case .play: "Played"
        case .pause: "Paused"
        case .next: "Next track"
        case .previous: "Previous track"
        case .toggle: "Play/pause toggled"
        }
    }

    // MARK: - File helpers

    /// Returns the number of items Finder actually moved, so a zero-match run is
    /// reported as "nothing matched" instead of a success.
    @discardableResult
    private static func moveDownloads(matching matcher: String, to destURL: URL) throws -> Int {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        let script = """
        tell application "Finder"
            set theItems to (every item of folder "\(downloads.appleScriptEscaped)" whose name contains "\(matcher.appleScriptEscaped)")
            set n to count of theItems
            if n > 0 then move theItems to folder "\(destURL.path.appleScriptEscaped)"
            return n
        end tell
        """
        let output = try runTool("/usr/bin/osascript", arguments: ["-e", script])
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func ensureFolder(named name: String) throws -> URL {
        var candidate = documents.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = desktop.appendingPathComponent(name)
        }
        if !FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        }
        return candidate
    }

    /// Resolves a folder alias to its canonical home location.
    private static func folderURL(named name: String) throws -> URL {
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let mapped: URL
        switch name.lowercased() {
        case "downloads": mapped = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case "desktop": mapped = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case "documents": mapped = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        case "pictures": mapped = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        case "music": mapped = fm.urls(for: .musicDirectory, in: .userDomainMask)[0]
        case "movies": mapped = fm.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        case "home": mapped = homeURL
        case "applications":
            if FileManager.default.fileExists(atPath: "/Applications") {
                mapped = URL(fileURLWithPath: "/Applications")
            } else {
                mapped = homeURL.appendingPathComponent("Applications")
            }
        default: mapped = homeURL
        }
        guard fm.fileExists(atPath: mapped.path) else {
            throw ActionExecutionError.parseFailure
        }
        return mapped
    }

    private static let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// Opens `url`'s app and waits until it is actually frontmost before the
    /// caller sends it a keystroke. Launch/activation takes ~0.5–2 s, and a ⌘V
    /// or ⌘N sent before that lands in Reflex or whatever was frontmost —
    /// silently typing into the wrong window (atlas/docs/audit-2026-10-14.md,
    /// M4). Blocks the calling thread, which is the detached dispatch thread,
    /// never the main actor.
    private static func openAndActivate(_ url: URL, timeout: TimeInterval = 3.0) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            _ = NSWorkspace.shared.open(url)
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID else { return }
        _ = NSWorkspace.shared.open(url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Types text as the user did in Jev: copy to the clipboard, then ⌘V
    /// (Cmd+V is the only keystroke that handles non-ASCII, accented, and
    /// multi-line). Optionally presses Return after depending on `submit`.
    private static func pasteText(_ text: String, withReturn submit: Bool) throws {
        try pbcopy(text)
        try ShortcutController.press(name: "paste")
        if submit {
            try ShortcutController.press(name: "enter")
        }
    }

    private static func pbcopy(_ text: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        process.arguments = []
        let input = Pipe()
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    // MARK: - Entities

    private static func extractPercent(from transcript: String) -> Int? {
        let patterns = [#"(\d{1,3})\s*(?:%|percent)"#, #"to\s+(\d{1,3})\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = transcript as NSString
            if let match = regex.firstMatch(in: transcript, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: match.range(at: 1))
                if let percent = Int(value) { return min(100, max(0, percent)) }
            }
        }
        return nil
    }

    /// Text between `labels.first` and `upTo` (case-insensitive), else nil.
    private static func phraseBetween(_ transcript: String, labels: [String], upTo: String? = nil) -> String? {
        let lower = transcript.lowercased()
        for label in labels {
            guard let start = lower.range(of: label) else { continue }
            var rest = String(transcript[start.upperBound...])
            if let upTo, let end = rest.lowercased().range(of: upTo) {
                rest = String(rest[..<end.lowerBound])
            }
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { return sanitizeName(rest) }
        }
        return nil
    }

    private static func sanitizeName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
        var parts = name.split(separator: " ")
        while let first = parts.first?.lowercased(), ["the", "a", "an", "my", "new"].contains(first) {
            parts.removeFirst()
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? raw : joined
    }

    // MARK: - Sites, URLs

    private static func looksLikeURL(_ name: String) -> Bool {
        let t = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
        guard !t.isEmpty, !t.contains(" ") else { return false }
        if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.") { return true }
        guard let parts = t.split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init) as [String]?, parts.count >= 2,
            let last = parts.last, PayloadExtractor.commonTLDs.contains(last) else {
            return false
        }
        return t.contains(".")
    }

    private static func normalizedURL(for name: String) -> URL {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
        if t.hasPrefix("http://") || t.hasPrefix("https://") {
            return URL(string: t) ?? URL(string: "https://\(t)")!
        }
        return URL(string: "https://\(t)")!
    }

    /// Per-site search URL host table, mirroring the Jev site catalog. Unknown
    /// sites fall back to a Google site-scoped search.
    private static func siteSearchURL(for site: PayloadExtractor.SiteSearch) -> URL {
        let host = site.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let rawQuery = site.query ?? ""
        let query = rawQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawQuery
        let url: String
        switch true {
        case host.contains("youtube"): url = "https://www.youtube.com/results?search_query=\(query)"
        case host.contains("wikipedia"): url = "https://en.wikipedia.org/w/index.php?search=\(query)"
        case host.contains("github"): url = "https://github.com/search?q=\(query)"
        case host.contains("reddit"): url = "https://www.reddit.com/search/?q=\(query)"
        case host.contains("maps"): url = "https://www.google.com/maps/search/\(query)"
        case host.contains("amazon"): url = "https://www.amazon.com/s?k=\(query)"
        case host.contains("imdb"): url = "https://www.imdb.com/find/?q=\(query)"
        case host.contains("netflix"): url = "https://www.netflix.com/search?q=\(query)"
        case host.contains("google"): url = "https://www.google.com/search?q=\(query)"
        case host.contains("twitter"): url = "https://twitter.com/search?q=\(query)"
        case host.contains("instagram"): url = "https://www.instagram.com/explore/tags/\(query.replacingOccurrences(of: " ", with: ""))/"
        default:
            // Unknown site — search Google scoped to that domain.
            url = "https://www.google.com/search?q=\(query)%20site:\(host)"
        }
        return URL(string: url) ?? URL(string: "https://www.google.com/search?q=\(query)")!
    }

    private static func openSiteSearch(_ site: PayloadExtractor.SiteSearch) throws -> ReflexActionResult {
        let url = siteSearchURL(for: site)
        _ = try BrowserController.open(url)
        return .searchedWeb(query: site.query ?? "", site: site.host)
    }

    // MARK: - Process

    static func runTool(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain before waiting. A child that writes more than the pipe buffer
        // (~64 KB) blocks on write, and then waitUntilExit() blocks with it.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ActionExecutionError.unexpectedExit(
                code: process.terminationStatus,
                command: executable,
                output: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return text
    }
}
#else
public enum ReflexActionResult: Sendable {
    case noOp(reason: String)
    case stopped
    public var summary: String {
        switch self {
        case .noOp(let reason): reason
        case .stopped: "Stopped listening"
        }
    }
}
public struct ActionDispatcher: Sendable {
    public init() {}
    public func dispatch(_ decision: ReflexDecision) throws -> ReflexActionResult {
        .noOp(reason: "action dispatch is macOS-only")
    }
}
#endif
