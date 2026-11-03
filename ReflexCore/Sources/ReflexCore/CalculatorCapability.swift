import Foundation

/// Typed semantic actions for Calculator. These are intent-level operations, not
/// keystrokes; the adapter maps them to the appropriate UI action.
public enum CalculatorAction: Sendable, Equatable {
    case clearEntry
    case clearAll
    case evaluate
    case enterNumber(String)
    case enterOperator(String)
    case readResult
    case undo
}

/// Provider for the Calculator app's capability pack.
public struct CalculatorCapabilityProvider: Sendable {
    public let bundleID = "com.apple.Calculator"

    public init() {}

    public func capability() -> ApplicationCapability {
        ApplicationCapability(
            appIdentifier: bundleID,
            supportedActions: ["clear_entry", "clear_all", "evaluate", "enter_number",
                               "enter_operator", "read_result", "undo"],
            actionAliases: [
                "clear_entry": ["clear this", "clear entry", "backspace"],
                "clear_all": ["clear everything", "clear all", "reset"],
                "evaluate": ["equals", "calculate", "what's the result"],
                "read_result": ["what is the result", "read result", "show result"],
                "undo": ["undo", "undo that"]
            ],
            requiredContext: ["frontmostApp"],
            confidenceRequirements: ["clear_all": 0.85, "clear_entry": 0.8],
            confirmationPolicy: ["clear_all": false],
            fallbackBehavior: "clarify",
            capabilityVersion: "1"
        )
    }
}

/// Adapter contract: given a resolved CalculatorAction and current context,
/// execute it and report success. macOS implementation uses Accessibility/UI;
/// tests inject a fake.
public protocol CalculatorActionAdapter: Sendable {
    func perform(_ action: CalculatorAction, context: AppContext) async throws -> Bool
}
