import XCTest
@testable import ReflexCore

final class RuleRouterTests: XCTestCase {
    func testClassifyOpenCalculator() {
        let router = RuleRouter()
        let decision = router.classify("open calculator")
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.target, "open_app")
        XCTAssertGreaterThanOrEqual(decision?.confidence ?? 0, 0.9)
    }

    func testClassifySearchQuery() {
        let router = RuleRouter()
        let decision = router.classify("search for cats")
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.target, "web_search")
    }
}
