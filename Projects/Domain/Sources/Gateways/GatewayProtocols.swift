import Foundation

public protocol AuthGateway: AnyObject, Sendable {
    func login(userId: String, userSig: String) async throws
    func logout() async throws
    func currentUserId() async -> String?
    func updateProfile(nickname: String, avatarData: Data?) async throws -> User
    func fetchProfile() async throws -> User
    /// Batch profile lookup (nickname + avatar key → resolved avatarURL).
    func fetchUsers(userIds: [String]) async throws -> [User]
    /// Best-effort wipe of IM nickname/avatar, remote avatar object, then logout.
    func deleteAccount() async throws
}

public protocol ConfigGateway: AnyObject, Sendable {
    func load() async throws -> AppCloudConfig?
    func save(_ config: AppCloudConfig) async throws
    func clearSessionUserId() async throws
    func saveSessionUserId(_ userId: String) async throws
    func loadSessionUserId() async throws -> String?
    /// Deletes cloud config and the persisted session user id.
    func clearAll() async throws
}

public protocol UserSigGateway: Sendable {
    func generateUserSig(userId: String, config: AppCloudConfig) throws -> String
}

public protocol MovieCatalogGateway: Sendable {
    func listMovies(config: AppCloudConfig) async throws -> [Movie]
    /// AWS SigV4 query-presigned HTTPS URL for online VLC playback (default 6h).
    func playURL(for movie: Movie, config: AppCloudConfig) async throws -> URL
}

/// Uploads profile avatars to object storage and resolves short-lived download URLs from object keys.
public protocol AvatarStorageGateway: Sendable {
    /// Uploads JPEG bytes; returns the object key (IM stores this, not a signed URL).
    func uploadAvatar(imageData: Data, userId: String, config: AppCloudConfig) async throws -> String
    /// SigV4 presigned GET against the configured S3 Endpoint.
    func signedURL(objectKey: String, config: AppCloudConfig) throws -> URL
    /// Best-effort S3 DELETE of a previously uploaded avatar object.
    func deleteAvatar(objectKey: String, config: AppCloudConfig) async throws
}

public protocol MetadataGateway: Sendable {
    func enrich(_ movie: Movie, config: AppCloudConfig) async -> Movie
}

/// Reads/writes Kodi-style NFO + poster/fanart sidecars beside the movie in object storage.
public protocol MovieMetadataStorageGateway: Sendable {
    /// Returns metadata from existing `{base}.nfo` (+ art) when present; otherwise `nil`.
    func load(for movie: Movie, config: AppCloudConfig) async -> Movie?
    /// Persists NFO and downloads remote art into `{base}-poster.jpg` / `{base}-fanart.jpg`.
    /// Returns a movie whose art URLs are SigV4 GET links when upload succeeded.
    func save(_ movie: Movie, config: AppCloudConfig) async -> Movie
}

public protocol RoomGateway: AnyObject, Sendable {
    func createRoom(movieId: String, hostUserId: String) async throws -> WatchRoom
    /// - Parameters:
    ///   - movieId/hostUserId: optional invite bootstrap when the room record is not found yet.
    func joinRoom(
        roomId: String,
        userId: String,
        movieId: String?,
        hostUserId: String?
    ) async throws -> WatchRoom
    func leaveRoom(roomId: String, userId: String) async throws -> WatchRoom?
    func updateRoom(_ room: WatchRoom) async throws
    func observeRoom(roomId: String) -> AsyncStream<WatchRoom>
}

public protocol ChatGateway: AnyObject, Sendable {
    func send(roomId: String, text: String, sender: User) async throws -> ChatMessage
    func messages(roomId: String) -> AsyncStream<ChatMessage>
    func postSystemMessage(roomId: String, text: String) async throws -> ChatMessage
}

public protocol PlaybackSyncGateway: AnyObject, Sendable {
    func send(roomId: String, signal: PlaybackSyncSignal) async throws
    func signals(roomId: String) -> AsyncStream<PlaybackSyncSignal>
}

public protocol SubtitleGateway: Sendable {
    func listEmbedded(for movie: Movie) async throws -> [SubtitleTrack]
    func listOSSSidecars(for movie: Movie, config: AppCloudConfig) async throws -> [SubtitleTrack]
    func searchOnline(query: String, year: String?, apiKey: String?) async throws -> [SubtitleTrack]
    /// Downloads a track. Pass cloud config so OSS sidecars can be re-presigned at download time.
    func download(_ track: SubtitleTrack, config: AppCloudConfig?) async throws -> URL
}

/// Host uploads a downloaded subtitle beside the movie object; members pull via SigV4 GET.
public protocol SharedSubtitleStorageGateway: Sendable {
    /// Uploads local subtitle bytes next to the movie (`{movieBase}.{ext}`); returns object key.
    func upload(
        fileURL: URL,
        roomId: String,
        movieId: String,
        config: AppCloudConfig
    ) async throws -> String
    /// Downloads a shared / sidecar subtitle to a sandbox file (UTF-8 normalized).
    func download(objectKey: String, config: AppCloudConfig) async throws -> URL
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
