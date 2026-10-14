import Foundation

/// Splits a compound utterance ("open notes and type buy milk and press enter")
/// into its parts and rebuilds each as its own plan, mirroring Jev's
/// `split_compound` + per-part Plan. A trailing "and press enter / hit submit"
/// folds into the *previous* part's `submit` flag instead of being treated as a
/// standalone shortcut.
public enum CompoundRouter {
    public struct Part: Sendable, Equatable {
        public let transcript: String
        public let submit: Bool

        public init(transcript: String, submit: Bool) {
            self.transcript = transcript
            self.submit = submit
        }
    }

    /// The separators Jev splits on, most specific first.
    private static let separators = [" and then ", " then ", " and also ", " and "]

    /// Whether an utterance reads as a compound command that should be split.
    public static func isCompound(_ transcript: String) -> Bool {
        !split(transcript).isEmpty
    }

    /// Returns the parts of a compound utterance, or an empty array when the
    /// phrase is single-action (no supportive `and`/`then` connective).
    public static func split(_ transcript: String) -> [Part] {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []

        // Find the *first* connective. Only split when the text after it is a
        // real, non-trivial clause; trailing "press enter" etc stays with the
        // prior part as submit.
        while let splitAt = supportingConnective(in: text) {
            let left = String(text[..<splitAt.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(text[splitAt.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // "press enter" trailing the whole utterance folds into `left`.
            if !remainingClause(right) {
                text = left
                break
            }
            parts.append(left)
            text = right
        }
        if parts.isEmpty {
            return []
        }
        parts.append(text)
        return parts.map { part in
            let submit = trailingSubmit(from: part)
            let trimmed = stripTrailingSubmit(part)
            return Part(transcript: trimmed.isEmpty ? part : trimmed, submit: submit)
        }
    }

    /// Finds the earliest `seps` connective whose *left* clause is a complete
    /// action (starts with a verb). "run and gun" must not split on "and"; a
    /// typed message full of "and"s ("type this and that") must not either,
    /// because its left side is mid-payload. Here any left side that already
    /// starts like a command is a split.
    private static func supportingConnective(in text: String) -> Range<String.Index>? {
        let lower = text.lowercased()
        for separator in separators {
            var searchStart = text.startIndex
            while let range = lower.range(of: separator, range: searchStart..<text.endIndex) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if looksLikeActionStart(before), !before.isEmpty {
                    return range
                }
                searchStart = range.upperBound
            }
        }
        return nil
    }

    /// A clause is a real action when it begins with a command verb (open,
    /// type, play, search, scroll, press, new, show, go, create, move, etc.).
    private static func looksLikeActionStart(_ clause: String) -> Bool {
        let lower = clause.lowercased()
        let verbs = [
            "open ", "launch ", "start ", "create ", "make ", "move ", "copy ",
            "type ", "write ", "paste ", "dictate ", "play ", "pause ", "stop ",
            "search ", "look up ", "scroll ", "go ", "show ", "press ", "hit ",
            "delete ", "rename ", "select ", "add ", "close ", "quit ", "new ",
            "set ", "turn ", "increase ", "decrease ", "bring up ", "pull up ",
        ]
        // Normalize "turn the volume up" — still starts with "turn ".
        for verb in verbs where lower.hasPrefix(verb) {
            return true
        }
        // "the first result", "the top link" are actions in context.
        if lower.hasPrefix("the ") { return true }
        return false
    }

    /// Whether `text` is a meaningful follow-up (not only "press enter").
    private static func remainingClause(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        let lower = t.lowercased()
        if ["press enter", "hit enter", "press return", "hit return",
            "and press enter", "then press enter"].contains(lower) {
            return false
        }
        // A trailing submit-only tail like "press enter" is folded, not split.
        return true
    }

    /// Detects a folded trailing "and press enter".
    public static func trailingSubmit(from clause: String) -> Bool {
        let lower = clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["press enter", "hit enter", "press return", "hit return", "submit",
                "and press enter", "then press enter", "and hit enter", "and press return"]
            .contains { lower.hasSuffix($0) }
    }

    /// Removes a trailing submit phrase so the clause is just the action text.
    public static func stripTrailingSubmit(_ clause: String) -> String {
        let tails = [
            " and press enter", " then press enter", " and hit enter", " then hit enter",
            " and press return", " then press return", " press enter", " hit enter",
            " and submit", " then submit", " submit",
        ]
        var t = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        for tail in tails where t.lowercased().hasSuffix(tail) {
            t = String(t.dropLast(tail.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
