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
    /// phrase is single-action (no supportive `and`/`then` connective and no
    /// sentence boundary).
    public static func split(_ transcript: String) -> [Part] {
        // Sentence boundaries are hard splits: Whisper puts two back-to-back
        // commands in one segment ("Open YouTube.com. Open a new tab") because
        // the VAD gate can be longer than the pause, and only the second clause
        // used to execute. A domain period is never followed by a space, so a
        // period at the end of a word is a sentence end here. Both sides must
        // look like actions, so ordinary prose stays whole.
        let sentences = sentenceParts(transcript)
        if sentences.count > 1, sentences.allSatisfy({ looksLikeClauseStart($0) }) {
            return sentences.flatMap { sentence -> [Part] in
                let clause = sentence.trimmingCharacters(in: CharacterSet(charactersIn: " \t.!?"))
                guard !clause.isEmpty else { return [] }
                let inner = splitConnectives(clause)
                if !inner.isEmpty { return inner }
                // A single-clause sentence keeps the trailing "and press enter"
                // fold the whole-utterance path applies.
                let submit = trailingSubmit(from: clause)
                let trimmed = stripTrailingSubmit(clause)
                return [Part(transcript: trimmed.isEmpty ? clause : trimmed, submit: submit)]
            }
        }
        return splitConnectives(transcript)
    }

    /// Sentence boundaries need a weaker test than the connective split: the
    /// second sentence may legitimately begin with a payload verb ("Type buy
    /// milk"), which the connective path rejects because there the left side is
    /// the text being typed. Prose still fails — "hello" and "what" are not
    /// command verbs, so "hello. what is the capital of France?" stays whole.
    private static func looksLikeClauseStart(_ clause: String) -> Bool {
        if looksLikeActionStart(clause) { return true }
        let lower = clause.lowercased()
        return payloadVerbs.contains { lower.hasPrefix($0) }
    }

    /// Splits on ". ", "! " and "? " (the whitespace is already consumed by the
    /// word split).
    private static func sentenceParts(_ transcript: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for unit in transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true) {
            current.append(String(unit))
            if unit.hasSuffix(".") || unit.hasSuffix("!") || unit.hasSuffix("?") {
                out.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    private static func splitConnectives(_ transcript: String) -> [Part] {
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
                // The right side is a trailing submit-only tail (like "press enter").
                // We want to split it off as a separate action.
                parts.append(left)
                parts.append(right)
                text = "" // So that the loop ends.
                break
            }
            parts.append(left)
            text = right
        }
        if parts.isEmpty {
            return []
        }
        parts.append(text)
        return parts.enumerated().map { index, part in
            let submit = trailingSubmit(from: part)
            let trimmed = stripTrailingSubmit(part)
            return Part(transcript: trimmed.isEmpty ? part : trimmed, submit: submit)
        }
    }
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

    /// Verbs whose remainder is a free-text payload, not a new clause. "type
    /// this and that" is one typed message, not two actions.
    private static let payloadVerbs = [
        "type ", "write ", "paste ", "dictate ", "input ", "search ", "look up ",
        "look for ", "play ",
    ]

    /// A clause is a real action when it begins with a command verb (open,
    /// type, play, search, scroll, press, new, show, go, create, move, etc.).
    private static func looksLikeActionStart(_ clause: String) -> Bool {
        let lower = clause.lowercased()
        if payloadVerbs.contains(where: { lower.hasPrefix($0) }) { return false }
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
             "and press enter", "then press enter", "new line", "press tab",
             "hit tab", "and new line", "and press tab"].contains(lower) {
            return false
        }
        // A trailing submit-only tail like "press enter" is folded, not split.
        return true
    }

    /// Detects a folded trailing "and press enter".
    public static func trailingSubmit(from clause: String) -> Bool {
        let lower = clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["press enter", "hit enter", "press return", "hit return", "submit",
                 "and press enter", "then press enter", "and hit enter", "and press return",
                 "new line", "press tab", "hit tab", "and new line", "and press tab"]
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
