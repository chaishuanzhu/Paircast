import XCTest
@testable import Domain

final class MovieCatalogRulesTests: XCTestCase {
    func test_filtersOnlySupportedVideoExtensions() {
        let keys = ["a.mp4", "b.mkv", "c.avi", "d.srt", "folder/e.MP4", "f.m4v"]
        XCTAssertEqual(
            MovieCatalogRules.filterVideoKeys(keys),
            ["a.mp4", "b.mkv", "folder/e.MP4", "f.m4v"]
        )
    }

    func test_parseFilenameWithYear() {
        let parsed = MovieCatalogRules.parseFilenameMetadata(from: "films/Inception.2010.1080p.mkv")
        XCTAssertEqual(parsed.title, "Inception")
        XCTAssertEqual(parsed.year, "2010")
    }

    func test_parseFilenameWithParenthesizedYear() {
        let parsed = MovieCatalogRules.parseFilenameMetadata(from: "画江湖之天罡 (2023).mkv")
        XCTAssertEqual(parsed.title, "画江湖之天罡")
        XCTAssertEqual(parsed.year, "2023")
    }

    func test_parseFilenameWithFullwidthParentheses() {
        let parsed = MovieCatalogRules.parseFilenameMetadata(from: "流浪地球（2019）.mp4")
        XCTAssertEqual(parsed.title, "流浪地球")
        XCTAssertEqual(parsed.year, "2019")
    }

    func test_parseFilenameWithoutYear() {
        let parsed = MovieCatalogRules.parseFilenameMetadata(from: "my-movie.mp4")
        XCTAssertEqual(parsed.title, "my-movie")
        XCTAssertNil(parsed.year)
    }
}

final class ConfigQRCodecTests: XCTestCase {
    func test_roundTrip() throws {
        let config = AppCloudConfig.fixture()
        let encoded = try ConfigQRCodec.encode(config)
        let decoded = try ConfigQRCodec.decode(encoded)
        XCTAssertEqual(decoded.im.sdkAppId, config.im.sdkAppId)
        XCTAssertEqual(decoded.storage.bucket, config.storage.bucket)
    }

    func test_invalidTypeDoesNotDecode() {
        let raw = #"{"v":1,"type":"other","im":{"sdkAppId":1,"secretKey":"x"},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"c","endpoint":"d","useSSL":true,"forcePathStyle":true}}"#
        XCTAssertThrowsError(try ConfigQRCodec.decode(raw)) { error in
            XCTAssertEqual(error as? AppError, .invalidConfigQR)
        }
    }

    func test_roundTripPreservesProviderAndFlags() throws {
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "im"),
            storage: .init(
                provider: .minio,
                accessKey: "a",
                secretKey: "b",
                bucket: "bucket",
                endpoint: "minio.local:9000",
                region: "us-east-1",
                useSSL: false,
                forcePathStyle: true
            )
        )
        let decoded = try ConfigQRCodec.decode(try ConfigQRCodec.encode(config))
        XCTAssertEqual(decoded.storage.provider, .minio)
        XCTAssertEqual(decoded.storage.endpoint, "minio.local:9000")
        XCTAssertEqual(decoded.storage.useSSL, false)
        XCTAssertEqual(decoded.storage.forcePathStyle, true)
        XCTAssertEqual(decoded.configVersion, 2)
    }

    func test_tooLargeRejected() {
        let hugeSecret = String(repeating: "x", count: 3_000)
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: hugeSecret),
            storage: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "d")
        )
        XCTAssertThrowsError(try ConfigQRCodec.encode(config)) { error in
            XCTAssertEqual(error as? AppError, .configQRTooLarge)
        }
    }
}

final class ConfigShareLinkTests: XCTestCase {
    func test_shareURLRoundTrip() throws {
        let config = AppCloudConfig.fixture()
        let url = try ConfigShareLink.shareURL(for: config)
        XCTAssertEqual(url.scheme, "tandem")
        XCTAssertEqual(url.host, "config")
        XCTAssertNotNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "args" })?.value)
        let decoded = try ConfigShareLink.decode(url.absoluteString)
        XCTAssertEqual(decoded.im.sdkAppId, config.im.sdkAppId)
        XCTAssertEqual(decoded.storage.bucket, config.storage.bucket)
        XCTAssertEqual(decoded.im.secretKey, config.im.secretKey)
    }

    func test_argsAreNotPlainJSON() throws {
        let url = try ConfigShareLink.shareURL(for: .fixture())
        let args = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "args" })?
            .value
        XCTAssertFalse(args?.contains("secretKey") == true)
        XCTAssertFalse(args?.hasPrefix("{") == true)
    }

    func test_pasteEmbeddedURL() throws {
        let url = try ConfigShareLink.shareURL(for: .fixture())
        let pasted = "给你配置：\(url.absoluteString) 打开即可"
        let decoded = try ConfigShareLink.decode(pasted)
        XCTAssertEqual(decoded.storage.bucket, AppCloudConfig.fixture().storage.bucket)
    }

    func test_legacyJSONStillDecodes() throws {
        let json = try ConfigQRCodec.encode(.fixture())
        let decoded = try ConfigShareLink.decode(json)
        XCTAssertEqual(decoded.im.sdkAppId, AppCloudConfig.fixture().im.sdkAppId)
    }

    func test_tamperedArgsFail() throws {
        var url = try ConfigShareLink.shareURL(for: .fixture())
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "args", value: "AAAA")]
        url = components.url!
        XCTAssertThrowsError(try ConfigShareLink.decode(url.absoluteString)) { error in
            XCTAssertEqual(error as? AppError, .invalidConfigQR)
        }
    }
}

final class LoginRulesTests: XCTestCase {
    func test_emptyPasswordFails() {
        XCTAssertThrowsError(try LoginRules.validateCredentials(userId: "u", password: ""))
    }

    func test_nonEmptyPassesWeakCheck() throws {
        try LoginRules.validateCredentials(userId: "u", password: "anything")
    }
}

final class ProfileRulesTests: XCTestCase {
    func test_trimsAndValidates() throws {
        XCTAssertEqual(try ProfileRules.validatedNickname("  Alice  "), "Alice")
    }

    func test_rejectsBlank() {
        XCTAssertThrowsError(try ProfileRules.validatedNickname("   "))
    }

    func test_rejectsTooLong() {
        XCTAssertThrowsError(try ProfileRules.validatedNickname(String(repeating: "a", count: 17)))
    }

    func test_rejectsOversizedAvatar() {
        let huge = Data(repeating: 1, count: ProfileRules.avatarMaxBytes + 1)
        XCTAssertThrowsError(try ProfileRules.validatedAvatarData(huge))
    }
}

final class ConfigValidationTests: XCTestCase {
    func test_rejectsCustomDomainAsEndpoint() {
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "s"),
            storage: .init(
                accessKey: "a",
                secretKey: "b",
                bucket: "c",
                endpoint: "https://qiniu.chaisz.com",
                domain: nil
            )
        )
        XCTAssertThrowsError(try ConfigValidation.validate(config)) { error in
            guard case AppError.validation(let message) = error else {
                return XCTFail("expected validation, got \(error)")
            }
            XCTAssertTrue(message.contains("Endpoint"))
        }
    }

    func test_normalizesSchemeAndRejectsS3AsDomain() throws {
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "s"),
            storage: .init(
                accessKey: "a",
                secretKey: "b",
                bucket: "c",
                endpoint: "https://s3.cn-south-1.qiniucs.com/",
                domain: "https://qiniu.chaisz.com/"
            )
        )
        let normalized = try ConfigValidation.normalized(config)
        XCTAssertEqual(normalized.storage.endpoint, "s3.cn-south-1.qiniucs.com")
        XCTAssertEqual(normalized.storage.domain, "qiniu.chaisz.com")

        XCTAssertThrowsError(
            try ConfigValidation.validatedDomain("s3.cn-south-1.qiniucs.com", provider: .qiniu)
        )
    }

    func test_acceptsAliyunOSSEndpoint() throws {
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "s"),
            storage: .init(
                provider: .aliyunOSS,
                accessKey: "a",
                secretKey: "b",
                bucket: "c",
                endpoint: "https://oss-cn-hangzhou.aliyuncs.com/"
            )
        )
        let normalized = try ConfigValidation.normalized(config)
        XCTAssertEqual(normalized.storage.endpoint, "oss-cn-hangzhou.aliyuncs.com")
        XCTAssertEqual(normalized.storage.signingRegion, "cn-hangzhou")
    }

    func test_acceptsTencentCOSAndMinio() throws {
        let cos = try ConfigValidation.normalizedStorage(
            .init(
                provider: .tencentCOS,
                accessKey: "a",
                secretKey: "b",
                bucket: "c",
                endpoint: "cos.ap-guangzhou.myqcloud.com"
            )
        )
        XCTAssertEqual(cos.signingRegion, "ap-guangzhou")

        let minio = try ConfigValidation.normalizedStorage(
            .init(
                provider: .minio,
                accessKey: "a",
                secretKey: "b",
                bucket: "c",
                endpoint: "192.168.1.10:9000",
                useSSL: false,
                forcePathStyle: true
            )
        )
        XCTAssertEqual(minio.endpoint, "192.168.1.10:9000")
        XCTAssertEqual(minio.signingRegion, "us-east-1")
        XCTAssertFalse(minio.useSSL)
    }

    func test_rejectsV1QRPayload() {
        let raw = #"{"v":1,"type":"tandem-config","im":{"sdkAppId":1,"secretKey":"x"},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"c","endpoint":"s3.cn-south-1.qiniucs.com","useSSL":true,"forcePathStyle":true}}"#
        XCTAssertThrowsError(try ConfigQRCodec.decode(raw)) { error in
            XCTAssertEqual(error as? AppError, .invalidConfigQR)
        }
    }
}

final class AvatarObjectKeyTests: XCTestCase {
    func test_parseRawAndLegacyHTTPS() {
        let key = "_tandem/avatars/alice/uuid.jpg"
        XCTAssertEqual(AvatarObjectKey.parse(fromFaceURL: key), key)
        XCTAssertEqual(
            AvatarObjectKey.parse(
                fromFaceURL: "https://s3.cn-south-1.qiniucs.com/b/_tandem/avatars/alice/uuid.jpg?e=1"
            ),
            key
        )
        XCTAssertEqual(
            AvatarObjectKey.parse(fromFaceURL: "tandem://avatar/_tandem/avatars/alice/uuid.jpg"),
            key
        )
    }
}

final class SubtitleStateTests: XCTestCase {
    func test_clampsOffset() {
        var state = SubtitleState(movieId: "m")
        state.applyOffsetDelta(40_000)
        XCTAssertEqual(state.offsetMs, 30_000)
        state.applyOffsetDelta(-100_000)
        XCTAssertEqual(state.offsetMs, -30_000)
    }

    func test_resetForMovieChange() {
        let state = SubtitleState.resetForMovieChange(movieId: "new")
        XCTAssertEqual(state.movieId, "new")
        XCTAssertEqual(state.source, .off)
        XCTAssertEqual(state.offsetMs, 0)
    }
}

final class PlaybackSyncRulesTests: XCTestCase {
    func test_staleSeqIgnored() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(movieId: "m1", lastSeq: 5)
        let signal = PlaybackSyncSignal(action: .pause, positionMs: 100, senderId: room.hostUserId, seq: 5)
        XCTAssertEqual(
            PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current),
            .ignored(.staleSeq)
        )
    }

    func test_nonHostIgnored() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(movieId: "m1", lastSeq: 1)
        let signal = PlaybackSyncSignal(action: .play, positionMs: 0, senderId: "intruder", seq: 2)
        XCTAssertEqual(
            PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current),
            .ignored(.nonHost)
        )
    }

    func test_hostPlayApplied() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(movieId: "m1", lastSeq: 1)
        let signal = PlaybackSyncSignal(action: .play, positionMs: 1500, senderId: room.hostUserId, seq: 2)
        let result = PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current)
        guard case .applied(let state, let seek) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertTrue(seek)
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.positionMs, 1500)
        XCTAssertEqual(state.lastSeq, 2)
    }

    func test_heartbeatWithinThresholdDoesNotSeekAgainstLiveClock() {
        let room = WatchRoom.fixture()
        // Bookkeeping clock is stale (last applied), live player has advanced with the film.
        let current = PlaybackState(positionMs: 1000, isPaused: false, movieId: "m1", lastSeq: 1)
        let signal = PlaybackSyncSignal(action: .heartbeat, positionMs: 6_000, senderId: room.hostUserId, seq: 2)
        let result = PlaybackSyncRules.shouldAccept(
            signal: signal,
            room: room,
            current: current,
            localPositionMs: 5_500
        )
        guard case .applied(let state, let seek) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertFalse(seek)
        XCTAssertEqual(state.positionMs, 6_000)
    }

    func test_heartbeatBeyondThresholdSeeksAgainstLiveClock() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(positionMs: 1000, isPaused: false, movieId: "m1", lastSeq: 1)
        let signal = PlaybackSyncSignal(action: .heartbeat, positionMs: 3000, senderId: room.hostUserId, seq: 2)
        let result = PlaybackSyncRules.shouldAccept(
            signal: signal,
            room: room,
            current: current,
            localPositionMs: 1000
        )
        guard case .applied(let state, let seek) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertTrue(seek)
        XCTAssertEqual(state.positionMs, 3000)
    }

    func test_heartbeatWithoutLocalClockUsesBookkeepingFallback() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(positionMs: 1000, isPaused: false, movieId: "m1", lastSeq: 1)
        let signal = PlaybackSyncSignal(action: .heartbeat, positionMs: 1500, senderId: room.hostUserId, seq: 2)
        let result = PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current)
        guard case .applied(_, let seek) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertFalse(seek)
    }

    func test_movieChangeResetsPosition() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(positionMs: 9999, isPaused: false, movieId: "m1", lastSeq: 1)
        let signal = PlaybackSyncSignal(
            action: .movieChange,
            positionMs: 0,
            movieId: "m2",
            senderId: room.hostUserId,
            seq: 2
        )
        let result = PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current)
        guard case .applied(let state, let seek) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertTrue(seek)
        XCTAssertEqual(state.movieId, "m2")
        XCTAssertEqual(state.positionMs, 0)
        XCTAssertTrue(state.isPaused)
    }

    func test_subtitleChangeAdvancesSeqWithoutSeek() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(positionMs: 4_200, isPaused: false, movieId: "m1", lastSeq: 3)
        let signal = PlaybackSyncSignal(
            action: .subtitleChange,
            positionMs: 4_200,
            movieId: "m1",
            senderId: room.hostUserId,
            seq: 4,
            subtitleObjectKey: "_tandem/subtitles/r1/abc.srt",
            subtitleLabel: "简体中文"
        )
        let result = PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current)
        guard case .applied(let state, let seek) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertFalse(seek)
        XCTAssertEqual(state.positionMs, 4_200)
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.lastSeq, 4)
    }
}

final class HostTransferRulesTests: XCTestCase {
    func test_hostLeaveTransfersToNextJoinOrder() {
        var room = WatchRoom.fixture(host: "a")
        room.memberIds = ["a", "b", "c"]
        room.joinOrder = ["a", "b", "c"]
        let outcome = HostTransferRules.resolveLeave(room: room, leavingUserId: "a", transferSeq: 10)
        guard case .transfer(let newHost, let updated) = outcome else {
            return XCTFail("expected transfer")
        }
        XCTAssertEqual(newHost, "b")
        XCTAssertEqual(updated.hostUserId, "b")
        XCTAssertEqual(updated.hostTransferSeq, 10)
        XCTAssertFalse(updated.memberIds.contains("a"))
    }

    func test_lastMemberEndsRoom() {
        let room = WatchRoom.fixture(host: "solo")
        let outcome = HostTransferRules.resolveLeave(room: room, leavingUserId: "solo", transferSeq: 1)
        guard case .endRoom(let updated) = outcome else {
            return XCTFail("expected end")
        }
        XCTAssertEqual(updated.status, .ended)
    }

    func test_memberLeaveKeepsHost() {
        var room = WatchRoom.fixture(host: "a")
        room.memberIds = ["a", "b"]
        room.joinOrder = ["a", "b"]
        let outcome = HostTransferRules.resolveLeave(room: room, leavingUserId: "b", transferSeq: 1)
        guard case .memberLeft(let updated) = outcome else {
            return XCTFail("expected memberLeft")
        }
        XCTAssertEqual(updated.hostUserId, "a")
        XCTAssertEqual(updated.memberIds, ["a"])
    }
}

final class ChatSafetyStoreTests: XCTestCase {
    func test_blockHidesOtherUsersMessages() {
        let defaults = UserDefaults(suiteName: "tandem.tests.chat-safety")!
        defaults.removePersistentDomain(forName: "tandem.tests.chat-safety")
        let store = ChatSafetyStore(defaults: defaults)
        store.block("bob", ownerId: "alice")
        XCTAssertTrue(store.isBlocked("bob", ownerId: "alice"))
        let visible = store.visibleMessages(
            [
                ChatMessage(id: "1", roomId: "r", senderId: "bob", senderNickname: "Bob", text: "hi"),
                ChatMessage(id: "2", roomId: "r", senderId: "alice", senderNickname: "Alice", text: "hey"),
                ChatMessage(id: "3", roomId: "r", senderNickname: "系统", text: "joined", kind: .system),
            ],
            ownerId: "alice"
        )
        XCTAssertEqual(visible.map(\.id), ["2", "3"])
    }
}

private extension AppCloudConfig {
    static func fixture() -> AppCloudConfig {
        AppCloudConfig(
            im: .init(sdkAppId: 123456789, secretKey: "im-secret"),
            storage: .init(
                accessKey: "ak",
                secretKey: "sk",
                bucket: "movies",
                endpoint: "s3-cn-east-1.qiniucs.com"
            ),
            omdbApiKey: "omdb"
        )
    }
}

private extension WatchRoom {
    static func fixture(host: String = "host1") -> WatchRoom {
        WatchRoom(id: "room1", movieId: "m1", hostUserId: host)
    }
}
