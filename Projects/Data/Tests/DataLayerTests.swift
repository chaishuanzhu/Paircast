import XCTest
@testable import Data
import Domain

final class LocalUserSigGatewayTests: XCTestCase {
    func test_generatesNonEmptySig() throws {
        let gateway = LocalUserSigGateway()
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1400000000, secretKey: "test-secret"),
            qiniu: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "d")
        )
        let sig = try gateway.generateUserSig(userId: "alice", config: config)
        XCTAssertFalse(sig.isEmpty)
    }
}

final class InMemoryAuthGatewayTests: XCTestCase {
    func test_unknownUserRejectedWhenWhitelistSet() async {
        let gateway = InMemoryAuthGateway(registeredUserIds: ["alice"])
        do {
            try await gateway.login(userId: "bob", userSig: "sig")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AppError, .accountUnavailable)
        }
    }
}

final class QiniuCatalogFilterIntegrationTests: XCTestCase {
    func test_demoCatalogOnlyVideoFormats() async throws {
        let gateway = QiniuMovieCatalogGateway(demoFallbackEnabled: true)
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "s"),
            qiniu: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "invalid.example")
        )
        let movies = try await gateway.listMovies(config: config)
        XCTAssertFalse(movies.isEmpty)
        XCTAssertTrue(movies.allSatisfy { MovieCatalogRules.isVideoObjectKey($0.objectKey) })
    }
}
