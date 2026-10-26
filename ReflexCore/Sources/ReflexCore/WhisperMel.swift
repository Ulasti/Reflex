import Accelerate
import Foundation

/// Whisper log-mel frontend, matching `whisper.audio.log_mel_spectrogram`
/// numerically: reflect-padded STFT (n_fft 400, hop 160), power spectrum,
/// whisper's baked mel filterbank, log10 clamp, global -8 floor, and the
/// `(x + 4) / 4` affine normalization. Output is `n_mels x 3000`, row-major.
public struct WhisperMel {
    static let sampleRate = 16_000
    static let nFFT = 400
    static let hopLength = 160
    static let chunkFrames = 3000
    static let nBins = nFFT / 2 + 1
    static let pad = nFFT / 2

    let nMel: Int
    private let filters: [Float]

    public init(nMel: Int) throws {
        guard let url = Bundle.module.url(
            forResource: "whisper-mel-\(nMel)",
            withExtension: "bin"
        ) else {
            throw WhisperMelError.missingFilterbank(nMel)
        }
        let data = try Data(contentsOf: url)
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count == nMel * Self.nBins else {
            throw WhisperMelError.corruptFilterbank(nMel)
        }
        self.nMel = nMel
        self.filters = floats
    }

    /// `samples` are 16 kHz mono floats in [-1, 1]. Returns `nMel * 3000`.
    public func logMel(samples: [Float]) -> [Float] {
        let frameCount = samples.count / Self.hopLength
        let window = Self.hannWindow()
        let (cosTable, sinTable) = Self.dftTables()

        var power = [Float](repeating: 0, count: 201 * max(frameCount, 0))
        let padded = Self.reflectPad(samples, pad: Self.pad)

        var frame = [Float](repeating: 0, count: Self.nFFT)
        for f in 0..<frameCount {
            let start = f * Self.hopLength
            for n in 0..<Self.nFFT {
                frame[n] = padded[start + n] * window[n]
            }
            for k in 0..<201 {
                let base = k * Self.nFFT
                var re: Float = 0
                var im: Float = 0
                cosTable.withUnsafeBufferPointer { c in
                    sinTable.withUnsafeBufferPointer { s in
                        vDSP_dotpr(frame, 1, c.baseAddress! + base, 1, &re, vDSP_Length(Self.nFFT))
                        vDSP_dotpr(frame, 1, s.baseAddress! + base, 1, &im, vDSP_Length(Self.nFFT))
                    }
                }
                power[k * frameCount + f] = re * re + im * im
            }
        }

        var mel = [Float](repeating: 0, count: nMel * frameCount)
        for m in 0..<nMel {
            for f in 0..<frameCount {
                var acc: Float = 0
                filters.withUnsafeBufferPointer { filt in
                    power.withUnsafeBufferPointer { p in
                        vDSP_dotpr(
                            filt.baseAddress! + m * Self.nBins, 1,
                            p.baseAddress! + f, frameCount,
                            &acc, vDSP_Length(Self.nBins)
                        )
                    }
                }
                mel[m * frameCount + f] = acc
            }
        }

        for i in 0..<mel.count {
            mel[i] = log10(max(mel[i], 1e-10))
        }
        var maxVal = -Float.greatestFiniteMagnitude
        for i in 0..<mel.count { maxVal = max(maxVal, mel[i]) }
        let floor = maxVal - 8.0
        for i in 0..<mel.count {
            mel[i] = (max(mel[i], floor) + 4.0) / 4.0
        }

        let outFrames = Self.chunkFrames
        var out = [Float](repeating: 0, count: nMel * outFrames)
        let copies = min(frameCount, outFrames)
        for m in 0..<nMel {
            for f in 0..<copies {
                out[m * outFrames + f] = mel[m * frameCount + f]
            }
        }
        return out
    }

    private static func hannWindow() -> [Float] {
        (0..<nFFT).map { n in
            0.5 - 0.5 * cos(2 * Float.pi * Float(n) / Float(nFFT))
        }
    }

    private static func dftTables() -> ([Float], [Float]) {
        var cosTable = [Float](repeating: 0, count: 201 * nFFT)
        var sinTable = [Float](repeating: 0, count: 201 * nFFT)
        for k in 0..<201 {
            let base = k * nFFT
            for n in 0..<nFFT {
                let angle = 2 * Float.pi * Float(k * n) / Float(nFFT)
                cosTable[base + n] = cos(angle)
                sinTable[base + n] = -sin(angle)
            }
        }
        return (cosTable, sinTable)
    }

    private static func reflectPad(_ samples: [Float], pad: Int) -> [Float] {
        guard samples.count > pad else {
            return [Float](repeating: 0, count: pad) + samples + [Float](repeating: 0, count: pad)
        }
        var out = [Float](repeating: 0, count: samples.count + 2 * pad)
        for i in 0..<pad { out[pad - 1 - i] = samples[i + 1] }
        for i in 0..<samples.count { out[pad + i] = samples[i] }
        for i in 0..<pad { out[pad + samples.count + i] = samples[samples.count - 2 - i] }
        return out
    }
}

enum WhisperMelError: LocalizedError {
    case missingFilterbank(Int)
    case corruptFilterbank(Int)

    var errorDescription: String? {
        switch self {
        case .missingFilterbank(let n): "No mel filterbank resource for \(n) mels."
        case .corruptFilterbank(let n): "Mel filterbank for \(n) mels is malformed."
        }
    }
}
