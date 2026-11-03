import Foundation

/// Combines the spoken transcript with the active app context and the capability
/// registry into a single decision context. Routing stays global-first; the
/// active app only adds candidate actions, never removes global ones.
public struct DecisionContext: Sendable, Equatable {
    public let transcript: String
    public let appContext: AppContext
    public let availableCapabilities: [ApplicationCapability]

    public init(transcript: String, appContext: AppContext, availableCapabilities: [ApplicationCapability]) {
        self.transcript = transcript
        self.appContext = appContext
        self.availableCapabilities = availableCapabilities
    }
}

public struct ContextAssembler: Sendable {
    private let provider: AppContextProvider
    private let registry: AppCapabilityRegistry

    public init(provider: AppContextProvider, registry: AppCapabilityRegistry) {
        self.provider = provider
        self.registry = registry
    }

    public func assemble(transcript: String) async -> DecisionContext {
        let ctx = await provider.currentContext()
        var caps: [ApplicationCapability] = []
        if let bundle = ctx.frontmostBundleID {
            if let cap = registry.capability(for: bundle) { caps.append(cap) }
        }
        // Global capability sentinel, if registered.
        if let global = registry.capability(for: "global") { caps.append(global) }
        return DecisionContext(transcript: transcript, appContext: ctx, availableCapabilities: caps)
    }
}
