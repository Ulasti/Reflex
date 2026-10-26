import Foundation
import Testing
@testable import ReflexCore

/// The live decode path's two guards: WhisperKit refuses windows under ~1.1 s
/// (this silently dropped short commands like "copy"), and it emits non-speech
/// markers that must never reach routing.
@Suite("LiveTranscriber decode guards")
struct LiveTranscriberDecodeTests {
    @Test("short windows pad to the minimum the model decodes")
    func shortWindowsArePadded() {
        let short = [Float](repeating: 0, count: 16_000)
        let padded = LiveTranscriber.decodeAudio(short)
        #expect(padded.count == 48_000)
        #expect(Array(padded.prefix(16_000)) == short)
    }

    @Test("long windows are untouched")
    func longWindowsAreUntouched() {
        let long = [Float](repeating: 0, count: 64_000)
        #expect(LiveTranscriber.decodeAudio(long) == long)
    }

    @Test("non-speech markers never reach routing")
    func dropsNonSpeechMarkers() {
        #expect(LiveTranscriber.clean("[BLANK_AUDIO] Copy.") == "Copy.")
        #expect(LiveTranscriber.clean("Copy. [MUSIC]") == "Copy.")
        #expect(LiveTranscriber.clean("Screen a bit darker") == "Screen a bit darker")
    }
}
