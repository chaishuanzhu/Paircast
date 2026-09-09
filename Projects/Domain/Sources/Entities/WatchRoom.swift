import Foundation

public struct WatchRoom: Equatable, Sendable, Identifiable {
    public var id: String
    public var movieId: String
    public var hostUserId: String
    public var memberIds: [String]
    public var joinOrder: [String]
    public var status: RoomStatus
    public var lastAppliedSeq: UInt64
    public var hostTransferSeq: UInt64

    public init(
        id: String,
        movieId: String,
        hostUserId: String,
        memberIds: [String] = [],
        joinOrder: [String] = [],
        status: RoomStatus = .active,
        lastAppliedSeq: UInt64 = 0,
        hostTransferSeq: UInt64 = 0
    ) {
        self.id = id
        self.movieId = movieId
        self.hostUserId = hostUserId
        self.memberIds = memberIds.isEmpty ? [hostUserId] : memberIds
        self.joinOrder = joinOrder.isEmpty ? [hostUserId] : joinOrder
        self.status = status
        self.lastAppliedSeq = lastAppliedSeq
        self.hostTransferSeq = hostTransferSeq
    }

    public var imGroupId: String { "paircast_\(id)" }
}

public enum RoomStatus: String, Equatable, Sendable {
    case active
    case ended
}
