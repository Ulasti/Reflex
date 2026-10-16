import XCTest
@testable import ReflexCore

final class MisfireRegressionTests: XCTestCase {
    func testFiftyTimesTwentyProducesNoOp() {
        let router = RuleRouter()
        let decision = router.classify("50 times 20")
        // "50 times 20" has no strong rule match; ensure it does not resolve to file_operation
        if let decision = decision {
            XCTAssertNotEqual(decision.target, "file_operation")
        } else {
            XCTAssertNil(decision) // acceptable: defer to Laya/arbiter
        }
    }
}
