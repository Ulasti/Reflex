import Foundation

extension String {
    /// Whole-word, case-insensitive containment. Use where a plain substring
    /// test is too loose: "display" contains "play", "unlock" contains "lock".
    func containsWord(_ word: String) -> Bool {
        range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
