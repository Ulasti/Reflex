import AVFoundation
import Foundation

/// Decodes an audio file to the 16 kHz mono float samples Whisper expects.
public enum AudioFileLoader {
    public static func loadSamples16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: inputBuffer)

        let ratio = 16000 / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity)!

        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }

        let channel = outputBuffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}
