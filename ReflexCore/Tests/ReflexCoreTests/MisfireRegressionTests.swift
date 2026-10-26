import XCTest
@testable import ReflexCore

final class MisfireRegressionTests: XCTestCase {
    func testFiftyTimesTwentyProducesNoOp() {
        let router = RuleRouter()
        let decision = router.classify("50 times 20")
        // "50 times 20" has no strong rule match; ensure it does not resolve to file_operation
        if let decision = decision {
            XCTAssertNotEqual(decision.target, "file_operation")
        } else {
            XCTAssertNil(decision) // acceptable: defer to Laya/arbiter
        }
    }

    /// "silence it" is the mute command; only an utterance that *is* the
    /// placeholder counts as silence, or the command was thrown away as noise.
    func testSilenceMarkerDoesNotSwallowSilenceCommand() {
        XCTAssertTrue(ReflexSystemEngine.isSilenceMarker("[BLANK_AUDIO]"))
        XCTAssertTrue(ReflexSystemEngine.isSilenceMarker("(silence)"))
        XCTAssertTrue(ReflexSystemEngine.isSilenceMarker("Silence."))
        XCTAssertFalse(ReflexSystemEngine.isSilenceMarker("silence it"))
        XCTAssertFalse(ReflexSystemEngine.isSilenceMarker("play some music"))
    }

    /// The train-only mishearing table: words that cannot mean anything else,
    /// with dictation exempt because those words are the user's payload.
    func testMishearingAliases() {
        XCTAssertEqual(PayloadExtractor.normalizeIntent("Skull down"), "scroll down")
        XCTAssertEqual(PayloadExtractor.normalizeIntent("Lover"), "louder")
        XCTAssertEqual(PayloadExtractor.normalizeIntent("Under it"), "undo it")
        XCTAssertEqual(PayloadExtractor.normalizeIntent("type this under the heading"),
                       "type this under the heading")
    }

    /// Logged in the live session: "open the third page" came out as Google
    /// Maps and "go to the forward page" (an app that does not exist) failed as
    /// "Execute failed". A decisive rule means a known target — an open/launch
    /// whose entity resolves to nothing must fall below 0.9 so Laya and the
    /// 0.4 abstention see it instead of a confident wrong action.
    func testUnresolvableOpenIsNotDecisive() {
        let router = RuleRouter()
        for phrase in ["open the third page", "go to the forward page"] {
            guard let decision = router.classify(phrase) else { continue }
            XCTAssertFalse(
                decision.target == "open_app" && decision.isDecisive,
                "\(phrase) → \(decision.target) @ \(decision.confidence)"
            )
        }
    }

    /// An exact catalog app name is certain; a unique-prefix guess ("open
    /// note" → Notes) is not decisive, so only the exact name skips Laya.
    func testFuzzyAppMatchIsNotDecisive() {
        let router = RuleRouter()
        let exact = router.classify("open notes")
        XCTAssertEqual(exact?.target, "open_app")
        XCTAssertEqual(exact?.confidence, 0.95)
        let fuzzy = router.classify("open note")
        XCTAssertEqual(fuzzy?.target, "open_app")
        XCTAssertNotEqual(fuzzy?.confidence, 0.95)
        XCTAssertFalse(fuzzy?.isDecisive ?? true)
    }
}
