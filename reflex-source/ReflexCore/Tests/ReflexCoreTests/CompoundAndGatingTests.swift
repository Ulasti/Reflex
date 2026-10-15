import Testing
@testable import ReflexCore

/// Splitting "open notes and type buy milk" into ordered actions.
@Suite("CompoundRouter")
struct CompoundRouterTests {
    @Test("two real actions split and keep their order")
    func splitsTwoActions() {
        let parts = CompoundRouter.split("open notes and type buy milk")
        #expect(parts.map(\.transcript) == ["open notes", "type buy milk"])
        #expect(parts.allSatisfy { !$0.submit })
    }

    @Test("a single action is not compound", arguments: [
        "open notes", "run and gun", "lock the screen", "take a screenshot",
    ])
    func singleActionIsNotCompound(phrase: String) {
        #expect(CompoundRouter.split(phrase).isEmpty)
        #expect(!CompoundRouter.isCompound(phrase))
    }

    @Test("a typed payload containing \"and\" is not split")
    func typedPayloadStaysWhole() {
        #expect(!CompoundRouter.isCompound("type this and that"))
    }

    @Test("a trailing \"and press enter\" folds into the last part")
    func trailingSubmitFolds() {
        let parts = CompoundRouter.split("open notes and type buy milk and press enter")
        #expect(parts.map(\.transcript) == ["open notes", "type buy milk"])
        #expect(parts.last?.submit == true)
    }
}

/// The gate that stands between a guess and an action. Jev's
/// `ACTION_MIN_CONFIDENCE`: below the floor the dispatcher no-ops.
@Suite("DecisionArbiter")
struct DecisionArbiterTests {
    @Test("confidence floor")
    func confidenceFloor() {
        let arbiter = DecisionArbiter()
        #expect(arbiter.shouldExecute(confidence: 0.5, addressed: 1.0))
        #expect(!arbiter.shouldExecute(confidence: 0.39, addressed: 1.0))
    }

    @Test("addressed floor")
    func addressedFloor() {
        let arbiter = DecisionArbiter()
        #expect(arbiter.shouldExecute(confidence: 1.0, addressed: 0.5))
        #expect(!arbiter.shouldExecute(confidence: 1.0, addressed: 0.4))
    }

    @Test("an unrouted phrase is a no-op, not a wild guess")
    func unroutedIsNoOp() {
        // The rule router declines "50 times 20"; Laya's best guess is far below
        // the floor and must not execute.
        #expect(RuleRouter().classify("50 times 20") == nil)
        let decision = DecisionArbiter().decide(
            layaTarget: "file_operation", layaConfidence: 0.19, transcript: "50 times 20"
        )
        #expect(!DecisionArbiter().shouldExecute(confidence: decision.confidence, addressed: decision.addressed))
    }

    @Test("a strong rule overrides a weak Laya guess")
    func strongRuleWins() {
        let decision = DecisionArbiter().decide(
            layaTarget: "media_control", layaConfidence: 0.5, transcript: "lock the screen"
        )
        #expect(decision.target == "system_control")
        #expect(decision.addressed == 1.0)
    }

    @Test("agreement keeps the higher confidence")
    func agreementKeepsHigherConfidence() {
        let decision = DecisionArbiter().decide(
            layaTarget: "open_app", layaConfidence: 0.3, transcript: "open notes"
        )
        #expect(decision.target == "open_app")
        #expect(decision.confidence == 0.9)
    }
}

@Suite("CommandPlan")
struct CommandPlanTests {
    @Test("make() carries the target, transcript and extracted payload")
    func makeCarriesPayload() {
        let plan = CommandPlan.make(target: "type_text", transcript: "type buy milk")
        #expect(plan.action == "type_text")
        #expect(plan.transcript == "type buy milk")
        #expect(plan.candidates.text == "buy milk")
    }
}
