import XCTest
@testable import Data
import Domain
import zlib

final class LocalUserSigGatewayTests: XCTestCase {
    func test_generatesNonEmptySig() throws {
        let gateway = LocalUserSigGateway()
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1400000000, secretKey: "test-secret"),
            qiniu: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "d")
        )
        let sig = try gateway.generateUserSig(userId: "alice", config: config)
        XCTAssertFalse(sig.isEmpty)
        XCTAssertFalse(sig.contains("+"))
        XCTAssertFalse(sig.contains("/"))
        XCTAssertFalse(sig.contains("="))
    }

    func test_sigIsZlibCompressedJSONWithOfficialFieldNames() throws {
        let gateway = LocalUserSigGateway()
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1_400_000_000, secretKey: "eJx*test-secret-key-for-hmac"),
            qiniu: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "d"),
            userSigExpireSeconds: 86_400
        )
        let sig = try gateway.generateUserSig(userId: "bob", config: config)
        // Reverse base64url → inflate → JSON
        let padded = sig
            .replacingOccurrences(of: "*", with: "+")
            .replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "_", with: "=")
        guard let compressed = Data(base64Encoded: padded) else {
            return XCTFail("not base64")
        }
        let jsonData = try zlibInflate(compressed)
        let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        XCTAssertEqual(obj?["TLS.ver"] as? String, "2.0")
        XCTAssertEqual(obj?["TLS.identifier"] as? String, "bob")
        XCTAssertEqual((obj?["TLS.sdkappid"] as? NSNumber)?.intValue, 1_400_000_000)
        XCTAssertEqual((obj?["TLS.expire"] as? NSNumber)?.intValue, 86_400)
        XCTAssertNotNil((obj?["TLS.time"] as? NSNumber)?.intValue)
        XCTAssertNotNil(obj?["TLS.sig"] as? String)
        XCTAssertNil(obj?["TLS.sdkAppID"]) // must not use camelCase AppID
    }

    private func zlibInflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw NSError(domain: "zlib", code: Int(status))
        }
        defer { inflateEnd(&stream) }

        let input = [UInt8](data)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        input.withUnsafeBufferPointer { inBuf in
            stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress!)
            stream.avail_in = uInt(inBuf.count)
        }

        repeat {
            let produced: Int = buffer.withUnsafeMutableBufferPointer { outBuf in
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                status = inflate(&stream, Z_NO_FLUSH)
                return outBuf.count - Int(stream.avail_out)
            }
            guard status == Z_OK || status == Z_STREAM_END else {
                throw NSError(domain: "zlib", code: Int(status))
            }
            output.append(buffer, count: produced)
        } while status != Z_STREAM_END

        return output
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

final class AWSV4SignerTests: XCTestCase {
    func test_regionFromDottedEndpoint() {
        XCTAssertEqual(AWSV4Signer.region(fromEndpoint: "s3.cn-east-1.qiniucs.com"), "cn-east-1")
        XCTAssertEqual(AWSV4Signer.region(fromEndpoint: "https://s3.cn-south-1.qiniucs.com"), "cn-south-1")
    }

    func test_regionFromHyphenEndpoint() {
        XCTAssertEqual(AWSV4Signer.region(fromEndpoint: "s3-cn-east-1.qiniucs.com"), "cn-east-1")
    }

    func test_signHeaderProducesAuthorization() throws {
        let url = URL(string: "https://s3.cn-east-1.qiniucs.com/movies?list-type=2")!
        let date = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01T00:00:00Z

        let signed = try AWSV4Signer.signHeader(
            method: "GET",
            url: url,
            region: "cn-east-1",
            credentials: .init(accessKey: "AKEXAMPLE", secretKey: "SECRETEXAMPLE"),
            date: date
        )
        XCTAssertEqual(signed.method, "GET")
        XCTAssertTrue(signed.headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKEXAMPLE/") == true)
        XCTAssertEqual(signed.headers["x-amz-content-sha256"], AWSV4Signer.emptyPayloadHash)
        XCTAssertEqual(signed.headers["x-amz-date"], "20200101T000000Z")
    }

    func test_presignContainsSignatureQuery() throws {
        let url = URL(string: "https://s3.cn-east-1.qiniucs.com/movies/films/a.mp4")!
        let signed = try AWSV4Signer.presignGET(
            url: url,
            region: "cn-east-1",
            credentials: .init(accessKey: "AK", secretKey: "SK"),
            expires: 600,
            date: Date(timeIntervalSince1970: 1_577_836_800)
        )
        let items = URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Set(items.map(\.name))
        XCTAssertTrue(names.contains("X-Amz-Algorithm"))
        XCTAssertTrue(names.contains("X-Amz-Signature"))
        XCTAssertTrue(names.contains("X-Amz-Credential"))
    }

    func test_canonicalQuerySortsByEncodedNameNotValue() {
        // Regression: sorter used `lhs.0 < rhs.1` (key vs value) which shuffled SigV4 params.
        let query = AWSV4Signer.canonicalQueryPairs([
            ("X-Amz-Date", "20200101T000000Z"),
            ("X-Amz-Credential", "bN6wfCIZ/20200101/cn-south-1/s3/aws4_request"),
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-SignedHeaders", "host"),
            ("X-Amz-Expires", "21600"),
            ("X-Amz-Signature", "abc"),
        ])
        let names = query.split(separator: "&").map { $0.split(separator: "=").first.map(String.init) ?? "" }
        XCTAssertEqual(names, [
            "X-Amz-Algorithm",
            "X-Amz-Credential",
            "X-Amz-Date",
            "X-Amz-Expires",
            "X-Amz-Signature",
            "X-Amz-SignedHeaders",
        ])
    }

    func test_presignEncodesParenthesesInPath() throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "s3.cn-south-1.qiniucs.com"
        components.percentEncodedPath = "/" + ["870027381", "画江湖之天罡 (2023).mkv"]
            .map { AWSV4Signer.uriEncodePublic($0) }
            .joined(separator: "/")
        let url = components.url!
        let signed = try AWSV4Signer.presignGET(
            url: url,
            region: "cn-south-1",
            credentials: .init(accessKey: "AK", secretKey: "SK"),
            expires: 21600,
            date: Date(timeIntervalSince1970: 1_577_836_800)
        )
        XCTAssertTrue(signed.path.contains("%28") || signed.absoluteString.contains("%28"))
        XCTAssertTrue(signed.absoluteString.contains("%282023%29"))
        XCTAssertTrue(signed.absoluteString.contains("X-Amz-Signature="))
        XCTAssertEqual(
            URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "X-Amz-Expires" })?.value,
            "21600"
        )
    }
}

final class S3ListObjectsV2ParserTests: XCTestCase {
    func test_parsesKeys() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Name>movies</Name>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>films/Inception.2010.mp4</Key></Contents>
          <Contents><Key>films/notes.txt</Key></Contents>
          <Contents><Key>films/Interstellar.2014.mkv</Key></Contents>
        </ListBucketResult>
        """
        let page = try S3ListObjectsV2Parser.parsePage(from: Data(xml.utf8))
        XCTAssertEqual(page.keys, [
            "films/Inception.2010.mp4",
            "films/notes.txt",
            "films/Interstellar.2014.mkv",
        ])
        XCTAssertFalse(page.isTruncated)
        XCTAssertNil(page.nextContinuationToken)
    }

    func test_parsesTruncationAndContinuation() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>token-abc==</NextContinuationToken>
          <Contents><Key>a.mp4</Key></Contents>
        </ListBucketResult>
        """
        let page = try S3ListObjectsV2Parser.parsePage(from: Data(xml.utf8))
        XCTAssertEqual(page.keys, ["a.mp4"])
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.nextContinuationToken, "token-abc==")
    }

    func test_errorXMLThrows() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error>
          <Code>AccessDenied</Code>
          <Message>Access Denied</Message>
        </Error>
        """
        XCTAssertThrowsError(try S3ListObjectsV2Parser.parseObjectKeys(from: Data(xml.utf8))) { error in
            guard let parseError = error as? S3ListObjectsV2Parser.ParseError,
                  case .errorResponse(let code, _) = parseError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(code, "AccessDenied")
        }
    }
}

final class QiniuCatalogFilterTests: XCTestCase {
    func test_videoExtensionFilterStillApplies() {
        let keys = ["a.mp4", "b.mkv", "c.txt", "d.avi", "e.m4v"]
        let filtered = MovieCatalogRules.filterVideoKeys(keys)
        XCTAssertEqual(filtered, ["a.mp4", "b.mkv", "e.m4v"])
    }
}

final class QiniuPlayURLTests: XCTestCase {
    func test_playURLAlwaysPresignsEvenWhenDomainSet() async throws {
        let gateway = QiniuMovieCatalogGateway()
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "im"),
            qiniu: .init(
                accessKey: "AK",
                secretKey: "SK",
                bucket: "870027381",
                endpoint: "s3.cn-south-1.qiniucs.com",
                domain: "cdn.example.com",
                prefix: nil
            )
        )
        let movie = Movie(
            id: "画江湖之天罡 (2023).mkv",
            objectKey: "画江湖之天罡 (2023).mkv",
            title: "画江湖之天罡",
            format: .mkv
        )
        let url = try await gateway.playURL(for: movie, config: config)
        XCTAssertEqual(url.host, "s3.cn-south-1.qiniucs.com")
        XCTAssertTrue(url.path.contains("870027381"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(where: { $0.name == "X-Amz-Signature" }))
        XCTAssertEqual(
            items.first(where: { $0.name == "X-Amz-Expires" })?.value,
            String(QiniuMovieCatalogGateway.defaultPresignExpiresSeconds)
        )
        XCTAssertEqual(QiniuMovieCatalogGateway.defaultPresignExpiresSeconds, 6 * 3600)
        XCTAssertFalse(url.host?.contains("cdn.example.com") == true)
    }
}

final class WatchRoomDTOTests: XCTestCase {
    func test_roundTripPreservesMembersAndStatus() throws {
        let room = WatchRoom(
            id: "r1",
            movieId: "画江湖.mkv",
            hostUserId: "alice",
            memberIds: ["alice", "bob"],
            joinOrder: ["alice", "bob"],
            status: .active,
            lastAppliedSeq: 3,
            hostTransferSeq: 1
        )
        let data = try JSONEncoder().encode(WatchRoomDTO(room))
        let decoded = try JSONDecoder().decode(WatchRoomDTO.self, from: data).toDomain()
        XCTAssertEqual(decoded, room)
        XCTAssertEqual(QiniuRoomGateway.objectKeyPrefix, "_tandem/rooms/")
    }
}

final class TencentIMGroupIDTests: XCTestCase {
    func test_groupIDUsesTandemPrefix() {
        XCTAssertEqual(TencentIMClient.groupID(forRoomId: "AbC"), "tandem_abc")
        XCTAssertEqual(TencentIMClient.groupID(forRoomId: "tandem_xyz"), "tandem_xyz")
        XCTAssertEqual(TencentIMClient.roomId(fromGroupID: "tandem_abc"), "abc")
    }

    func test_playbackSignalJSONRoundTrip() throws {
        let signal = PlaybackSyncSignal(
            action: .pause,
            positionMs: 1_200,
            movieId: "film.mkv",
            hostUserId: "alice",
            senderId: "alice",
            seq: 9
        )
        let data = try JSONEncoder().encode(signal)
        let decoded = try JSONDecoder().decode(PlaybackSyncSignal.self, from: data)
        XCTAssertEqual(decoded, signal)
        XCTAssertEqual(TencentIMClient.systemPrefix, "[sys]")
        XCTAssertEqual(TencentIMClient.groupTypeMeeting, "Meeting")
    }
}

final class MetadataGatewayHelpersTests: XCTestCase {
    func test_validHTTPURLRejectsNA() {
        XCTAssertNil(CascadingMetadataGateway.validHTTPURL("N/A"))
        XCTAssertNil(CascadingMetadataGateway.validHTTPURL(""))
    }

    func test_validHTTPURLUpgradesHTTP() {
        let url = CascadingMetadataGateway.validHTTPURL("http://img.example.com/p.jpg")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "img.example.com")
    }

    func test_parseDoubanIntro() {
        let html = #"<div>简介：大周年间，时局动荡，奸臣当道。直属帝王的秘密暗杀组织不良人一夜之间突然群龙无首。</div>"#
        let intro = CascadingMetadataGateway.parseDoubanIntro(from: html)
        XCTAssertNotNil(intro)
        XCTAssertTrue(intro?.contains("大周年间") == true)
    }

    func test_imdbSuggestionURLUsesFirstLetterBucket() {
        let url = CascadingMetadataGateway.imdbSuggestionURL(for: "Inception")
        XCTAssertEqual(url?.absoluteString, "https://v3.sg.media-imdb.com/suggestion/i/inception.json")
    }

    func test_imdbSuggestionURLUsesXBucketForCJK() {
        let url = CascadingMetadataGateway.imdbSuggestionURL(for: "画江湖之天罡")
        XCTAssertTrue(url?.path.hasPrefix("/suggestion/x/") == true)
        XCTAssertTrue(url?.absoluteString.contains("%E7%94%BB") == true)
    }

    func test_pickIMDbPrefersYearMatchedMovie() throws {
        let json = """
        {"d":[
          {"id":"tt1","l":"Wrong","qid":"movie","y":2010,"i":{"imageUrl":"https://m.media-amazon.com/a.jpg"}},
          {"id":"tt2","l":"Right","qid":"movie","y":2023,"i":{"imageUrl":"https://m.media-amazon.com/b.jpg"}},
          {"id":"tt3","l":"Series","qid":"tvSeries","y":2023,"i":{"imageUrl":"https://m.media-amazon.com/c.jpg"}}
        ]}
        """
        let dto = try JSONDecoder().decode(IMDbSuggestResponse.self, from: Data(json.utf8))
        let pick = CascadingMetadataGateway.pickIMDbSuggestion(dto.d ?? [], preferringYear: "2023")
        XCTAssertEqual(pick?.id, "tt2")
        XCTAssertEqual(pick?.l, "Right")
    }

    func test_pickIMDbReturnsNilWhenYearMisses() throws {
        let json = """
        {"d":[{"id":"tt1","l":"Wrong","qid":"movie","y":2010,"i":{"imageUrl":"https://m.media-amazon.com/a.jpg"}}]}
        """
        let dto = try JSONDecoder().decode(IMDbSuggestResponse.self, from: Data(json.utf8))
        XCTAssertNil(CascadingMetadataGateway.pickIMDbSuggestion(dto.d ?? [], preferringYear: "2023"))
    }
}

final class QiniuDownloadURLTests: XCTestCase {
    func test_signedURLContainsDeadlineAndToken() throws {
        let base = URL(string: "https://cdn.example.com/_tandem/avatars/alice/a.jpg")!
        let signed = try QiniuDownloadURL.signedURL(
            resourceURL: base,
            accessKey: "AKID",
            secretKey: "secret",
            expiresInSeconds: QiniuDownloadURL.oneYearSeconds,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let items = URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let e = items.first(where: { $0.name == "e" })?.value
        let token = items.first(where: { $0.name == "token" })?.value
        XCTAssertEqual(e, String(1_700_000_000 + QiniuDownloadURL.oneYearSeconds))
        XCTAssertEqual(token?.hasPrefix("AKID:"), true)
        XCTAssertFalse(token?.contains("+") == true)
        XCTAssertFalse(token?.contains("/") == true)
    }

    func test_roundTripStableForSameInputs() throws {
        let base = URL(string: "https://cdn.example.com/key.jpg")!
        let a = try QiniuDownloadURL.signedURL(
            resourceURL: base,
            accessKey: "ak",
            secretKey: "sk",
            expiresInSeconds: 3600,
            now: Date(timeIntervalSince1970: 100)
        )
        let b = try QiniuDownloadURL.signedURL(
            resourceURL: base,
            accessKey: "ak",
            secretKey: "sk",
            expiresInSeconds: 3600,
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(a, b)
    }
}

final class QiniuAvatarStorageTests: XCTestCase {
    func test_signedURLUsesEndpointPresign() {
        let storage = QiniuAvatarStorage()
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "im"),
            qiniu: .init(
                accessKey: "AK",
                secretKey: "SK",
                bucket: "b",
                endpoint: "s3.cn-south-1.qiniucs.com"
            )
        )
        XCTAssertThrowsError(try storage.signedURL(objectKey: "films/a.jpg", config: config))
        let url = try? storage.signedURL(
            objectKey: "_tandem/avatars/alice/x.jpg",
            config: config
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("X-Amz-Signature=") == true)
        XCTAssertEqual(url?.host, "s3.cn-south-1.qiniucs.com")
        XCTAssertEqual(QiniuAvatarStorage.sigV4MaxExpiresSeconds, 7 * 24 * 3600)
    }
}
