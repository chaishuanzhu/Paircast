import Foundation
import Domain

/// Persists watch rooms as JSON objects in the configured Qiniu bucket so friends on
/// other devices can join via invite (in-memory rooms cannot cross processes/devices).
public final class QiniuRoomGateway: RoomGateway, @unchecked Sendable {
    public static let objectKeyPrefix = "_tandem/rooms/"

    private let configGateway: ConfigGateway
    private let session: URLSession
    private let lock = NSLock()
    private var localCache: [String: WatchRoom] = [:]
    private var continuations: [String: [UUID: AsyncStream<WatchRoom>.Continuation]] = [:]
    private var pollTasks: [String: Task<Void, Never>] = [:]

    public init(configGateway: ConfigGateway, session: URLSession = .shared) {
        self.configGateway = configGateway
        self.session = session
    }

    public func createRoom(movieId: String, hostUserId: String) async throws -> WatchRoom {
        let id = UUID().uuidString.lowercased()
        let room = WatchRoom(id: id, movieId: movieId, hostUserId: hostUserId)
        try await putRoom(room)
        cacheAndBroadcast(room)
        return room
    }

    public func joinRoom(
        roomId: String,
        userId: String,
        movieId: String?,
        hostUserId: String?
    ) async throws -> WatchRoom {
        let id = roomId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { throw AppError.roomNotFound }

        var room: WatchRoom
        if let existing = try await fetchRoom(id: id) {
            room = existing
        } else if let movieId, let hostUserId, !movieId.isEmpty, !hostUserId.isEmpty {
            // Invite bootstrap: host's PUT may be briefly invisible, or invite carries full context.
            room = WatchRoom(id: id, movieId: movieId, hostUserId: hostUserId)
        } else {
            throw AppError.roomNotFound
        }

        guard room.status == .active else { throw AppError.roomEnded }

        if !room.memberIds.contains(userId) {
            room.memberIds.append(userId)
            room.joinOrder.append(userId)
        }
        try await putRoom(room)
        cacheAndBroadcast(room)
        return room
    }

    public func leaveRoom(roomId: String, userId: String) async throws -> WatchRoom? {
        let id = roomId.lowercased()
        if let cached = cachedRoom(id) { return cached }
        return try await fetchRoom(id: id)
    }

    public func updateRoom(_ room: WatchRoom) async throws {
        if room.status == .ended {
            // Notify local observers first, then remove the Qiniu object so dissolved
            // rooms do not leave orphan `_tandem/rooms/{id}.json` files.
            cacheAndBroadcast(room)
            do {
                try await deleteRoomObject(id: room.id)
            } catch {
                TandemLog.catalog.error(
                    "room DELETE failed id=\(room.id, privacy: .public); writing ended tombstone"
                )
                try await putRoom(room)
            }
            stopPolling(roomId: room.id)
            return
        }
        try await putRoom(room)
        cacheAndBroadcast(room)
    }

    public func observeRoom(roomId: String) -> AsyncStream<WatchRoom> {
        let id = roomId.lowercased()
        return AsyncStream { continuation in
            let token = UUID()
            self.lock.lock()
            var map = self.continuations[id] ?? [:]
            map[token] = continuation
            self.continuations[id] = map
            let existing = self.localCache[id]
            let shouldStartPoll = self.pollTasks[id] == nil
            self.lock.unlock()

            if let existing {
                continuation.yield(existing)
            }

            if shouldStartPoll {
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.pollLoop(roomId: id)
                }
                self.lock.lock()
                self.pollTasks[id] = task
                self.lock.unlock()
            }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id]?[token] = nil
                let empty = self.continuations[id]?.isEmpty != false
                if empty {
                    self.continuations[id] = nil
                    self.pollTasks[id]?.cancel()
                    self.pollTasks[id] = nil
                }
                self.lock.unlock()
            }
        }
    }

    // MARK: - Qiniu IO

    private func pollLoop(roomId: String) async {
        while !Task.isCancelled {
            do {
                if let room = try await fetchRoom(id: roomId) {
                    cacheAndBroadcast(room)
                }
            } catch {
                // Transient network — keep polling while observers exist.
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            lock.lock()
            let hasObservers = !(continuations[roomId] ?? [:]).isEmpty
            lock.unlock()
            if !hasObservers { break }
        }
        lock.lock()
        pollTasks[roomId] = nil
        lock.unlock()
    }

    private func fetchRoom(id: String) async throws -> WatchRoom? {
        let config = try await requireConfig()
        let url = try objectURL(roomId: id, config: config)
        let region = AWSV4Signer.region(fromEndpoint: config.qiniu.endpoint)
        let signed = try AWSV4Signer.signHeader(
            method: "GET",
            url: url,
            region: region,
            credentials: .init(accessKey: config.qiniu.accessKey, secretKey: config.qiniu.secretKey)
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        request.timeoutInterval = 20
        for (key, value) in signed.headers where key.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.network }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            TandemLog.catalog.error("room GET HTTP \(http.statusCode, privacy: .public)")
            throw AppError.network
        }
        return try JSONDecoder().decode(WatchRoomDTO.self, from: data).toDomain()
    }

    private func putRoom(_ room: WatchRoom) async throws {
        let config = try await requireConfig()
        let dto = WatchRoomDTO(room)
        let body = try JSONEncoder().encode(dto)
        let url = try objectURL(roomId: room.id, config: config)
        let region = AWSV4Signer.region(fromEndpoint: config.qiniu.endpoint)
        let payloadHash = AWSV4Signer.sha256Hex(body)
        let signed = try AWSV4Signer.signHeader(
            method: "PUT",
            url: url,
            region: region,
            credentials: .init(accessKey: config.qiniu.accessKey, secretKey: config.qiniu.secretKey),
            headers: ["content-type": "application/json"],
            payloadHash: payloadHash
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        request.httpBody = body
        request.timeoutInterval = 20
        for (key, value) in signed.headers where key.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            TandemLog.catalog.error("room PUT HTTP \(code, privacy: .public)")
            throw AppError.network
        }
    }

    private func deleteRoomObject(id: String) async throws {
        let config = try await requireConfig()
        let url = try objectURL(roomId: id, config: config)
        let region = AWSV4Signer.region(fromEndpoint: config.qiniu.endpoint)
        let signed = try AWSV4Signer.signHeader(
            method: "DELETE",
            url: url,
            region: region,
            credentials: .init(accessKey: config.qiniu.accessKey, secretKey: config.qiniu.secretKey)
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        request.timeoutInterval = 20
        for (key, value) in signed.headers where key.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.network }
        // 404: already gone — treat as success for dissolve cleanup.
        guard http.statusCode == 404 || (200..<300).contains(http.statusCode) else {
            TandemLog.catalog.error("room DELETE HTTP \(http.statusCode, privacy: .public)")
            throw AppError.network
        }
        TandemLog.catalog.info("room DELETE ok id=\(id, privacy: .public)")
    }

    public static func objectKey(roomId: String) -> String {
        objectKeyPrefix + roomId.lowercased() + ".json"
    }

    private func objectURL(roomId: String, config: AppCloudConfig) throws -> URL {
        let host = AWSV4Signer.normalizedHost(config.qiniu.endpoint)
        let key = Self.objectKey(roomId: roomId)
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = "/" + ([config.qiniu.bucket] + key.split(separator: "/").map(String.init))
            .map { AWSV4Signer.uriEncodePublic($0) }
            .joined(separator: "/")
        guard let url = components.url else { throw AppError.network }
        return url
    }

    private func requireConfig() async throws -> AppCloudConfig {
        guard let config = try await configGateway.load(), config.qiniu.isComplete else {
            throw AppError.notConfigured
        }
        return config
    }

    private func cachedRoom(_ id: String) -> WatchRoom? {
        lock.lock(); defer { lock.unlock() }
        return localCache[id]
    }

    private func cacheAndBroadcast(_ room: WatchRoom) {
        lock.lock()
        localCache[room.id.lowercased()] = room
        let conts = continuations[room.id.lowercased()]?.values.map { $0 } ?? []
        lock.unlock()
        conts.forEach { $0.yield(room) }
    }

    private func stopPolling(roomId: String) {
        let id = roomId.lowercased()
        lock.lock()
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        lock.unlock()
    }
}

struct WatchRoomDTO: Codable, Equatable {
    var id: String
    var movieId: String
    var hostUserId: String
    var memberIds: [String]
    var joinOrder: [String]
    var status: String
    var lastAppliedSeq: UInt64
    var hostTransferSeq: UInt64

    init(_ room: WatchRoom) {
        id = room.id
        movieId = room.movieId
        hostUserId = room.hostUserId
        memberIds = room.memberIds
        joinOrder = room.joinOrder
        status = room.status.rawValue
        lastAppliedSeq = room.lastAppliedSeq
        hostTransferSeq = room.hostTransferSeq
    }

    func toDomain() -> WatchRoom {
        WatchRoom(
            id: id,
            movieId: movieId,
            hostUserId: hostUserId,
            memberIds: memberIds,
            joinOrder: joinOrder,
            status: RoomStatus(rawValue: status) ?? .ended,
            lastAppliedSeq: lastAppliedSeq,
            hostTransferSeq: hostTransferSeq
        )
    }
}
