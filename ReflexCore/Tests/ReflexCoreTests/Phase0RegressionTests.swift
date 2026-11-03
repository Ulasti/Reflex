import Testing
import Foundation
@testable import ReflexCore

/// Phase 0 regression locks for invariants the roadmap depends on.
/// AppModel-level double-dispatch invariants (early commit vs finalized) live in
/// the app target, which has no test target yet — see Atlas Doctor D1/D14.
/// These core-level locks guard the building blocks.
@Suite("Phase 0 regression")
struct Phase0RegressionTests {

    @Test("low confidence is not executable")
    func lowConfidenceNotExecutable() {
        let arbiter = DecisionArbiter()
        #expect(!arbiter.shouldExecute(confidence: 0.06, addressed: 0.5))
        #expect(!arbiter.shouldExecute(confidence: 0.30, addressed: 0.5))
    }

    @Test("high confidence + addressed is executable")
    func highConfidenceExecutable() {
        let arbiter = DecisionArbiter()
        #expect(arbiter.shouldExecute(confidence: 0.9, addressed: 0.9))
    }

    @Test("sanitizer rejects repetition loops")
    func sanitizerRejectsLoops() {
        let result = TranscriptSanitizer.sanitize("next song next song next song")
        #expect(result != .accepted("next song next song next song"))
    }

    @Test("compound router does not split a lone connective")
    func loneConnectiveNotCompound() {
        // "and" alone must not be treated as a compound utterance; otherwise a
        // single low-confidence token can be routed as if it were two clauses.
        #expect(!CompoundRouter.isCompound("and"))
    }

    @Test("rule router classifies volume phrases as media_control")
    func volumePhrases() {
        #expect(RuleRouter().classify("volume up")?.target == "media_control")
        #expect(RuleRouter().classify("volume down")?.target == "media_control")
    }

    @Test("incremental gate excludes text entry and file ops")
    func incrementalGateSafety() {
        #expect(!IncrementalCommitGate.isEligible(target: "type_text"))
        #expect(!IncrementalCommitGate.isEligible(target: "file_operation"))
    }
}