import Foundation

public protocol AuthGateway: AnyObject {
    func login(userId: String, userSig: String) async throws
    func logout() async throws
    func currentUserId() async -> String?
    func updateProfile(nickname: String, avatarData: Data?) async throws -> User
    func fetchProfile() async throws -> User
}

public protocol ConfigGateway: AnyObject {
    func load() async throws -> AppCloudConfig?
    func save(_ config: AppCloudConfig) async throws
    func clearSessionUserId() async throws
    func saveSessionUserId(_ userId: String) async throws
    func loadSessionUserId() async throws -> String?
}

public protocol UserSigGateway {
    func generateUserSig(userId: String, config: AppCloudConfig) throws -> String
}

public protocol MovieCatalogGateway {
    func listMovies(config: AppCloudConfig) async throws -> [Movie]
    func playURL(for movie: Movie, config: AppCloudConfig) async throws -> URL
}

public protocol MetadataGateway {
    func enrich(_ movie: Movie, config: AppCloudConfig) async -> Movie
}

public protocol RoomGateway: AnyObject {
    func createRoom(movieId: String, hostUserId: String) async throws -> WatchRoom
    func joinRoom(roomId: String, userId: String) async throws -> WatchRoom
    func leaveRoom(roomId: String, userId: String) async throws -> WatchRoom?
    func updateRoom(_ room: WatchRoom) async throws
    func observeRoom(roomId: String) -> AsyncStream<WatchRoom>
}

public protocol ChatGateway: AnyObject {
    func send(roomId: String, text: String, sender: User) async throws -> ChatMessage
    func messages(roomId: String) -> AsyncStream<ChatMessage>
    func postSystemMessage(roomId: String, text: String) async throws -> ChatMessage
}

public protocol PlaybackSyncGateway: AnyObject {
    func send(roomId: String, signal: PlaybackSyncSignal) async throws
    func signals(roomId: String) -> AsyncStream<PlaybackSyncSignal>
}

public protocol SubtitleGateway {
    func listEmbedded(for movie: Movie) async throws -> [SubtitleTrack]
    func listQiniuSidecars(for movie: Movie, config: AppCloudConfig) async throws -> [SubtitleTrack]
    func searchOnline(query: String, year: String?, apiKey: String?) async throws -> [SubtitleTrack]
    func download(_ track: SubtitleTrack, apiKey: String?) async throws -> URL
}

@MainActor
public protocol PlayerGateway: AnyObject {
    func prepare(url: URL) async throws
    func play() async
    func pause() async
    func seek(toMs positionMs: Int64) async
    func currentPositionMs() async -> Int64
    func isPaused() async -> Bool
    func setSubtitleURL(_ url: URL?, offsetMs: Int) async
}
