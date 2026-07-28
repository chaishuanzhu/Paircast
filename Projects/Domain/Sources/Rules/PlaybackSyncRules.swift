import Foundation

public enum PlaybackSyncRules {
    public static let syncThresholdMs: Int64 = 1_200
    public static let foregroundHeartbeatSeconds: TimeInterval = 5
    public static let backgroundHeartbeatSeconds: TimeInterval = 15
    public static let hostDisconnectTimeoutSeconds: TimeInterval = 45

    public enum ApplyResult: Equatable, Sendable {
        case applied(PlaybackState)
        case ignored(Reason)

        public enum Reason: Equatable, Sendable {
            case staleSeq
            case nonHost
            case roomEnded
        }
    }

    public static func shouldAccept(
        signal: PlaybackSyncSignal,
        room: WatchRoom,
        current: PlaybackState
    ) -> ApplyResult {
        guard room.status == .active else {
            return .ignored(.roomEnded)
        }

        if signal.action == .hostTransfer {
            guard let newHost = signal.hostUserId, !newHost.isEmpty else {
                return .ignored(.nonHost)
            }
            guard signal.seq > room.hostTransferSeq else {
                return .ignored(.staleSeq)
            }
            var state = current
            state.positionMs = signal.positionMs
            state.isPaused = true
            if let movieId = signal.movieId {
                state.movieId = movieId
            }
            state.lastSeq = max(current.lastSeq, signal.seq)
            return .applied(state)
        }

        guard signal.seq > current.lastSeq else {
            return .ignored(.staleSeq)
        }

        let sender = signal.senderId ?? ""
        guard sender == room.hostUserId else {
            return .ignored(.nonHost)
        }

        var state = current
        state.lastSeq = signal.seq

        switch signal.action {
        case .play:
            state.positionMs = signal.positionMs
            state.isPaused = false
        case .pause:
            state.positionMs = signal.positionMs
            state.isPaused = true
        case .seek:
            state.positionMs = signal.positionMs
        case .heartbeat:
            let delta = abs(signal.positionMs - current.positionMs)
            if delta > syncThresholdMs {
                state.positionMs = signal.positionMs
            }
            state.isPaused = false
        case .movieChange:
            state.movieId = signal.movieId ?? state.movieId
            state.positionMs = 0
            state.isPaused = true
        case .hostTransfer:
            break
        }

        return .applied(state)
    }

    public static func needsSmoothCorrection(localMs: Int64, hostMs: Int64) -> Bool {
        abs(localMs - hostMs) > syncThresholdMs
    }
}
