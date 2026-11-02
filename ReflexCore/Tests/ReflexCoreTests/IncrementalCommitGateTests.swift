import Testing
import Foundation
@testable import ReflexCore

@Suite("Incremental commit gate")
struct IncrementalCommitGateTests {
    @Test("safe targets are eligible")
    func safeTargets() {
        #expect(IncrementalCommitGate.isEligible(target: "open_app"))
        #expect(IncrementalCommitGate.isEligible(target: "media_control"))
        #expect(IncrementalCommitGate.isEligible(target: "display_control"))
    }

    @Test("unsafe targets are not eligible")
    func unsafeTargets() {
        #expect(!IncrementalCommitGate.isEligible(target: "type_text"))
        #expect(!IncrementalCommitGate.isEligible(target: "file_operation"))
        #expect(!IncrementalCommitGate.isEligible(target: "shortcut"))
        #expect(!IncrementalCommitGate.isEligible(target: "general_query"))
    }

    @Test("buffer starts clean")
    func bufferClean() {
        let b = TranscriptEventBuffer(utteranceID: 1)
        #expect(b.provisionalTranscript == "")
        #expect(b.revision == 0)
        #expect(!b.isCommitted)
        #expect(!b.isFinalized)
    }

    @Test("updates bump revision")
    func bufferUpdate() {
        var b = TranscriptEventBuffer(utteranceID: 1)
        b.update("open")
        #expect(b.provisionalTranscript == "open")
        #expect(b.revision == 1)
        b.update("open safari")
        #expect(b.revision == 2)
        // identical update does not bump
        b.update("open safari")
        #expect(b.revision == 2)
    }

    @Test("new utterance resets state")
    func newUtterance() {
        var b = TranscriptEventBuffer(utteranceID: 1)
        b.update("open safari")
        b.markCommitted()
        b.startNew(utteranceID: 2)
        #expect(b.provisionalTranscript == "")
        #expect(b.revision == 0)
        #expect(!b.isCommitted)
    }
}
