import Testing
import Foundation
@testable import ReflexCore

@Suite("Calculator command router")
struct CalculatorCommandRouterTests {
    let router = CalculatorCommandRouter()

    @Test("clear entry phrases")
    func clearEntry() {
        #expect(router.classify("clear this entry") == .clearEntry)
        #expect(router.classify("clear entry") == .clearEntry)
        #expect(router.classify("backspace") == .clearEntry)
    }

    @Test("clear all phrases")
    func clearAll() {
        #expect(router.classify("clear everything") == .clearAll)
        #expect(router.classify("clear all") == .clearAll)
        #expect(router.classify("reset") == .clearAll)
        #expect(router.classify("start over") == .clearAll)
    }

    @Test("ambiguous bare clear returns nil")
    func ambiguousClear() {
        #expect(router.classify("clear") == nil)
        #expect(router.classify("clear it") == nil)
    }

    @Test("evaluate")
    func evaluate() {
        #expect(router.classify("equals") == .evaluate)
        #expect(router.classify("calculate") == .evaluate)
    }

    @Test("read result")
    func readResult() {
        #expect(router.classify("what is the result") == .readResult)
        #expect(router.classify("what's the answer") == .readResult)
    }

    @Test("undo")
    func undo() {
        #expect(router.classify("undo that") == .undo)
    }

    @Test("unsupported returns nil")
    func unsupported() {
        #expect(router.classify("launch the rocket") == nil)
    }
}
