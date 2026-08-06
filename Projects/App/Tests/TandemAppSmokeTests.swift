import XCTest
@testable import Tandem

final class TandemAppSmokeTests: XCTestCase {
    func test_bundleIdentifierUsesComChaiszPrefix() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        XCTAssertTrue(
            bundleId.hasPrefix("com.chaisz"),
            "Expected com.chaisz.* bundle id, got \(bundleId)"
        )
    }
}
