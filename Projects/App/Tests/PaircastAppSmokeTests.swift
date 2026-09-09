import XCTest
@testable import Paircast

final class PaircastAppSmokeTests: XCTestCase {
    func test_bundleIdentifierUsesComChaiszPrefix() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        XCTAssertTrue(
            bundleId.hasPrefix("com.chaisz"),
            "Expected com.chaisz.* bundle id, got \(bundleId)"
        )
    }
}
