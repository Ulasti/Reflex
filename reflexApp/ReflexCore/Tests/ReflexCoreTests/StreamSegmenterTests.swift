import Foundation
import Testing
@testable import ReflexCore

/// The voice-activity segmenter that decides what reaches Whisper. It runs on
/// the audio thread and was previously untested, yet everything downstream
/// depends on where its boundaries land.
@Suite("StreamSegmenter")
struct StreamSegmenterTests {
    private static let rate: Float = 16_000

    private static func tone(windows: Int, amplitude: Float = 0.3) -> [Float] {
        let count = windows * StreamSegmenter().window
        return (0..<count).map { amplitude * sin(2 * Float.pi * 220 * Float($0) / rate) }
    }

    private static func silence(windows: Int) -> [Float] {
        [Float](repeating: 0, count: windows * StreamSegmenter().window)
    }

    private static func recorder() -> (StreamSegmenter, LockedBox<[[Float]]>) {
        let segmenter = StreamSegmenter()
        let collected = LockedBox<[[Float]]>([])
        segmenter.onSegment = { segment, reason, audioDuration in collected.withLock { $0.append(segment) } }
        return (segmenter, collected)
    }

    @Test("speech followed by enough silence emits exactly one segment")
    func emitsOneSegment() {
        let (segmenter, collected) = Self.recorder()
        segmenter.feed(Self.tone(windows: 10))
        segmenter.feed(Self.silence(windows: 8))

        let segments = collected.withLock { $0 }
        #expect(segments.count == 1)
        #expect(segments.first?.count == 10 * segmenter.window)
    }

    @Test("room tone alone emits nothing")
    func silenceEmitsNothing() {
        let (segmenter, collected) = Self.recorder()
        segmenter.feed(Self.silence(windows: 40))
        #expect(collected.withLock { $0 }.isEmpty)
    }

    @Test("a burst shorter than the floor is discarded")
    func shortBurstIsDiscarded() {
        let (segmenter, collected) = Self.recorder()
        segmenter.feed(Self.tone(windows: 3))
        segmenter.feed(Self.silence(windows: 8))
        #expect(collected.withLock { $0 }.isEmpty)
    }

    @Test("flush emits a still-open segment")
    func flushEmitsOpenSegment() {
        let (segmenter, collected) = Self.recorder()
        segmenter.feed(Self.tone(windows: 10))
        #expect(collected.withLock { $0 }.isEmpty)
        segmenter.flush()
        #expect(collected.withLock { $0 }.count == 1)
    }

    @Test("a segment is capped so a monologue cannot grow without bound")
    func segmentIsCapped() {
        let segmenter = StreamSegmenter(maxSegmentSamples: 6 * StreamSegmenter().window)
        let collected = LockedBox<[[Float]]>([])
        segmenter.onSegment = { segment, reason, audioDuration in collected.withLock { $0.append(segment) } }

        for _ in 0..<10 { segmenter.feed(Self.tone(windows: 1)) }

        let segments = collected.withLock { $0 }
        #expect(segments.count == 1)
        #expect(segments.first?.count == 6 * segmenter.window)
    }

    /// Two commands spoken back to back are two segments only if the pause
    /// between them reaches the silence gate. This is the boundary the Phase 2
    /// sweep moves.
    @Test("two commands separated by a pause at the gate emit two segments")
    func twoCommandsEmitTwoSegments() {
        let gate = StreamSegmenter().maxSilenceWindows
        let (segmenter, collected) = Self.recorder()
        segmenter.feed(Self.tone(windows: 8))
        segmenter.feed(Self.silence(windows: gate))
        #expect(collected.withLock { $0 }.count == 1)
        segmenter.feed(Self.tone(windows: 8))
        segmenter.feed(Self.silence(windows: gate))
        #expect(collected.withLock { $0 }.count == 2)
    }

    @Test("a pause one window short of the gate merges into one segment")
    func pauseShortOfGateMerges() {
        let gate = StreamSegmenter().maxSilenceWindows
        let (segmenter, collected) = Self.recorder()
        segmenter.feed(Self.tone(windows: 8))
        segmenter.feed(Self.silence(windows: gate - 1))
        segmenter.feed(Self.tone(windows: 8))
        #expect(collected.withLock { $0 }.isEmpty)
        segmenter.feed(Self.silence(windows: gate))
        let segments = collected.withLock { $0 }
        #expect(segments.count == 1)
        // The merged segment holds both speech runs around the short pause.
        #expect(segments.first!.count > 8 * segmenter.window)
    }

    @Test("the gate boundary holds at every swept length", arguments: [3, 4, 5, 7])
    func gateBoundaryIsExact(gate: Int) {
        let segmenter = StreamSegmenter(maxSilenceWindows: gate)
        let collected = LockedBox<[[Float]]>([])
        segmenter.onSegment = { segment, reason, audioDuration in collected.withLock { $0.append(segment) } }
        segmenter.feed(Self.tone(windows: 8))
        segmenter.feed(Self.silence(windows: gate - 1))
        #expect(collected.withLock { $0 }.isEmpty)
        segmenter.feed(Self.silence(windows: 1))
        #expect(collected.withLock { $0 }.count == 1)
    }
}
