import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Converts a continuous raw-samples stream into discrete speech segments.
///
/// Whisper is not a streaming model, so "live" feels like high-frequency VAD:
/// the underlying audio is sliced into short energy windows, speech runs are
/// accumulated, and a segment is emitted ~0.6 s after the speaker stops (or
/// when a run hits the cap). A separate adaptively-set threshold keeps the
/// classifier robust to room tone. `feed` may be called from the audio thread.
public final class StreamSegmenter: @unchecked Sendable {
    /// Samples per energy window (1600 @ 16 kHz = 100 ms).
    public let window: Int
    /// Consecutive silent windows that end a segment (7 = 0.7 s).
    public let maxSilenceWindows: Int
    /// Minimum speech windows before a segment counts (4 = 0.4 s).
    public let minSpeechWindows: Int
    /// Hard cap on one segment's length in samples (10 s), bounds memory.
    public let maxSegmentSamples: Int
    /// Windows skipped after a segment ends before the next may start.
    public let rearmWindows: Int

    private var carry: [Float] = []
    private var speech: [Float] = []
    private var speechWindows = 0
    private var silenceWindows = 0
    private var lastSpeechEnd = 0
    private var rearm = 0
    private var noiseFloor: Float = 0.0005

    /// Called on the audio thread with each finalized speech segment.
    public var onSegment: (@Sendable ([Float]) -> Void)?
    /// Called on the audio thread ~every 100 ms with (normalized rms, speaking).
    public var onLevel: (@Sendable (Float, Bool) -> Void)?
    /// Called on the audio thread with the current rolling speech window each
    /// time a speech window is processed (~100 ms cadence). Consumers feed it
    /// to a streaming transcriber for live partials; throttle downstream.
    public var onPartial: (@Sendable ([Float]) -> Void)?

    public init(
        window: Int = 1600,
        maxSilenceWindows: Int = 7,
        minSpeechWindows: Int = 4,
        maxSegmentSamples: Int = 160_000,
        rearmWindows: Int = 4
    ) {
        self.window = window
        self.maxSilenceWindows = maxSilenceWindows
        self.minSpeechWindows = minSpeechWindows
        self.maxSegmentSamples = maxSegmentSamples
        self.rearmWindows = rearmWindows
    }

    public func feed(_ samples: [Float]) {
        var buffer = carry
        carry = []
        buffer.append(contentsOf: samples)

        guard buffer.count >= window else {
            carry = buffer
            return
        }

        var offset = 0
        while offset + window <= buffer.count {
            processWindow(Array(buffer[offset..<(offset + window)]))
            offset += window
        }
        carry = Array(buffer[offset...])

        if speech.count >= maxSegmentSamples {
            finalize()
        }
    }

    /// Emits the trailing partial segment if one is still open. Call when the
    /// source ends (stream closed, input final).
    public func flush() {
        if speechWindows >= minSpeechWindows {
            finalize()
        } else {
            reset()
        }
    }

    private func processWindow(_ win: [Float]) {
        defer {
            let rms = Float(AudioPreflight.rms(win))
            onLevel?(min(1, rms * 8), speaking)
        }

        guard rearm == 0 else {
            rearm -= 1
            return
        }

        let rms = Float(AudioPreflight.rms(win))
        let threshold = max(noiseFloor * 2.2, 0.0012)

        if rms >= threshold {
            speech.append(contentsOf: win)
            speechWindows += 1
            silenceWindows = 0
            lastSpeechEnd = speech.count
            speaking = true
            onPartial?(Array(speech[0..<lastSpeechEnd]))
        } else {
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
            if speechWindows > 0 {
                speech.append(contentsOf: win)
                silenceWindows += 1
                if silenceWindows >= maxSilenceWindows {
                    finalize()
                }
            } else {
                speaking = false
            }
        }
    }

    private func finalize() {
        guard speechWindows >= minSpeechWindows, lastSpeechEnd > 0 else {
            reset()
            return
        }
        let segment = Array(speech[0..<lastSpeechEnd])
        reset()
        if segment.count >= minSpeechWindows * window {
            onSegment?(segment)
        }
    }

    private func reset() {
        speech = []
        speechWindows = 0
        silenceWindows = 0
        lastSpeechEnd = 0
        speaking = false
        rearm = rearmWindows
    }

    public private(set) var speaking = false
}

/// Offline variant of `StreamSegmenter` for files: splits a whole capture into
/// speech sections so the CLI can replay the exact streaming path headlessly.
public enum SpeechSegmentifier {
    public struct Section: Sendable, Equatable {
        public let sampleRange: Range<Int>
    }

    public static func sections(in samples: [Float], window: Int = 1600) -> [Section] {
        guard samples.count >= window else { return [] }
        let peak = AudioPreflight.peak(samples)
        let threshold = max(Double(peak) * 0.02, 0.0005)

        var result: [Section] = []
        var start: Int?
        var lastSpeechEnd = -1
        var silenceRuns = 0
        var offset = 0
        while offset + window <= samples.count {
            let slice = samples[offset..<(offset + window)]
            let energy = slice.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = (energy / Double(window)).squareRoot()
            if rms >= threshold {
                if start == nil { start = offset }
                lastSpeechEnd = offset + window
                silenceRuns = 0
            } else if start != nil {
                silenceRuns += 1
                if silenceRuns >= 6 {
                    result.append(Section(sampleRange: start!..<lastSpeechEnd))
                    start = nil
                    silenceRuns = 0
                }
            }
            offset += window
        }
        if let start { result.append(Section(sampleRange: start..<max(lastSpeechEnd, start))) }
        return result
    }
}

/// Bounded-memory live mic wrapper around `StreamSegmenter`. Owns the
/// `AudioCaptureManager`, runs the VAD on the audio thread, and forwards
/// segment + level events to caller-provided sendable closures.
public final class MicMonitor: @unchecked Sendable {
    private let capture: AudioCaptureManager
    private let segmenter: StreamSegmenter

    /// Called on the audio thread with each finalized speech segment.
    public var onSegment: (@Sendable ([Float]) -> Void)? {
        get { segmenter.onSegment }
        set { segmenter.onSegment = newValue }
    }
    /// Called on the audio thread ~every 100 ms with (normalized rms, speaking).
    public var onLevel: (@Sendable (Float, Bool) -> Void)? {
        get { segmenter.onLevel }
        set { segmenter.onLevel = newValue }
    }

    /// Called on the audio thread with the current rolling speech window.
    public var onPartial: (@Sendable ([Float]) -> Void)? {
        get { segmenter.onPartial }
        set { segmenter.onPartial = newValue }
    }

    public private(set) var isRunning = false

    public init(capture: AudioCaptureManager = AudioCaptureManager(),
                segmenter: StreamSegmenter = StreamSegmenter(),
                deviceID: UInt32? = nil) {
        self.capture = capture
        #if os(macOS)
        if let deviceID { self.capture.deviceID = deviceID }
        #endif
        self.segmenter = segmenter
    }

    public func start() throws {
        guard !isRunning else { return }
        capture.storeSamples = false
        capture.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.segmenter.feed(chunk)
        }
        try capture.start()
        isRunning = true
    }

    public func stop() {
        capture.onChunk = nil
        capture.stop()
        isRunning = false
    }
}
