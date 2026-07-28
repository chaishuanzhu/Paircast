import Foundation

public enum PlaybackAction: String, Equatable, Sendable, Codable {
    case play
    case pause
    case seek
    case heartbeat
    case movieChange = "movie_change"
    case hostTransfer = "host_transfer"
}

public struct PlaybackSyncSignal: Equatable, Sendable, Codable {
    public var action: PlaybackAction
    public var positionMs: Int64
    public var movieId: String?
    public var hostUserId: String?
    public var senderId: String?
    public var clientTs: Int64
    public var playbackRate: Double
    public var seq: UInt64

    public init(
        action: PlaybackAction,
        positionMs: Int64,
        movieId: String? = nil,
        hostUserId: String? = nil,
        senderId: String? = nil,
        clientTs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        playbackRate: Double = 1.0,
        seq: UInt64
    ) {
        self.action = action
        self.positionMs = positionMs
        self.movieId = movieId
        self.hostUserId = hostUserId
        self.senderId = senderId
        self.clientTs = clientTs
        self.playbackRate = playbackRate
        self.seq = seq
    }
}

public struct PlaybackState: Equatable, Sendable {
    public var positionMs: Int64
    public var isPaused: Bool
    public var movieId: String
    public var lastSeq: UInt64

    public init(positionMs: Int64 = 0, isPaused: Bool = true, movieId: String, lastSeq: UInt64 = 0) {
        self.positionMs = positionMs
        self.isPaused = isPaused
        self.movieId = movieId
        self.lastSeq = lastSeq
    }
}
