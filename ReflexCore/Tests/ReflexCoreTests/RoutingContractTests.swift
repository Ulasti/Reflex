import Testing
@testable import ReflexCore

/// The phrase to target contract of `RuleRouter`, transcribed from its rule
/// table and checked against the live router (`reflex-cli --rule`).
///
/// This is the regression net for the biggest structural finding
/// (`atlas/docs/audit-2026-10-14.md`, M3): `RuleRouter` and `ActionDispatcher`
/// each hold a phrase table and must agree.
@Suite("RuleRouter contract")
struct RoutingContractTests {
    @Test("phrase routes to the intended target", arguments: [
        // Display
        ("set the brightness to 50", "display_control"),
        ("turn up the brightness", "display_control"),
        ("turn the brightness up", "display_control"),
        // Media
        ("set the volume to 30", "media_control"),
        ("mute", "media_control"),
        ("turn up the volume", "media_control"),
        ("play some jazz", "media_control"),
        ("pause", "media_control"),
        ("next song", "media_control"),
        ("resume", "media_control"),
        ("play music", "media_control"),
        ("stop playing", "media_control"),
        // Typing
        ("type hello world", "type_text"),
        ("type buy milk in notes", "type_text"),
        ("dictate a note", "type_text"),
        // Clipboard-only phrases are the paste shortcut; free text after the
        // verb is still dictation (plan Phase 3.1).
        ("paste that", "shortcut"),
        ("paste hello world", "type_text"),
        // Browser
        ("next tab", "browser_command"),
        ("close the tab", "browser_command"),
        ("go back", "browser_command"),
        ("reload", "browser_command"),
        ("open the first result", "browser_command"),
        ("open the first link on the page", "browser_command"),
        ("click the second result", "browser_command"),
        // Scroll
        ("scroll down", "scroll"),
        ("jump to the top", "scroll"),
        ("scroll to the bottom", "scroll"),
        // Web search
        ("youtube.com search selfie", "web_search"),
        ("search for cats", "web_search"),
        ("look up the weather", "web_search"),
        // Apps
        ("open youtube.com", "open_app"),
        ("open notes", "open_app"),
        ("open calculator", "open_app"),
        ("quit calculator", "quit"),
        ("close safari", "quit"),
        // Files
        ("create a folder called invoices", "file_operation"),
        ("new folder called q3", "file_operation"),
        ("move the pdfs into archive", "file_operation"),
        ("move invoices to the desktop", "file_operation"),
        ("search for the invoice and copy the path", "file_operation"),
        ("find my invoice and copy the path", "file_operation"),
        // New item
        ("new note", "new_item"),
        ("new window", "new_item"),
        ("new document called q3 report", "new_item"),
        // Screenshot
        ("take a screenshot", "screenshot"),
        ("screenshot", "screenshot"),
        // Stop
        ("stop listening", "stop"),
        ("stop", "stop"),
        ("halt", "stop"),
        ("turn yourself off", "stop"),
        // Shortcuts
        ("copy that", "shortcut"),
        ("undo", "shortcut"),
        ("zoom in", "shortcut"),
        ("fullscreen", "shortcut"),
        // System
        ("lock the screen", "system_control"),
        ("reveal the desktop", "system_control"),
        ("set dark mode", "system_control"),
        ("turn on light mode", "system_control"),
        ("empty the trash", "system_control"),
        ("empty the bin", "system_control"),
        ("clear the trash", "system_control"),
        // Environment
        ("ssh into the server", "environment_setup"),
        ("deploy the backend", "environment_setup"),
        ("restart the server", "environment_setup"),
        ("run the build script", "environment_setup"),
        ("open a terminal", "environment_setup"),
        // General
        ("what is the capital of france", "general_query"),
        ("who is the president", "general_query"),
        ("explain quantum computing", "general_query"),
        ("tell me about ridgeline", "general_query"),
    ])
    func routes(phrase: String, expected: String) {
        #expect(RuleRouter().classify(phrase)?.target == expected)
    }

    @Test("a phrase no rule claims defers to Laya")
    func unmatchedDefers() {
        #expect(RuleRouter().classify("50 times 20") == nil)
    }
}

/// Phrases that used to misroute, pinned as regressions (audit M3, S8). Each
/// was a real, reproduced misroute, not a hypothetical; they carried
/// `withKnownIssue` until the router fix landed.
@Suite("RuleRouter regressions")
struct RoutingMismatchTests {
    @Test("a display-sleep phrase reaches system_control", arguments: [
        "turn off the display", "sleep the display", "put the display to sleep",
    ])
    func displaySleepRoutesToSystemControl(phrase: String) {
        #expect(RuleRouter().classify(phrase)?.target == "system_control")
    }

    @Test("\"display\" alone is not a media command")
    func displayIsNotMedia() {
        #expect(RuleRouter().classify("open the display")?.target != "media_control")
    }

    @Test("a show-desktop phrase reaches system_control", arguments: [
        "show desktop", "show the desktop", "go to the desktop",
    ])
    func showDesktopRoutesToSystemControl(phrase: String) {
        #expect(RuleRouter().classify(phrase)?.target == "system_control")
    }

    @Test("opening a browser by name is an app launch, not a web search")
    func openGoogleChromeIsAppLaunch() {
        #expect(RuleRouter().classify("open google chrome")?.target == "open_app")
    }
}
