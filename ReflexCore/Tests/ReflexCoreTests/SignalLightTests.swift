import Testing
@testable import ReflexCore

/// The menu bar light's priority order. Each assertion pins one rule of the
/// contract in SignalLight's doc comment; if a reordering breaks feedback the
/// user sees, it breaks here first.
@Suite("Signal light states")
struct SignalLightTests {
    private func resolve(
        failure: String? = nil,
        loading: Bool = false,
        flashActive: Bool = false,
        listening: Bool = false,
        hearing: Bool = false
    ) -> SignalLight {
        SignalLight.resolve(
            failure: failure,
            loading: loading,
            flashActive: flashActive,
            listening: listening,
            hearing: hearing
        )
    }

    @Test("Failure outranks everything, including a load in progress")
    func failureWins() {
        #expect(resolve(failure: "mic denied", loading: true, flashActive: true, listening: true) == .error)
        #expect(resolve(failure: "") == .off)
    }

    @Test("Loading shows the waiting light even while already listening")
    func loadingBeatsFlashAndListening() {
        #expect(resolve(loading: true, flashActive: true, listening: true, hearing: true) == .waiting)
    }

    @Test("An executed flash outranks the resting listening state")
    func flashBeatsListening() {
        #expect(resolve(flashActive: true, listening: true, hearing: true) == .executed)
        // The "stop listening" command flashes green, then settles to off.
        #expect(resolve(flashActive: true, listening: false) == .executed)
    }

    @Test("Mic live splits into armed (nothing heard) and hearing")
    func listeningSplitsOnVoice() {
        #expect(resolve(listening: true, hearing: true) == .hearing)
        #expect(resolve(listening: true, hearing: false) == .armed)
    }

    @Test("Mic not live is off, no matter what else is quiet")
    func notListeningIsOff() {
        #expect(resolve() == .off)
        #expect(resolve(listening: false, hearing: true) == .off)
    }

    /// After a failed dispatch — or a gated no-op ("not sure what you meant")
    /// — the light must return to Armed: no green flash, and no red, which is
    /// reserved for mic, model and capture failures.
    @Test("A failed or no-op dispatch returns to armed, not green and not red")
    func failedDispatchReturnsToArmed() {
        #expect(resolve(listening: true) == .armed)
        #expect(resolve(listening: true, hearing: false) != .executed)
        #expect(resolve(listening: true) != .error)
        // Only a real failure lights red.
        #expect(resolve(failure: "Microphone access denied", listening: true) == .error)
    }
}
