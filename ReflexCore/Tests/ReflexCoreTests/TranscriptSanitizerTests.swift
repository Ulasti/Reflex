import Testing
@testable import ReflexCore

@Suite("TranscriptSanitizer")
struct TranscriptSanitizerTests {
    @Test("accepts normal command")
    func acceptsNormal() {
        if case .accepted(let t) = TranscriptSanitizer.sanitize("Open Safari") {
            #expect(t == "Open Safari")
        } else {
            #expect(Bool(false))
        }
    }

    @Test("rejects empty")
    func rejectsEmpty() {
        if case .rejected(let r) = TranscriptSanitizer.sanitize("   ") {
            #expect(r == "empty_transcript")
        } else { #expect(Bool(false)) }
    }

    @Test("rejects standalone annotation")
    func rejectsAnnotation() {
        if case .rejected(let r) = TranscriptSanitizer.sanitize("(music)") {
            #expect(r == "non_speech_annotation")
        } else { #expect(Bool(false)) }
        if case .rejected(let r) = TranscriptSanitizer.sanitize("(silence)") {
            #expect(r == "non_speech_annotation")
        } else { #expect(Bool(false)) }
    }

    @Test("accepts dictated parenthetical")
    func acceptsParenthetical() {
        if case .accepted = TranscriptSanitizer.sanitize("note (urgent)") { } else { #expect(Bool(false)) }
    }

    @Test("rejects repeated transcript")
    func rejectsRepeat() {
        if case .rejected(let r) = TranscriptSanitizer.sanitize("hello hello hello hello hello hello") {
            #expect(r == "repeated_transcript")
        } else { #expect(Bool(false)) }
    }
}
