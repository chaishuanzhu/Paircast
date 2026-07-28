import XCTest
@testable import Presentation
import Domain

@MainActor
final class InviteUseCasePresentationTests: XCTestCase {
    func test_inviteURLFormat() {
        let url = InviteHarness().inviteURL(roomId: "abc")
        XCTAssertEqual(url.absoluteString, "tandem://watch?roomId=abc")
    }
}

private struct InviteHarness: InviteToRoomUseCase {}

@MainActor
final class AppRouteDeepLinkTests: XCTestCase {
    func test_watchDeepLinkRequiresLogin() async {
        let session = AppSession(
            configGateway: FakeConfig(),
            authGateway: FakeAuth(),
            userSigGateway: FakeSig(),
            catalogGateway: FakeCatalog(),
            metadataGateway: FakeMeta(),
            roomGateway: FakeRoom(),
            chatGateway: FakeChat(),
            syncGateway: FakeSync(),
            subtitleGateway: FakeSubtitle()
        )
        session.handleDeepLink(URL(string: "tandem://watch?roomId=r1")!)
        XCTAssertEqual(session.route, .login)
        XCTAssertEqual(session.toast, "请先登录再加入房间")
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
    func joinRoom(roomId: String, userId: String) async throws -> WatchRoom {
        WatchRoom(id: roomId, movieId: "m", hostUserId: userId)
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
    func download(_ track: SubtitleTrack, apiKey: String?) async throws -> URL { URL(string: "https://example.com")! }
}
