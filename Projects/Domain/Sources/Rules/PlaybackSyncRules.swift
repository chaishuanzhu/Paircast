import Foundation

public enum PlaybackSyncRules {
    public static let syncThresholdMs: Int64 = 1_200
    public static let foregroundHeartbeatSeconds: TimeInterval = 5
    public static let backgroundHeartbeatSeconds: TimeInterval = 15
    public static let hostDisconnectTimeoutSeconds: TimeInterval = 45

    public enum ApplyResult: Equatable, Sendable {
        /// - Parameter seek: Whether the player should seek to `state.positionMs`.
        case applied(PlaybackState, seek: Bool)
        case ignored(Reason)

        public enum Reason: Equatable, Sendable {
            case staleSeq
            case nonHost
            case roomEnded
        }
    }

    /// - Parameter localPositionMs: Live player clock for heartbeat drift checks.
    ///   When omitted, falls back to `current.positionMs` (tests / bookkeeping only).
    public static func shouldAccept(
        signal: PlaybackSyncSignal,
        room: WatchRoom,
        current: PlaybackState,
        localPositionMs: Int64? = nil
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
            return .applied(state, seek: true)
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
            return .applied(state, seek: true)
        case .pause:
            state.positionMs = signal.positionMs
            state.isPaused = true
            return .applied(state, seek: true)
        case .seek:
            state.positionMs = signal.positionMs
            return .applied(state, seek: true)
        case .heartbeat:
            // Compare against the *live* player clock. Using frozen `current.positionMs`
            // makes drift exceed the threshold every ~1.2s of playback and forces a seek
            // on every heartbeat → stutter + repeated stream fetches.
            let baseline = localPositionMs ?? current.positionMs
            let delta = abs(signal.positionMs - baseline)
            state.positionMs = signal.positionMs
            state.isPaused = false
            return .applied(state, seek: delta > syncThresholdMs)
        case .movieChange:
            state.movieId = signal.movieId ?? state.movieId
            state.positionMs = 0
            state.isPaused = true
            return .applied(state, seek: true)
        case .subtitleChange:
            // Subtitle share does not move the playhead or pause state.
            return .applied(state, seek: false)
        case .hostTransfer:
            break
        }

        return .applied(state, seek: false)
    }

    public static func needsSmoothCorrection(localMs: Int64, hostMs: Int64) -> Bool {
        abs(localMs - hostMs) > syncThresholdMs
    }
}
