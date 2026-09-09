import Foundation
import Domain

/// Persists room JSON via object storage and mirrors lifecycle onto a Tencent IM Meeting group.
public final class IMSyncedRoomGateway: RoomGateway, @unchecked Sendable {
    private let storage: RoomGateway
    private let client: TencentIMClient

    public init(storage: RoomGateway, client: TencentIMClient = .shared) {
        self.storage = storage
        self.client = client
    }

    public func createRoom(movieId: String, hostUserId: String) async throws -> WatchRoom {
        let room = try await storage.createRoom(movieId: movieId, hostUserId: hostUserId)
        try await client.ensureMeetingGroup(roomId: room.id, groupName: "Paircast \(room.id.prefix(8))")
        return room
    }

    public func joinRoom(
        roomId: String,
        userId: String,
        movieId: String?,
        hostUserId: String?
    ) async throws -> WatchRoom {
        let room = try await storage.joinRoom(
            roomId: roomId,
            userId: userId,
            movieId: movieId,
            hostUserId: hostUserId
        )
        try await client.ensureMeetingGroup(roomId: room.id, groupName: "Paircast \(room.id.prefix(8))")
        return room
    }

    public func leaveRoom(roomId: String, userId: String) async throws -> WatchRoom? {
        let room = try await storage.leaveRoom(roomId: roomId, userId: userId)
        try? await client.leaveOrDismissGroup(roomId: roomId, shouldDismiss: false)
        return room
    }

    public func updateRoom(_ room: WatchRoom) async throws {
        try await storage.updateRoom(room)
        if room.status == .ended {
            try? await client.leaveOrDismissGroup(roomId: room.id, shouldDismiss: true)
        }
    }

    public func observeRoom(roomId: String) -> AsyncStream<WatchRoom> {
        storage.observeRoom(roomId: roomId)
    }
}
