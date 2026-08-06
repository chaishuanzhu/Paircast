import XCTest
@testable import Presentation
import Domain

@MainActor
final class InviteUseCasePresentationTests: XCTestCase {
    func test_inviteURLFormat() {
        let url = InviteHarness().inviteURL(roomId: "abc", movieId: "film.mkv", hostUserId: "alice")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.scheme, "tandem")
        XCTAssertEqual(url.host, "watch")
        XCTAssertEqual(items.first(where: { $0.name == "roomId" })?.value, "abc")
        XCTAssertEqual(items.first(where: { $0.name == "movieId" })?.value, "film.mkv")
        XCTAssertEqual(items.first(where: { $0.name == "hostUserId" })?.value, "alice")
    }
}

private struct InviteHarness: InviteToRoomUseCase {}

@MainActor
final class AppRouteDeepLinkTests: XCTestCase {
    func test_watchDeepLinkRequiresLoginAndKeepsPendingInvite() async {
        let session = AppSession(
            configGateway: FakeConfig(),
            authGateway: FakeAuth(),
            userSigGateway: FakeSig(),
            catalogGateway: FakeCatalog(),
            metadataGateway: FakeMeta(),
            roomGateway: FakeRoom(),
            chatGateway: FakeChat(),
            syncGateway: FakeSync(),
            subtitleGateway: FakeSubtitle(),
            sharedSubtitleStorage: FakeSharedSubtitle()
        )
        session.handleDeepLink(URL(string: "tandem://watch?roomId=r1&movieId=m1&hostUserId=host")!)
        XCTAssertEqual(session.route, .login)
        XCTAssertEqual(session.toast, "请先登录再加入房间")
        XCTAssertEqual(session.pendingInvite?.roomId, "r1")
        XCTAssertEqual(session.pendingInvite?.movieId, "m1")
        XCTAssertEqual(session.pendingInvite?.hostUserId, "host")
    }

    func test_watchDeepLinkOpensWatchWhenLoggedIn() async {
        let session = AppSession(
            configGateway: FakeConfig(),
            authGateway: FakeAuth(),
            userSigGateway: FakeSig(),
            catalogGateway: FakeCatalog(),
            metadataGateway: FakeMeta(),
            roomGateway: FakeRoom(),
            chatGateway: FakeChat(),
            syncGateway: FakeSync(),
            subtitleGateway: FakeSubtitle(),
            sharedSubtitleStorage: FakeSharedSubtitle()
        )
        session.currentUser = User(id: "bob", nickname: "bob")
        session.handleDeepLink(URL(string: "tandem://watch?roomId=r1&movieId=m1&hostUserId=host")!)
        XCTAssertEqual(session.route, .watch(roomId: "r1", movieId: "m1", hostUserId: "host"))
        XCTAssertNil(session.pendingInvite)
    }

    func test_configShareDeepLinkOpensConfigWithPendingImport() throws {
        let session = AppSession(
            configGateway: FakeConfig(),
            authGateway: FakeAuth(),
            userSigGateway: FakeSig(),
            catalogGateway: FakeCatalog(),
            metadataGateway: FakeMeta(),
            roomGateway: FakeRoom(),
            chatGateway: FakeChat(),
            syncGateway: FakeSync(),
            subtitleGateway: FakeSubtitle(),
            sharedSubtitleStorage: FakeSharedSubtitle()
        )
        let share = try ConfigShareLink.shareURL(for: .fixture())
        session.handleDeepLink(share)
        XCTAssertEqual(session.route, .config(fromLogin: true))
        XCTAssertEqual(session.consumePendingConfigImport(), share.absoluteString)
        XCTAssertNil(session.consumePendingConfigImport())
    }
}

private final class FakeConfig: ConfigGateway, @unchecked Sendable {
    func load() async throws -> AppCloudConfig? { nil }
    func save(_ config: AppCloudConfig) async throws {}
    func clearSessionUserId() async throws {}
    func saveSessionUserId(_ userId: String) async throws {}
    func loadSessionUserId() async throws -> String? { nil }
}
private final class FakeAuth: AuthGateway, @unchecked Sendable {
    func login(userId: String, userSig: String) async throws {}
    func logout() async throws {}
    func currentUserId() async -> String? { nil }
    func updateProfile(nickname: String, avatarData: Data?) async throws -> User { User(id: "u", nickname: nickname) }
    func fetchProfile() async throws -> User { User(id: "u", nickname: "n") }
    func fetchUsers(userIds: [String]) async throws -> [User] {
        userIds.map { User(id: $0, nickname: $0) }
    }
}
private final class FakeSig: UserSigGateway, @unchecked Sendable {
    func generateUserSig(userId: String, config: AppCloudConfig) throws -> String { "sig" }
}
private final class FakeCatalog: MovieCatalogGateway, @unchecked Sendable {
    func listMovies(config: AppCloudConfig) async throws -> [Movie] { [] }
    func playURL(for movie: Movie, config: AppCloudConfig) async throws -> URL { URL(string: "https://example.com")! }
}
private final class FakeMeta: MetadataGateway, @unchecked Sendable {
    func enrich(_ movie: Movie, config: AppCloudConfig) async -> Movie { movie }
}
private final class FakeRoom: RoomGateway, @unchecked Sendable {
    func createRoom(movieId: String, hostUserId: String) async throws -> WatchRoom {
        WatchRoom(id: "r", movieId: movieId, hostUserId: hostUserId)
    }
    func joinRoom(
        roomId: String,
        userId: String,
        movieId: String?,
        hostUserId: String?
    ) async throws -> WatchRoom {
        WatchRoom(
            id: roomId,
            movieId: movieId ?? "m",
            hostUserId: hostUserId ?? userId
        )
    }
    func leaveRoom(roomId: String, userId: String) async throws -> WatchRoom? { nil }
    func updateRoom(_ room: WatchRoom) async throws {}
    func observeRoom(roomId: String) -> AsyncStream<WatchRoom> { AsyncStream { $0.finish() } }
}
private final class FakeChat: ChatGateway, @unchecked Sendable {
    func send(roomId: String, text: String, sender: User) async throws -> ChatMessage {
        ChatMessage(id: "1", roomId: roomId, senderNickname: sender.nickname, text: text)
    }
    func messages(roomId: String) -> AsyncStream<ChatMessage> { AsyncStream { $0.finish() } }
    func postSystemMessage(roomId: String, text: String) async throws -> ChatMessage {
        ChatMessage(id: "1", roomId: roomId, senderNickname: "系统", text: text, kind: .system)
    }
}
private final class FakeSync: PlaybackSyncGateway, @unchecked Sendable {
    func send(roomId: String, signal: PlaybackSyncSignal) async throws {}
    func signals(roomId: String) -> AsyncStream<PlaybackSyncSignal> { AsyncStream { $0.finish() } }
}
private final class FakeSubtitle: SubtitleGateway, @unchecked Sendable {
    func listEmbedded(for movie: Movie) async throws -> [SubtitleTrack] { [] }
    func listQiniuSidecars(for movie: Movie, config: AppCloudConfig) async throws -> [SubtitleTrack] { [] }
    func searchOnline(query: String, year: String?, apiKey: String?) async throws -> [SubtitleTrack] { [] }
    func download(_ track: SubtitleTrack, config: AppCloudConfig?) async throws -> URL {
        URL(string: "https://example.com")!
    }
}
private final class FakeSharedSubtitle: SharedSubtitleStorageGateway, @unchecked Sendable {
    func upload(
        fileURL: URL,
        roomId: String,
        movieId: String,
        config: AppCloudConfig
    ) async throws -> String {
        SharedSubtitleObjectKey.sidecarKey(movieObjectKey: movieId, fileExtension: "srt")
            ?? "\(movieId).srt"
    }
    func download(objectKey: String, config: AppCloudConfig) async throws -> URL {
        URL(fileURLWithPath: "/tmp/fake.srt")
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
            )
        )
    }
}
