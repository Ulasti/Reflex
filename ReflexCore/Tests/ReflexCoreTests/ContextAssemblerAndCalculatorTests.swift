import Testing
import Foundation
@testable import ReflexCore

@Suite("Context assembler")
struct ContextAssemblerTests {
    @Test("assembles global capability when registered")
    func globalCap() async {
        let reg = AppCapabilityRegistry()
        reg.register(ApplicationCapability(appIdentifier: "global", supportedActions: ["open_app"]))
        let assembler = ContextAssembler(provider: NullAppContextProvider(), registry: reg)
        let ctx = await assembler.assemble(transcript: "open safari")
        #expect(ctx.transcript == "open safari")
        #expect(ctx.availableCapabilities.count == 1)
    }

    @Test("no capabilities when provider reports nothing")
    func none() async {
        let reg = AppCapabilityRegistry()
        let assembler = ContextAssembler(provider: NullAppContextProvider(), registry: reg)
        let ctx = await assembler.assemble(transcript: "hi")
        #expect(ctx.availableCapabilities.isEmpty)
    }
}

@Suite("Calculator capability")
struct CalculatorCapabilityTests {
    @Test("calculator capability lists clear actions")
    func lists() {
        let cap = CalculatorCapabilityProvider().capability()
        #expect(cap.supports("clear_entry"))
        #expect(cap.supports("clear_all"))
        #expect(cap.appIdentifier == "com.apple.Calculator")
    }

    @Test("registry lookup for calculator")
    func registry() {
        let reg = AppCapabilityRegistry()
        reg.register(CalculatorCapabilityProvider().capability())
        #expect(reg.supports(appIdentifier: "com.apple.Calculator", action: "evaluate"))
    }
}
