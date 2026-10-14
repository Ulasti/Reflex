import Testing
@testable import ReflexCore

/// Canary: the test target links `ReflexCore` and reaches its internals. If this
/// suite stops running, the rest of the net is not running either.
@Suite("Test harness")
struct HarnessCanaryTests {
    @Test("ReflexCore is importable and reachable")
    func reachesInternals() {
        #expect(RuleRouter().classify("open calculator")?.target == "open_app")
    }
}
