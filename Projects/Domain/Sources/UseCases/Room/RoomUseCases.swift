import Foundation

public protocol CreateOrJoinRoomUseCase {
    var roomGateway: RoomGateway { get }
}

public extension CreateOrJoinRoomUseCase {
    func createRoom(movieId: String, hostUserId: String) async throws -> WatchRoom {
        try await roomGateway.createRoom(movieId: movieId, hostUserId: hostUserId)
    }

    func joinRoom(
        roomId: String,
        userId: String,
        movieId: String? = nil,
        hostUserId: String? = nil
    ) async throws -> WatchRoom {
        try await roomGateway.joinRoom(
            roomId: roomId,
            userId: userId,
            movieId: movieId,
            hostUserId: hostUserId
        )
    }
}

public protocol LeaveRoomUseCase {
    var roomGateway: RoomGateway { get }
    var chatGateway: ChatGateway { get }
    var syncGateway: PlaybackSyncGateway { get }
}

public extension LeaveRoomUseCase {
    func leaveRoom(
        room: WatchRoom,
        leavingUserId: String,
        positionMs: Int64,
        nextTransferSeq: UInt64
    ) async throws -> HostTransferRules.Outcome {
        let outcome = HostTransferRules.resolveLeave(
            room: room,
            leavingUserId: leavingUserId,
            transferSeq: nextTransferSeq
        )
        switch outcome {
        case .unchanged:
            return outcome
        case .memberLeft(let updated):
            _ = try await roomGateway.leaveRoom(roomId: updated.id, userId: leavingUserId)
            try await roomGateway.updateRoom(updated)
            return outcome
        case .endRoom(let updated):
            _ = try await roomGateway.leaveRoom(roomId: updated.id, userId: leavingUserId)
            try await roomGateway.updateRoom(updated)
            return outcome
        case .transfer(let newHost, let updated):
            _ = try await roomGateway.leaveRoom(roomId: updated.id, userId: leavingUserId)
            try await roomGateway.updateRoom(updated)
            let signal = PlaybackSyncSignal(
                action: .hostTransfer,
                positionMs: positionMs,
                movieId: updated.movieId,
                hostUserId: newHost,
                senderId: leavingUserId,
                seq: nextTransferSeq
            )
            try await syncGateway.send(roomId: updated.id, signal: signal)
            _ = try await chatGateway.postSystemMessage(
                roomId: updated.id,
                text: "Host transferred to \(newHost)"
            )
            return outcome
        }
    }
}

public protocol ChangeMovieUseCase {
    var roomGateway: RoomGateway { get }
    var syncGateway: PlaybackSyncGateway { get }
    var chatGateway: ChatGateway { get }
}

public extension ChangeMovieUseCase {
    func changeMovie(
        room: WatchRoom,
        actorUserId: String,
        newMovie: Movie,
        seq: UInt64
    ) async throws -> (WatchRoom, PlaybackSyncSignal) {
        guard actorUserId == room.hostUserId else {
            throw AppError.onlyHostCanSwitchMovie
        }
        guard newMovie.id != room.movieId else {
            throw AppError.validation("Already playing")
        }
        var updated = room
        updated.movieId = newMovie.id
        try await roomGateway.updateRoom(updated)
        let signal = PlaybackSyncSignal(
            action: .movieChange,
            positionMs: 0,
            movieId: newMovie.id,
            hostUserId: room.hostUserId,
            senderId: actorUserId,
            seq: seq
        )
        try await syncGateway.send(roomId: room.id, signal: signal)
        _ = try await chatGateway.postSystemMessage(
            roomId: room.id,
            text: "Host switched the movie to “\(newMovie.title)”"
        )
        return (updated, signal)
    }
}

public protocol InviteToRoomUseCase {}

public extension InviteToRoomUseCase {
    func inviteURL(roomId: String, movieId: String, hostUserId: String) -> URL {
        var components = URLComponents()
        components.scheme = "tandem"
        components.host = "watch"
        components.queryItems = [
            URLQueryItem(name: "roomId", value: roomId),
            URLQueryItem(name: "movieId", value: movieId),
            URLQueryItem(name: "hostUserId", value: hostUserId),
        ]
        return components.url ?? URL(string: "tandem://watch?roomId=\(roomId)")!
    }
}
