import XCTest
@testable import Data
import Domain
import zlib

final class LocalUserSigGatewayTests: XCTestCase {
    func test_generatesNonEmptySig() throws {
        let gateway = LocalUserSigGateway()
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1400000000, secretKey: "test-secret"),
            storage: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "d")
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
            storage: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "d"),
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

    func test_inferredSigningRegionPerProvider() {
        XCTAssertEqual(
            ObjectStorageConfig.inferredRegion(provider: .qiniu, endpoint: "s3.cn-south-1.qiniucs.com"),
            "cn-south-1"
        )
        XCTAssertEqual(
            ObjectStorageConfig.inferredRegion(provider: .aliyunOSS, endpoint: "oss-cn-beijing.aliyuncs.com"),
            "cn-beijing"
        )
        XCTAssertEqual(
            ObjectStorageConfig.inferredRegion(provider: .tencentCOS, endpoint: "cos.ap-shanghai.myqcloud.com"),
            "ap-shanghai"
        )
        XCTAssertEqual(
            ObjectStorageConfig.inferredRegion(provider: .minio, endpoint: "127.0.0.1:9000"),
            "us-east-1"
        )
    }

    func test_s3CompatibleURLPathStyleWithPort() throws {
        let storage = ObjectStorageConfig(
            provider: .minio,
            accessKey: "a",
            secretKey: "b",
            bucket: "movies",
            endpoint: "192.168.1.10:9000",
            useSSL: false,
            forcePathStyle: true
        )
        let url = try S3CompatibleURL.objectURL(objectKey: "films/a.mp4", storage: storage)
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "192.168.1.10")
        XCTAssertEqual(url.port, 9000)
        XCTAssertEqual(url.path, "/movies/films/a.mp4")
    }

    func test_s3CompatibleURLVirtualHosted() throws {
        let storage = ObjectStorageConfig(
            provider: .aliyunOSS,
            accessKey: "a",
            secretKey: "b",
            bucket: "movies",
            endpoint: "oss-cn-hangzhou.aliyuncs.com",
            useSSL: true,
            forcePathStyle: false
        )
        let url = try S3CompatibleURL.objectURL(objectKey: "a.mp4", storage: storage)
        XCTAssertEqual(url.host, "movies.oss-cn-hangzhou.aliyuncs.com")
        XCTAssertEqual(url.path, "/a.mp4")
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

final class OSSCatalogFilterTests: XCTestCase {
    func test_videoExtensionFilterStillApplies() {
        let keys = ["a.mp4", "b.mkv", "c.txt", "d.avi", "e.m4v"]
        let filtered = MovieCatalogRules.filterVideoKeys(keys)
        XCTAssertEqual(filtered, ["a.mp4", "b.mkv", "e.m4v"])
    }
}

final class OSSPlayURLTests: XCTestCase {
    func test_playURLAlwaysPresignsEvenWhenDomainSet() async throws {
        let gateway = OSSMovieCatalogGateway()
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "im"),
            storage: .init(
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
            String(OSSMovieCatalogGateway.defaultPresignExpiresSeconds)
        )
        XCTAssertEqual(OSSMovieCatalogGateway.defaultPresignExpiresSeconds, 6 * 3600)
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
        XCTAssertEqual(OSSRoomGateway.objectKeyPrefix, "_paircast/rooms/")
        XCTAssertEqual(OSSRoomGateway.objectKey(roomId: "AbC-123"), "_paircast/rooms/abc-123.json")
    }
}

final class TencentIMGroupIDTests: XCTestCase {
    func test_groupIDUsesPaircastPrefix() {
        XCTAssertEqual(TencentIMClient.groupID(forRoomId: "AbC"), "paircast_abc")
        XCTAssertEqual(TencentIMClient.groupID(forRoomId: "paircast_xyz"), "paircast_xyz")
        XCTAssertEqual(TencentIMClient.roomId(fromGroupID: "paircast_abc"), "abc")
    }

    func test_playbackSignalJSONRoundTrip() throws {
        let signal = PlaybackSyncSignal(
            action: .subtitleChange,
            positionMs: 1_200,
            movieId: "film.mkv",
            hostUserId: "alice",
            senderId: "alice",
            seq: 9,
            subtitleObjectKey: "films/Inception.2010.srt",
            subtitleLabel: "简体"
        )
        let data = try JSONEncoder().encode(signal)
        let decoded = try JSONDecoder().decode(PlaybackSyncSignal.self, from: data)
        XCTAssertEqual(decoded, signal)
        XCTAssertEqual(TencentIMClient.systemPrefix, "[sys]")
        XCTAssertEqual(TencentIMClient.groupTypeMeeting, "Meeting")
    }

    func test_sharedSubtitleObjectKeyPrefix() {
        XCTAssertEqual(
            SharedSubtitleObjectKey.sidecarKey(movieObjectKey: "films/Inception.2010.mkv", fileExtension: "srt"),
            "films/Inception.2010.srt"
        )
        XCTAssertEqual(
            SharedSubtitleObjectKey.sidecarKey(movieObjectKey: "films/Inception.2010.mkv", fileExtension: "ASS"),
            "films/Inception.2010.ass"
        )
        XCTAssertNil(SharedSubtitleObjectKey.sidecarKey(movieObjectKey: "_paircast/rooms/x.json", fileExtension: "srt"))
        XCTAssertTrue(SharedSubtitleObjectKey.isValid("films/Inception.2010.srt"))
        XCTAssertFalse(SharedSubtitleObjectKey.isValid("_paircast/avatars/u/a.jpg"))
        XCTAssertFalse(SharedSubtitleObjectKey.isValid("films/Inception.2010.mkv"))
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

final class OSSAvatarStorageTests: XCTestCase {
    func test_signedURLUsesEndpointPresign() {
        let storage = OSSAvatarStorage()
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "im"),
            storage: .init(
                accessKey: "AK",
                secretKey: "SK",
                bucket: "b",
                endpoint: "s3.cn-south-1.qiniucs.com"
            )
        )
        XCTAssertThrowsError(try storage.signedURL(objectKey: "films/a.jpg", config: config))
        let url = try? storage.signedURL(
            objectKey: "_paircast/avatars/alice/x.jpg",
            config: config
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("X-Amz-Signature=") == true)
        XCTAssertEqual(url?.host, "s3.cn-south-1.qiniucs.com")
        XCTAssertEqual(OSSAvatarStorage.sigV4MaxExpiresSeconds, 7 * 24 * 3600)
    }
}

final class SubtitleEncodingNormalizerTests: XCTestCase {
    func test_convertsGBKChineseSRTToUTF8() throws {
        let sample = """
        1
        00:00:01,000 --> 00:00:03,000
        你残余的记忆，就是最好的证据。
        """
        let cfEnc = CFStringEncodings.GB_18030_2000.rawValue
        let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc))
        guard ns != kCFStringEncodingInvalidId,
              let raw = (sample as NSString).data(using: ns) else {
            return XCTFail("failed to encode GB18030 sample")
        }
        // Confirm raw is not valid UTF-8 (typical legacy Chinese SRT).
        XCTAssertNil(String(data: raw, encoding: .utf8))

        let utf8 = SubtitleEncodingNormalizer.utf8Data(from: raw)
        let text = String(data: utf8, encoding: .utf8)
        XCTAssertEqual(text, sample)
        XCTAssertTrue(text?.contains("记忆") == true)
    }

    func test_keepsUTF8ChineseSRT() {
        let sample = """
        1
        00:00:01,000 --> 00:00:03,000
        简体中文字幕
        """
        let raw = Data(sample.utf8)
        let out = SubtitleEncodingNormalizer.utf8Data(from: raw)
        XCTAssertEqual(String(data: out, encoding: .utf8), sample)
    }
}

final class MovieNFOCodecTests: XCTestCase {
    func test_roundTripPreservesFields() throws {
        let payload = MovieNFOCodec.Payload(
            title: "盗梦空间",
            year: "2010",
            overview: "你残余的记忆，就是最好的证据。",
            posterFileName: "Inception.2010-poster.jpg",
            fanartFileName: "Inception.2010-fanart.jpg"
        )
        let data = MovieNFOCodec.encode(payload)
        let decoded = try XCTUnwrap(MovieNFOCodec.decode(data))
        XCTAssertEqual(decoded.title, payload.title)
        XCTAssertEqual(decoded.year, payload.year)
        XCTAssertEqual(decoded.overview, payload.overview)
        XCTAssertEqual(decoded.posterFileName, payload.posterFileName)
        XCTAssertEqual(decoded.fanartFileName, payload.fanartFileName)
    }

    func test_metadataObjectKeys() {
        let movie = "films/Inception.2010.mkv"
        XCTAssertEqual(MovieMetadataObjectKey.nfoKey(for: movie), "films/Inception.2010.nfo")
        XCTAssertEqual(MovieMetadataObjectKey.posterKey(for: movie), "films/Inception.2010-poster.jpg")
        XCTAssertEqual(MovieMetadataObjectKey.fanartKey(for: movie), "films/Inception.2010-fanart.jpg")
        XCTAssertNil(MovieMetadataObjectKey.nfoKey(for: "_paircast/rooms/x.json"))
    }
}

final class OSSSidecarMatchingTests: XCTestCase {
    func test_matchesSameBasenameAndLanguageSuffixes() {
        let movie = "films/Inception.2010.mkv"
        let keys = [
            movie,
            "films/Inception.2010.srt",
            "films/Inception.2010.zh.srt",
            "films/Inception.2010.chi.ass",
            "films/Inception.2010.en.vtt",
            "films/Inception.2010_extra.srt",
            "films/Other.Movie.srt",
            "films/Inception.2010.nfo",
        ]
        let matched = OpenSubtitlesGateway.matchingSidecarKeys(from: keys, movieObjectKey: movie)
        XCTAssertEqual(
            Set(matched),
            Set([
                "films/Inception.2010.srt",
                "films/Inception.2010.zh.srt",
                "films/Inception.2010.chi.ass",
                "films/Inception.2010.en.vtt",
                "films/Inception.2010_extra.srt",
            ])
        )
    }

    func test_parsesObjectKeyFromTrackId() {
        let track = SubtitleTrack(
            id: "oss:films/a.zh.srt",
            label: "ZH (sidecar)",
            source: .oss
        )
        XCTAssertEqual(OpenSubtitlesGateway.ossObjectKey(from: track), "films/a.zh.srt")
    }
}

