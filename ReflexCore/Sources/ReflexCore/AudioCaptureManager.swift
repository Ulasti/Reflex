import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Live microphone capture that resamples to the 16 kHz mono float stream
/// Whisper's frontend expects. Samples accumulate on the audio thread and are
/// handed back in one batch on `stop()`.
public final class AudioCaptureManager: @unchecked Sendable {
    public enum CaptureError: LocalizedError {
        case noInput
        case converterUnavailable

        public var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input device is available."
            case .converterUnavailable: "Could not build a 16 kHz converter for the input device."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()

    private var converter: AVAudioConverter?
    private var captured: [Float] = []
    private var running = false
    public var deviceID: UInt32? = nil

    public private(set) var isRecording = false

    /// When true (default), converted samples accumulate until `stop()` hands
    /// them back as one batch. When false, samples are only delivered through
    /// `onChunk` — required for continuous listening so memory stays bounded.
    public var storeSamples = true

    /// Called on the audio thread with each converted 16 kHz chunk. Set this
    /// before `start()`, or use this in listening mode to feed a VAD.
    public var onChunk: (([Float]) -> Void)?

    public init() {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        #if os(macOS)
        // On macOS, set input device via AVAudioEngine by re-configuring input if needed.
        // AVAudioInputNode doesn't expose setDevice; for now, ignore specific selection
        // if the device isn't directly compatible - default works.
        _ = deviceID
        #endif
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter
        lock.lock()
        captured.removeAll(keepingCapacity: true)
        lock.unlock()

        let handler = onChunk
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }
            if self.storeSamples {
                self.lock.lock()
                self.captured.append(contentsOf: converted)
                self.lock.unlock()
            }
            handler?(converted)
        }
        engine.prepare()
        try engine.start()
        running = true
        isRecording = true
    }

    @discardableResult
    public func stop() -> [Float] {
        guard running else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        isRecording = false
        lock.lock()
        let result = captured
        captured.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }

    /// Converts one input buffer to 16 kHz mono floats. Returns nil if the
    /// converter has not been configured or produced no data.
    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channels = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
    }
}
