import Foundation

/// Maps natural-language Calculator utterances to typed CalculatorAction.
/// Returns nil for ambiguous or unsupported phrases so the caller can ask a
/// concise clarification rather than guess (roadmap Phase 2).
public struct CalculatorCommandRouter: Sendable {
    public init() {}

    public func classify(_ raw: String) -> CalculatorAction? {
        let t = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;"))

        // Ambiguous bare "clear" → caller clarifies.
        if t == "clear" || t == "clear it" {
            return nil
        }
        // Clear entry.
        if t.contains("clear this") || t.contains("clear entry") || t.contains("backspace")
            || t.contains("delete last") || t.contains("clear last") {
            return .clearEntry
        }
        // Clear all.
        if t.contains("clear everything") || t.contains("clear all") || t == "reset"
            || t.contains("start over") || t.contains("clear the calculator") {
            return .clearAll
        }
        // Evaluate.
        if t == "equals" || t == "calculate" || t == "evaluate" || t == "compute" {
            return .evaluate
        }
        // Read result.
        if t.contains("result") || t.contains("answer") || t.contains("what did i get")
            || t == "what is it" {
            return .readResult
        }
        // Undo.
        if t.contains("undo") {
            return .undo
        }
        return nil
    }
}
