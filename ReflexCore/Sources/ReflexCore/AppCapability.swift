import Foundation

/// A declarative description of what Reflex can do in one application.
/// Kept separate from transcription and the global intent classifier; an app's
/// capabilities are data, not code paths in the audio pipeline.
public struct ApplicationCapability: Sendable, Equatable, Identifiable {
    public let id: String
    public let appIdentifier: String
    public let supportedActions: [String]
    public let actionAliases: [String: [String]]
    public let requiredContext: [String]
    public let parameterSchema: [String: String]
    public let confidenceRequirements: [String: Double]
    public let confirmationPolicy: [String: Bool]
    public let fallbackBehavior: String
    public let capabilityVersion: String

    public init(
        id: String? = nil,
        appIdentifier: String,
        supportedActions: [String] = [],
        actionAliases: [String: [String]] = [:],
        requiredContext: [String] = [],
        parameterSchema: [String: String] = [:],
        confidenceRequirements: [String: Double] = [:],
        confirmationPolicy: [String: Bool] = [:],
        fallbackBehavior: String = "no_op",
        capabilityVersion: String = "1"
    ) {
        self.id = id ?? appIdentifier
        self.appIdentifier = appIdentifier
        self.supportedActions = supportedActions
        self.actionAliases = actionAliases
        self.requiredContext = requiredContext
        self.parameterSchema = parameterSchema
        self.confidenceRequirements = confidenceRequirements
        self.confirmationPolicy = confirmationPolicy
        self.fallbackBehavior = fallbackBehavior
        self.capabilityVersion = capabilityVersion
    }

    public func supports(_ action: String) -> Bool {
        supportedActions.contains(action)
    }
}

/// Registry of application capabilities. Global commands are always available
/// regardless of which app is active; app-specific capabilities are consulted
/// only when their app is frontmost (or explicitly targeted).
public final class AppCapabilityRegistry: @unchecked Sendable {
    private var capabilities: [String: ApplicationCapability] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(_ capability: ApplicationCapability) {
        lock.lock(); defer { lock.unlock() }
        capabilities[capability.appIdentifier] = capability
    }

    public func capability(for appIdentifier: String) -> ApplicationCapability? {
        lock.lock(); defer { lock.unlock() }
        return capabilities[appIdentifier]
    }

    public func all() -> [ApplicationCapability] {
        lock.lock(); defer { lock.unlock() }
        return Array(capabilities.values)
    }

    public func supports(appIdentifier: String, action: String) -> Bool {
        capability(for: appIdentifier)?.supports(action) ?? false
    }
}
