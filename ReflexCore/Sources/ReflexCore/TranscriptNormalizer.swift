import Foundation

/// Cleans an ASR transcript before it reaches either the router or the
/// dispatcher. Whisper returns verbatim speech ("please open safari for me");
/// stripping the conversational filler helps Laya route on the real intent
/// and lets the dispatcher's entity extractors see a clean command.
public enum TranscriptNormalizer {
    private static let prefixes = [
        "hey reflex", "hey siri", "okay reflex", "ok reflex", "okay", "hey",
        "can you please", "could you please", "would you please", "can you",
        "could you", "would you", "i want you to", "i need you to",
        "i would like you to", "i'd like you to", "please make sure you",
        "please",
    ]

    public static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripping = true
        while stripping {
            stripping = false
            let lowered = text.lowercased()
            for prefix in prefixes {
                guard !prefix.isEmpty, lowered.hasPrefix(prefix) else { continue }
                guard let advance = text.index(text.startIndex, offsetBy: prefix.count, limitedBy: text.endIndex) else { continue }
                text = String(text[advance...]).trimmingCharacters(in: .whitespacesAndNewlines)
                stripping = true
                break
            }
        }

        if text.lowercased().hasSuffix(" please") {
            text = String(text.dropLast(" please".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var parts = text.split(separator: " ").filter { !$0.isEmpty }
        while let first = parts.first, first.isEmpty {
            parts.removeFirst()
        }
        text = parts.joined(separator: " ")

        return text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
    }
}
