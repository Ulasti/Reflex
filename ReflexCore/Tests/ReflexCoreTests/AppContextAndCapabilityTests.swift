import Testing
import Foundation
@testable import ReflexCore

@Suite("App context")
struct AppContextTests {
    @Test("freshness holds within threshold")
    func fresh() {
        let ctx = AppContext(capturedAt: Date())
        #expect(ctx.isFresh())
    }

    @Test("stale context is not fresh")
    func stale() {
        let old = Date().addingTimeInterval(-5)
        let ctx = AppContext(capturedAt: old)
        #expect(!ctx.isFresh())
    }

    @Test("null provider returns empty context")
    func nullProvider() async {
        let ctx = await NullAppContextProvider().currentContext()
        #expect(ctx.frontmostBundleID == nil)
        #expect(ctx.confidence == 0)
    }
}

@Suite("App capability registry")
struct AppCapabilityRegistryTests {
    @Test("register and lookup")
    func registerLookup() {
        let reg = AppCapabilityRegistry()
        let cap = ApplicationCapability(appIdentifier: "com.apple.Calculator", supportedActions: ["clear_entry", "clear_all"])
        reg.register(cap)
        #expect(reg.capability(for: "com.apple.Calculator")?.supports("clear_entry") == true)
        #expect(reg.supports(appIdentifier: "com.apple.Calculator", action: "clear_all"))
        #expect(!reg.supports(appIdentifier: "com.apple.Calculator", action: "launch_rocket"))
    }

    @Test("unknown app has no capabilities")
    func unknown() {
        let reg = AppCapabilityRegistry()
        #expect(reg.capability(for: "com.example.nope") == nil)
    }

    @Test("global commands are not gated by registry")
    func globalNotGated() {
        // Registry only describes app-specific capabilities; absence must not
        // imply a global command is unsupported.
        let reg = AppCapabilityRegistry()
        #expect(reg.capability(for: "global") == nil)
    }
}
