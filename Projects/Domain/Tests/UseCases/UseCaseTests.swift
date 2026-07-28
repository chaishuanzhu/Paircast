import XCTest
@testable import Domain

final class LoginUseCaseTests: XCTestCase {
    func test_login_requiresConfig() async {
        let sut = AuthUseCaseHarness()
        sut.fakeConfig.config = nil
        do {
            try await sut.login(userId: "u", password: "p")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AppError, .notConfigured)
        }
    }

    func test_login_successPersistsSession() async throws {
        let sut = AuthUseCaseHarness()
        sut.fakeConfig.config = .fixture()
        try await sut.login(userId: "alice", password: "secret")
        XCTAssertTrue(sut.fakeAuth.loginCalled)
        XCTAssertEqual(sut.fakeConfig.sessionUserId, "alice")
    }

    func test_logout_clearsSessionKeepsConfig() async throws {
        let sut = AuthUseCaseHarness()
        sut.fakeConfig.config = .fixture()
        sut.fakeConfig.sessionUserId = "alice"
        try await sut.logout()
        XCTAssertNil(sut.fakeConfig.sessionUserId)
        XCTAssertNotNil(sut.fakeConfig.config)
    }
}

final class ImportConfigQRUseCaseTests: XCTestCase {
    func test_invalidQRDoesNotOverwrite() async throws {
        let sut = ConfigUseCaseHarness()
        let existing = AppCloudConfig.fixture()
        sut.fakeConfig.config = existing
        do {
            _ = try await sut.importConfigQR("not-json")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(sut.fakeConfig.config, existing)
        }
    }

    func test_validQRReplacesConfig() async throws {
        let sut = ConfigUseCaseHarness()
        sut.fakeConfig.config = .fixture()
        var next = AppCloudConfig.fixture()
        next.qiniu.bucket = "other-bucket"
        let raw = try ConfigQRCodec.encode(next)
        let imported = try await sut.importConfigQR(raw)
        XCTAssertEqual(imported.qiniu.bucket, "other-bucket")
        XCTAssertEqual(sut.fakeConfig.config?.qiniu.bucket, "other-bucket")
    }
}

final class ChangeMovieUseCaseTests: XCTestCase {
    func test_memberCannotChangeMovie() async {
        let sut = RoomUseCaseHarness()
        let room = WatchRoom(id: "r", movieId: "m1", hostUserId: "host")
        do {
            _ = try await sut.changeMovie(
                room: room,
                actorUserId: "member",
                newMovie: .fixture(id: "m2"),
                seq: 1
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AppError, .onlyHostCanSwitchMovie)
        }
    }

    func test_hostChangeBroadcastsSignal() async throws {
        let sut = RoomUseCaseHarness()
        let room = WatchRoom(id: "r", movieId: "m1", hostUserId: "host")
        let (updated, signal) = try await sut.changeMovie(
            room: room,
            actorUserId: "host",
            newMovie: .fixture(id: "m2", title: "New"),
            seq: 3
        )
        XCTAssertEqual(updated.movieId, "m2")
        XCTAssertEqual(signal.action, .movieChange)
        XCTAssertEqual(sut.fakeSync.sent.count, 1)
        XCTAssertTrue(sut.fakeChat.systemTexts.contains { $0.contains("New") })
    }
}

final class ApplyPlaybackSignalUseCaseTests: XCTestCase {
    func test_applyDelegatesToRules() {
        let sut = SyncUseCaseHarness()
        let room = WatchRoom(id: "r", movieId: "m1", hostUserId: "host")
        let current = PlaybackState(movieId: "m1", lastSeq: 0)
        let signal = PlaybackSyncSignal(action: .pause, positionMs: 10, senderId: "host", seq: 1)
        let result = sut.apply(signal: signal, room: room, current: current)
        guard case .applied = result else {
            return XCTFail("expected applied")
        }
    }
}

// MARK: - Harnesses & Fakes

private final class AuthUseCaseHarness: LoginUseCase, LogoutUseCase, @unchecked Sendable {
    let configGateway: ConfigGateway
    let authGateway: AuthGateway
    let userSigGateway: UserSigGateway
    let fakeConfig: FakeConfigGateway
    let fakeAuth: FakeAuthGateway

    init() {
        let config = FakeConfigGateway()
        let auth = FakeAuthGateway()
        self.fakeConfig = config
        self.fakeAuth = auth
        self.configGateway = config
        self.authGateway = auth
        self.userSigGateway = FakeUserSigGateway()
    }
}

private final class ConfigUseCaseHarness: ImportConfigQRUseCase, ExportConfigQRUseCase, @unchecked Sendable {
    let configGateway: ConfigGateway
    let fakeConfig: FakeConfigGateway

    init() {
        let config = FakeConfigGateway()
        self.fakeConfig = config
        self.configGateway = config
    }
}

private final class RoomUseCaseHarness: ChangeMovieUseCase, @unchecked Sendable {
    let roomGateway: RoomGateway
    let syncGateway: PlaybackSyncGateway
    let chatGateway: ChatGateway
    let fakeSync: FakeSyncGateway
    let fakeChat: FakeChatGateway

    init() {
        let sync = FakeSyncGateway()
        let chat = FakeChatGateway()
        self.fakeSync = sync
        self.fakeChat = chat
        self.roomGateway = FakeRoomGateway()
        self.syncGateway = sync
        self.chatGateway = chat
    }
}

private final class SyncUseCaseHarness: ApplyPlaybackSignalUseCase {}

private final class FakeConfigGateway: ConfigGateway, @unchecked Sendable {
    var config: AppCloudConfig?
    var sessionUserId: String?

    func load() async throws -> AppCloudConfig? { config }
    func save(_ config: AppCloudConfig) async throws { self.config = config }
    func clearSessionUserId() async throws { sessionUserId = nil }
    func saveSessionUserId(_ userId: String) async throws { sessionUserId = userId }
    func loadSessionUserId() async throws -> String? { sessionUserId }
}

private final class FakeAuthGateway: AuthGateway, @unchecked Sendable {
    var loginCalled = false
    func login(userId: String, userSig: String) async throws { loginCalled = true }
    func logout() async throws {}
    func currentUserId() async -> String? { nil }
    func updateProfile(nickname: String, avatarData: Data?) async throws -> User {
        User(id: "u", nickname: nickname)
    }
    func fetchProfile() async throws -> User { User(id: "u", nickname: "n") }
}

private final class FakeUserSigGateway: UserSigGateway, @unchecked Sendable {
    func generateUserSig(userId: String, config: AppCloudConfig) throws -> String {
        "sig-\(userId)"
    }
}

private final class FakeRoomGateway: RoomGateway, @unchecked Sendable {
    var rooms: [String: WatchRoom] = [:]
    func createRoom(movieId: String, hostUserId: String) async throws -> WatchRoom {
        let room = WatchRoom(id: UUID().uuidString, movieId: movieId, hostUserId: hostUserId)
        rooms[room.id] = room
        return room
    }
    func joinRoom(roomId: String, userId: String) async throws -> WatchRoom {
        var room = rooms[roomId] ?? WatchRoom(id: roomId, movieId: "m", hostUserId: userId)
        if !room.memberIds.contains(userId) {
            room.memberIds.append(userId)
            room.joinOrder.append(userId)
        }
        rooms[roomId] = room
        return room
    }
    func leaveRoom(roomId: String, userId: String) async throws -> WatchRoom? {
        rooms[roomId]
    }
    func updateRoom(_ room: WatchRoom) async throws { rooms[room.id] = room }
    func observeRoom(roomId: String) -> AsyncStream<WatchRoom> {
        AsyncStream { $0.finish() }
    }
}

private final class FakeSyncGateway: PlaybackSyncGateway, @unchecked Sendable {
    var sent: [PlaybackSyncSignal] = []
    func send(roomId: String, signal: PlaybackSyncSignal) async throws { sent.append(signal) }
    func signals(roomId: String) -> AsyncStream<PlaybackSyncSignal> {
        AsyncStream { $0.finish() }
    }
}

private final class FakeChatGateway: ChatGateway, @unchecked Sendable {
    var systemTexts: [String] = []
    func send(roomId: String, text: String, sender: User) async throws -> ChatMessage {
        ChatMessage(id: UUID().uuidString, roomId: roomId, senderId: sender.id, senderNickname: sender.nickname, text: text)
    }
    func messages(roomId: String) -> AsyncStream<ChatMessage> {
        AsyncStream { $0.finish() }
    }
    func postSystemMessage(roomId: String, text: String) async throws -> ChatMessage {
        systemTexts.append(text)
        return ChatMessage(id: UUID().uuidString, roomId: roomId, senderNickname: "系统", text: text, kind: .system)
    }
}

private extension AppCloudConfig {
    static func fixture() -> AppCloudConfig {
        AppCloudConfig(
            im: .init(sdkAppId: 1, secretKey: "s"),
            qiniu: .init(accessKey: "a", secretKey: "b", bucket: "c", endpoint: "d")
        )
    }
}

private extension Movie {
    static func fixture(id: String, title: String = "Title") -> Movie {
        Movie(id: id, objectKey: "\(id).mp4", title: title, format: .mp4)
    }
}
