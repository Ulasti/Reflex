import Foundation

/// Conditioning applied to raw mic captures before Whisper sees them.
///
/// A major source of empty transcripts is a quiet or short clip: the capture
/// includes silence before/after speech and the average level is low enough
/// that Whisper's mel loses the signal. Conditioning trims edge silence,
/// peak-normalizes, and rejects clips with too little speech to transcribe.
public enum AudioPreflight {
    /// Raw 16 kHz mono float PCM.
    public static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// Highest absolute sample in the clip.
    private static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0.0) { max($0, abs($1)) }
    }

    /// `nil` means the clip carries no audible speech (silence, or too short).
    public static func condition(_ samples: [Float]) -> [Float]? {
        let trimmed = trimSilence(samples)
        let speechSeconds = Double(trimmed.count) / 16_000
        guard speechSeconds >= 0.25 else { return nil }
        return peakNormalize(trimmed)
    }

    /// Removes leading/trailing low-energy windows. Interior speech is never
    /// touched, so this only helps encoder attention focus.
    private static func trimSilence(_ samples: [Float]) -> [Float] {
        let window = 256
        guard samples.count >= window else { return samples }
        let peak = peak(samples)
        let threshold = max(Double(peak) * 0.02, 0.0005)

        var first = -1
        var last = -1
        var offset = 0
        while offset + window <= samples.count {
            let slice = samples[offset..<(offset + window)]
            let energy = slice.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = (energy / Double(window)).squareRoot()
            if rms >= threshold {
                if first < 0 { first = offset }
                last = offset + window
            }
            offset += window
        }
        guard first >= 0 else { return [] }

        let margin = 2 * window
        let start = max(0, first - margin)
        let end = min(samples.count, last + margin)
        return Array(samples[start..<end])
    }

    private static func peakNormalize(_ samples: [Float]) -> [Float] {
        let peak = peak(samples)
        guard peak > 0.0001, peak < 0.98 else { return samples }
        let gain = 0.9 / peak
        return samples.map { $0 * gain }
    }
}
