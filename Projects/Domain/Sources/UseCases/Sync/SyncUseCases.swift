import Foundation

public protocol ApplyPlaybackSignalUseCase {}

public extension ApplyPlaybackSignalUseCase {
    func apply(
        signal: PlaybackSyncSignal,
        room: WatchRoom,
        current: PlaybackState
    ) -> PlaybackSyncRules.ApplyResult {
        PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: current)
    }
}

public protocol EmitHostPlaybackUseCase {
    var syncGateway: PlaybackSyncGateway { get }
}

public extension EmitHostPlaybackUseCase {
    func emitHostSignal(
        room: WatchRoom,
        hostUserId: String,
        action: PlaybackAction,
        positionMs: Int64,
        seq: UInt64,
        movieId: String? = nil,
        subtitleObjectKey: String? = nil,
        subtitleLabel: String? = nil
    ) async throws -> PlaybackSyncSignal {
        guard hostUserId == room.hostUserId else {
            throw AppError.onlyHostCanSwitchMovie
        }
        let signal = PlaybackSyncSignal(
            action: action,
            positionMs: positionMs,
            movieId: movieId ?? room.movieId,
            hostUserId: hostUserId,
            senderId: hostUserId,
            seq: seq,
            subtitleObjectKey: subtitleObjectKey,
            subtitleLabel: subtitleLabel
        )
        try await syncGateway.send(roomId: room.id, signal: signal)
        return signal
    }
}
