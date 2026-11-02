import Foundation

/// Deterministic transcript cleaning/validation between Whisper output and
/// command interpretation. Preserves the raw transcript for diagnostics.
public enum TranscriptSanitizer {

    public enum Result: Sendable, Equatable {
        case accepted(String)
        case rejected(reason: String)
    }

    /// Standalone non-speech annotations produced by Whisper/WhisperKit.
    private static let annotationPattern = try! NSRegularExpression(
        pattern: #"^\s*\([^)]*\)\s*$"#, options: []
    )

    /// Known non-speech markers (matched as the whole transcript).
    private static let knownMarkers: Set<String> = [
        "silence", "silent", "music", "applause", "laughter", "laughing",
        "coughing", "sighs", "sigh", "blank_audio", "inaudible", "noise"
    ]

    public static func sanitize(_ raw: String) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(reason: "empty_transcript") }

        // Standalone non-speech annotation: "(music)", "(silence)", etc.
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if annotationPattern.firstMatch(in: trimmed, options: [], range: range) != nil {
            let inner = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "() ")).lowercased()
            if knownMarkers.contains(where: { inner.contains($0) }) {
                return .rejected(reason: "non_speech_annotation")
            }
            // Unknown parenthesized content: keep it (could be dictated).
        }

        // Repetition / looping detection: same 2+ word phrase repeated 3+ times.
        let words = trimmed.lowercased().split(separator: " ")
        if words.count >= 6 {
            for phraseLen in 2...min(4, words.count / 3) {
                let phrase = words.prefix(phraseLen)
                var count = 0
                var i = 0
                while i + phraseLen <= words.count {
                    if Array(words[i..<(i + phraseLen)]) == Array(phrase) {
                        count += 1
                        i += phraseLen
                    } else {
                        i += 1
                    }
                }
                if count >= 3 {
                    return .rejected(reason: "repeated_transcript")
                }
            }
        }

        return .accepted(trimmed)
    }
}
