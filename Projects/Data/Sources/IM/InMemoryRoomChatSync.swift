import Foundation
import Domain

public final class InMemoryRoomGateway: RoomGateway, @unchecked Sendable {
    private var rooms: [String: WatchRoom] = [:]
    private var continuations: [String: [UUID: AsyncStream<WatchRoom>.Continuation]] = [:]
    private let lock = NSLock()

    public init() {}

    public func createRoom(movieId: String, hostUserId: String) async throws -> WatchRoom {
        lock.lock()
        let id = UUID().uuidString.lowercased()
        let room = WatchRoom(id: id, movieId: movieId, hostUserId: hostUserId)
        rooms[id] = room
        let conts = continuations[id]?.values.map { $0 } ?? []
        lock.unlock()
        conts.forEach { $0.yield(room) }
        return room
    }

    public func joinRoom(
        roomId: String,
        userId: String,
        movieId: String?,
        hostUserId: String?
    ) async throws -> WatchRoom {
        lock.lock()
        let id = roomId.lowercased()
        let room: WatchRoom
        if var existing = rooms[id] {
            guard existing.status == .active else {
                lock.unlock()
                throw AppError.roomEnded
            }
            if !existing.memberIds.contains(userId) {
                existing.memberIds.append(userId)
                existing.joinOrder.append(userId)
            }
            rooms[id] = existing
            room = existing
        } else if let movieId, let hostUserId, !movieId.isEmpty, !hostUserId.isEmpty {
            var created = WatchRoom(id: id, movieId: movieId, hostUserId: hostUserId)
            if userId != hostUserId, !created.memberIds.contains(userId) {
                created.memberIds.append(userId)
                created.joinOrder.append(userId)
            }
            rooms[id] = created
            room = created
        } else {
            lock.unlock()
            throw AppError.roomNotFound
        }
        let conts = continuations[id]?.values.map { $0 } ?? []
        lock.unlock()
        conts.forEach { $0.yield(room) }
        return room
    }

    public func leaveRoom(roomId: String, userId: String) async throws -> WatchRoom? {
        lock.lock(); defer { lock.unlock() }
        return rooms[roomId]
    }

    public func updateRoom(_ room: WatchRoom) async throws {
        lock.lock()
        rooms[room.id] = room
        let conts = continuations[room.id]?.values.map { $0 } ?? []
        lock.unlock()
        conts.forEach { $0.yield(room) }
    }

    public func observeRoom(roomId: String) -> AsyncStream<WatchRoom> {
        AsyncStream { continuation in
            let token = UUID()
            self.lock.lock()
            var map = self.continuations[roomId] ?? [:]
            map[token] = continuation
            self.continuations[roomId] = map
            let existing = self.rooms[roomId]
            self.lock.unlock()
            if let existing {
                continuation.yield(existing)
            }
            continuation.onTermination = { _ in
                self.lock.lock()
                self.continuations[roomId]?[token] = nil
                self.lock.unlock()
            }
        }
    }
}

public final class InMemoryChatGateway: ChatGateway, @unchecked Sendable {
    private var storage: [String: [ChatMessage]] = [:]
    private var continuations: [String: [UUID: AsyncStream<ChatMessage>.Continuation]] = [:]
    private let lock = NSLock()

    public init() {}

    public func send(roomId: String, text: String, sender: User) async throws -> ChatMessage {
        let message = ChatMessage(
            id: UUID().uuidString,
            roomId: roomId,
            senderId: sender.id,
            senderNickname: sender.nickname,
            text: text
        )
        append(message)
        return message
    }

    public func messages(roomId: String) -> AsyncStream<ChatMessage> {
        AsyncStream { continuation in
            let token = UUID()
            self.lock.lock()
            var map = self.continuations[roomId] ?? [:]
            map[token] = continuation
            self.continuations[roomId] = map
            let existing = self.storage[roomId] ?? []
            self.lock.unlock()
            existing.forEach { continuation.yield($0) }
            continuation.onTermination = { _ in
                self.lock.lock()
                self.continuations[roomId]?[token] = nil
                self.lock.unlock()
            }
        }
    }

    public func postSystemMessage(roomId: String, text: String) async throws -> ChatMessage {
        let message = ChatMessage(
            id: UUID().uuidString,
            roomId: roomId,
            senderNickname: "系统",
            text: text,
            kind: .system
        )
        append(message)
        return message
    }

    private func append(_ message: ChatMessage) {
        lock.lock()
        storage[message.roomId, default: []].append(message)
        let conts = continuations[message.roomId]?.values.map { $0 } ?? []
        lock.unlock()
        conts.forEach { $0.yield(message) }
    }
}

public final class InMemoryPlaybackSyncGateway: PlaybackSyncGateway, @unchecked Sendable {
    private var continuations: [String: [UUID: AsyncStream<PlaybackSyncSignal>.Continuation]] = [:]
    private let lock = NSLock()

    public init() {}

    public func send(roomId: String, signal: PlaybackSyncSignal) async throws {
        lock.lock()
        let conts = continuations[roomId]?.values.map { $0 } ?? []
        lock.unlock()
        conts.forEach { $0.yield(signal) }
    }

    public func signals(roomId: String) -> AsyncStream<PlaybackSyncSignal> {
        AsyncStream { continuation in
            let token = UUID()
            self.lock.lock()
            var map = self.continuations[roomId] ?? [:]
            map[token] = continuation
            self.continuations[roomId] = map
            self.lock.unlock()
            continuation.onTermination = { _ in
                self.lock.lock()
                self.continuations[roomId]?[token] = nil
                self.lock.unlock()
            }
        }
    }
}
