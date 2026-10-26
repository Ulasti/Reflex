import XCTest
@testable import ReflexCore

final class PayloadExtractorTests: XCTestCase {
    func testExtractsBasicSearch() {
        let result = PayloadExtractor.extract(from: "search for swift", target: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.query, "swift")
    }
}
