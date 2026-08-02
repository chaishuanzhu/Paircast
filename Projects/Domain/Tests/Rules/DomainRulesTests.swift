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
        XCTAssertEqual(decoded.qiniu.bucket, config.qiniu.bucket)
    }

    func test_invalidTypeDoesNotDecode() {
        let raw = #"{"v":1,"type":"other","im":{"sdkAppId":1,"secretKey":"x"},"qiniu":{"accessKey":"a","secretKey":"b","bucket":"c","endpoint":"d"}}"#
        XCTAssertThrowsError(try ConfigQRCodec.decode(raw)) { error in
            XCTAssertEqual(error as? AppError, .invalidConfigQR)
        }
    }

    func test_tooLargeRejected() {
        let hugeSecret = String(repeating: "x", count: 3_000)
        let config = AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: hugeSecret),
            qiniu: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "d")
        )
        XCTAssertThrowsError(try ConfigQRCodec.encode(config)) { error in
            XCTAssertEqual(error as? AppError, .configQRTooLarge)
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
        guard case .applied(let state) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.positionMs, 1500)
        XCTAssertEqual(state.lastSeq, 2)
    }

    func test_heartbeatWithinThresholdDoesNotSeek() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(positionMs: 1000, isPaused: false, movieId: "m1", lastSeq: 1)
        let signal = PlaybackSyncSignal(action: .heartbeat, positionMs: 1500, senderId: room.hostUserId, seq: 2)
        let result = PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current)
        guard case .applied(let state) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertEqual(state.positionMs, 1000)
    }

    func test_heartbeatBeyondThresholdSeeks() {
        let room = WatchRoom.fixture()
        let current = PlaybackState(positionMs: 1000, isPaused: false, movieId: "m1", lastSeq: 1)
        let signal = PlaybackSyncSignal(action: .heartbeat, positionMs: 3000, senderId: room.hostUserId, seq: 2)
        let result = PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current)
        guard case .applied(let state) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertEqual(state.positionMs, 3000)
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
        guard case .applied(let state) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertEqual(state.movieId, "m2")
        XCTAssertEqual(state.positionMs, 0)
        XCTAssertTrue(state.isPaused)
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

private extension AppCloudConfig {
    static func fixture() -> AppCloudConfig {
        AppCloudConfig(
            im: .init(sdkAppId: 123456789, secretKey: "im-secret"),
            qiniu: .init(
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
