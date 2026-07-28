import Foundation

public enum HostTransferRules {
    public enum Outcome: Equatable, Sendable {
        case memberLeft(WatchRoom)
        case transfer(newHostUserId: String, room: WatchRoom)
        case endRoom(WatchRoom)
        case unchanged
    }

    /// Selects next host by join order after current host leaves.
    public static func resolveLeave(
        room: WatchRoom,
        leavingUserId: String,
        transferSeq: UInt64
    ) -> Outcome {
        guard room.status == .active else { return .unchanged }

        if leavingUserId != room.hostUserId {
            var updated = room
            updated.memberIds.removeAll { $0 == leavingUserId }
            updated.joinOrder.removeAll { $0 == leavingUserId }
            if updated.memberIds.isEmpty {
                updated.status = .ended
                return .endRoom(updated)
            }
            return .memberLeft(updated)
        }

        var updated = room
        updated.memberIds.removeAll { $0 == leavingUserId }
        updated.joinOrder.removeAll { $0 == leavingUserId }

        if updated.memberIds.isEmpty {
            updated.status = .ended
            return .endRoom(updated)
        }

        let nextHost = updated.joinOrder.first ?? updated.memberIds[0]
        updated.hostUserId = nextHost
        updated.hostTransferSeq = transferSeq
        return .transfer(newHostUserId: nextHost, room: updated)
    }
}
