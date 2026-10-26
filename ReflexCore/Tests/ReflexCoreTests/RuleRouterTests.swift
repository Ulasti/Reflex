import XCTest
@testable import ReflexCore

final class RuleRouterTests: XCTestCase {
    func testClassifyOpenCalculator() {
        let router = RuleRouter()
        let decision = router.classify("open calculator")
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.target, "open_app")
        XCTAssertGreaterThanOrEqual(decision?.confidence ?? 0, 0.9)
    }

    func testClassifySearchQuery() {
        let router = RuleRouter()
        let decision = router.classify("search for cats")
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.target, "web_search")
    }

    /// The demo phrasings the v1 command set must route (train + heldout
    /// shapes), driven from the recorded-corpus misses (plan Phase 3).
    func testDemoPhrasingsRoute() {
        let cases: [(String, String)] = [
            ("turn it up", "media_control"),
            ("crank it up", "media_control"),
            ("volume a bit higher", "media_control"),
            ("it's way too loud", "media_control"),
            ("turn it down", "media_control"),
            ("volume off", "media_control"),
            ("silence it", "media_control"),
            ("next track", "media_control"),
            ("previous track", "media_control"),
            ("last song", "media_control"),
            ("play the last one", "media_control"),
            ("back to the previous one", "media_control"),
            ("toggle playback", "media_control"),
            ("go up", "scroll"),
            ("move up", "scroll"),
            ("page up", "scroll"),
            ("take me to the top", "scroll"),
            ("go down", "scroll"),
            ("more down", "scroll"),
            ("take me to the bottom", "scroll"),
            ("screen capture", "screenshot"),
            ("grab the screen", "screenshot"),
            ("take a picture of the screen", "screenshot"),
            ("switch to dark", "system_control"),
            ("night mode", "system_control"),
            ("make it dark", "system_control"),
            ("show me the desktop", "system_control"),
            ("go to desktop", "system_control"),
            ("clear the screen", "system_control"),
            ("minimize everything", "system_control"),
            ("desktop, please", "system_control"),
            ("copy", "shortcut"),
            ("copy everything", "shortcut"),
            ("paste that", "shortcut"),
            ("put it here", "shortcut"),
            ("drop it in here", "shortcut"),
            ("take it back", "shortcut"),
            ("brighter", "display_control"),
            ("more light", "display_control"),
            ("less light", "display_control"),
            ("safari please", "open_app"),
            ("calendar", "open_app"),
            ("visit github", "open_app"),
            ("go to google", "open_app"),
            ("youtube.com", "open_app"),
            ("wikipedia.com", "open_app"),
            ("open note", "open_app"),
            ("open term", "open_app"),
        ]
        let router = RuleRouter()
        for (phrase, want) in cases {
            XCTAssertEqual(router.classify(phrase)?.target, want, "phrase: \(phrase)")
        }
    }

    /// Payload parse for the same phrasings: the op the dispatcher would run.
    func testDemoPhrasingPayloads() {
        XCTAssertEqual(PayloadExtractor.extract(from: "turn it up", target: "media_control").volumeOp, .up(delta: 15))
        XCTAssertEqual(PayloadExtractor.extract(from: "crank it up", target: "media_control").volumeOp, .up(delta: 15))
        XCTAssertEqual(PayloadExtractor.extract(from: "volume a bit higher", target: "media_control").volumeOp, .up(delta: 15))
        XCTAssertEqual(PayloadExtractor.extract(from: "it's way too loud", target: "media_control").volumeOp, .down(delta: 15))
        XCTAssertEqual(PayloadExtractor.extract(from: "silence it", target: "media_control").volumeOp, .mute)
        XCTAssertEqual(PayloadExtractor.extract(from: "volume off", target: "media_control").volumeOp, .mute)
        XCTAssertEqual(PayloadExtractor.extract(from: "go up", target: "scroll").direction, "up")
        XCTAssertEqual(PayloadExtractor.extract(from: "page down", target: "scroll").direction, "down")
        XCTAssertEqual(PayloadExtractor.extract(from: "take me to the top", target: "scroll").direction, "top")
        XCTAssertEqual(PayloadExtractor.extract(from: "Safari please", target: "open_app").appName, "Safari")
        XCTAssertEqual(PayloadExtractor.extract(from: "visit github", target: "open_app").appName, "github")

        // Op order: "play the last one" is previous, not play.
        if case .previous = ActionDispatcher.mediaOperation(for: "play the last one") {} else {
            XCTFail("play the last one → previous")
        }
        if case .next = ActionDispatcher.mediaOperation(for: "next track") {} else {
            XCTFail("next track → next")
        }
        XCTAssertEqual(ActionDispatcher.systemOperation(for: "night mode"), .darkMode(true))
        XCTAssertEqual(ActionDispatcher.systemOperation(for: "minimize everything"), .showDesktop)
        XCTAssertEqual(ActionDispatcher.brightnessOperation(for: "more light"), .up)
        XCTAssertEqual(ActionDispatcher.brightnessOperation(for: "less light"), .down)
    }

    /// The ground-truth oracle run (plan step 1) found these still unhandled
    /// with perfect ASR; spoken domains carry a space, "please" rides along,
    /// and two media phrasings were missing.
    func testOracleGapPhrasingsRoute() {
        let router = RuleRouter()
        XCTAssertEqual(router.classify("github dot com")?.target, "open_app")
        XCTAssertEqual(router.classify("wikipedia dot com")?.target, "open_app")
        XCTAssertEqual(router.classify("youtube dot com")?.target, "open_app")
        XCTAssertEqual(router.classify("google dot com")?.target, "open_app")
        XCTAssertEqual(router.classify("stop for a second")?.target, "media_control")
        XCTAssertEqual(router.classify("back to the previous one")?.target, "media_control")
        XCTAssertEqual(ActionDispatcher.systemOperation(for: "desktop, please"), .showDesktop)
        // A decisive rule is the one the engine may dispatch without Laya.
        XCTAssertEqual(router.classify("volume up")?.isDecisive, true)
        XCTAssertEqual(router.classify("night mode")?.isDecisive, false)
    }

    /// Confidence grades with match quality instead of reporting 0.90 for
    /// every rule hit: an utterance that *is* a catalog phrase is 0.95, one
    /// that merely contains the phrase keeps the rule's base, and the
    /// deliberately cautious rules stay where they are.
    func testConfidenceGradesWithMatchQuality() {
        let router = RuleRouter()
        XCTAssertEqual(router.classify("turn it up")?.confidence, 0.95)
        XCTAssertEqual(router.classify("raise the volume")?.confidence, 0.9)
        XCTAssertEqual(router.classify("press enter")?.confidence, 0.95)
        XCTAssertEqual(router.classify("please press enter for me")?.confidence, 0.9)
        XCTAssertEqual(router.classify("open notes")?.confidence, 0.95)
        XCTAssertEqual(router.classify("go to the forward page")?.confidence, 0.8)
        XCTAssertEqual(router.classify("night mode")?.confidence, 0.85)
        // A known site, bare or after a verb, stays decisive.
        XCTAssertEqual(router.classify("youtube.com")?.confidence, 0.95)
        XCTAssertEqual(router.classify("open youtube.com")?.isDecisive, true)
        XCTAssertEqual(router.classify("go to github")?.isDecisive, true)
    }
}
