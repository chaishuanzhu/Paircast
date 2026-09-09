import Foundation
import ImSDKSPM
import Domain

/// Shared Tencent Cloud IM wrapper (login, Meeting groups, text + custom signaling).
///
/// Thread-safety invariant: every mutable property owned by this wrapper is
/// accessed while `lock` is held. Tencent SDK objects are only invoked through
/// their documented thread-safe API. Remove `@unchecked Sendable` after the SDK
/// exposes native Sendable annotations and this state can move to an actor.
public final class TencentIMClient: NSObject, @unchecked Sendable {
    public static let shared = TencentIMClient()

    public static let systemPrefix = "[sys]"
    public static let groupTypeMeeting = "Meeting"
    public static let groupIDPrefix = "paircast_"

    private let manager = V2TIMManager.sharedInstance()!
    private let lock = NSLock()
    private var didInit = false
    private var initializedAppId: Int32 = 0
    private var loggedInUserId: String?

    private var textContinuations: [String: [UUID: AsyncStream<ChatMessage>.Continuation]] = [:]
    private var signalContinuations: [String: [UUID: AsyncStream<PlaybackSyncSignal>.Continuation]] = [:]

    private lazy var sdkListener = SDKListenerBridge(owner: self)
    private lazy var msgListener = SimpleMsgListenerBridge(owner: self)

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func ensureInitialized(sdkAppId: Int) throws {
        try lock.withLock {
            let appId = Int32(sdkAppId)
            if didInit {
                if initializedAppId != appId {
                    throw AppError.imInitFailed
                }
                return
            }
            let config = V2TIMSDKConfig()
            // V2TIM_LOG_INFO == 4
            config.logLevel = V2TIMLogLevel(rawValue: 4)!
            guard manager.initSDK(appId, config: config) else {
                throw AppError.imInitFailed
            }
            manager.addIMSDKListener(listener: sdkListener)
            manager.addSimpleMsgListener(listener: msgListener)
            didInit = true
            initializedAppId = appId
        }
    }

    public func login(userId: String, userSig: String, sdkAppId: Int) async throws {
        try ensureInitialized(sdkAppId: sdkAppId)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.login(userID: userId, userSig: userSig) { [weak self] in
                self?.lock.withLock {
                    self?.loggedInUserId = userId
                }
                cont.resume()
            } fail: { code, desc in
                cont.resume(throwing: Self.mapLoginError(code: code, desc: desc))
            }
        }
    }

    public func logout() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.logout(succ: {
                self.lock.withLock {
                    self.loggedInUserId = nil
                }
                cont.resume()
            }, fail: { code, desc in
                cont.resume(throwing: Self.mapError(code: code, desc: desc))
            })
        }
    }

    public var currentUserId: String? {
        lock.withLock {
            if let loggedInUserId { return loggedInUserId }
            return manager.getLoginUser()
        }
    }

    // MARK: - Profile

    public func fetchProfile(userId: String) async throws -> User {
        let users = try await fetchProfiles(userIds: [userId])
        return users.first ?? User(id: userId, nickname: userId)
    }

    public func fetchProfiles(userIds: [String]) async throws -> [User] {
        let ids = Array(Set(userIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[User], Error>) in
            manager.getUsersInfo(ids, succ: { list in
                let mapped: [User] = (list ?? []).compactMap { info in
                    guard let id = info.userID, !id.isEmpty else { return nil }
                    let nick = info.nickName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return User(
                        id: id,
                        nickname: (nick?.isEmpty == false ? nick! : id),
                        avatarKey: AvatarObjectKey.parse(fromFaceURL: info.faceURL)
                    )
                }
                // Preserve request order; fill missing ids with placeholders.
                let byId = Dictionary(uniqueKeysWithValues: mapped.map { ($0.id, $0) })
                cont.resume(returning: ids.map { byId[$0] ?? User(id: $0, nickname: $0) })
            }, fail: { code, desc in
                cont.resume(throwing: Self.mapError(code: code, desc: desc))
            })
        }
    }

    /// - Parameter avatarKey: When non-nil, written to IM `faceURL` as the object key (not a signed URL).
    public func updateProfile(nickname: String, avatarKey: String?) async throws -> User {
        guard let userId = currentUserId else { throw AppError.userSigExpired }
        let info = V2TIMUserFullInfo()
        info.nickName = nickname
        if let avatarKey {
            info.faceURL = avatarKey.isEmpty ? "" : AvatarObjectKey.faceURLValue(forKey: avatarKey)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.setSelfInfo(info: info) {
                cont.resume()
            } fail: { code, desc in
                cont.resume(throwing: Self.mapError(code: code, desc: desc))
            }
        }
        return User(id: userId, nickname: nickname, avatarKey: avatarKey)
    }

    // MARK: - Groups

    public static func groupID(forRoomId roomId: String) -> String {
        let id = roomId.lowercased()
        if id.hasPrefix(groupIDPrefix) { return id }
        return groupIDPrefix + id
    }

    public static func roomId(fromGroupID groupID: String) -> String {
        let id = groupID.lowercased()
        if id.hasPrefix(groupIDPrefix) {
            return String(id.dropFirst(groupIDPrefix.count))
        }
        return id
    }

    /// Ensure a Meeting group exists and the current user is a member.
    public func ensureMeetingGroup(roomId: String, groupName: String? = nil) async throws {
        let gid = Self.groupID(forRoomId: roomId)
        let name = groupName ?? "Paircast \(roomId.prefix(8))"
        try await createGroup(groupID: gid, groupName: name)
        try await joinGroup(groupID: gid)
    }

    public func createGroup(groupID: String, groupName: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.createGroup(
                groupType: Self.groupTypeMeeting,
                groupID: groupID,
                groupName: groupName
            ) { _ in
                cont.resume()
            } fail: { code, desc in
                if code == 10021 || code == 10025 {
                    cont.resume()
                } else {
                    cont.resume(throwing: Self.mapError(code: code, desc: desc))
                }
            }
        }
    }

    public func joinGroup(groupID: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.joinGroup(groupID: groupID, msg: nil) {
                cont.resume()
            } fail: { code, desc in
                if code == 10013 {
                    cont.resume()
                } else {
                    cont.resume(throwing: Self.mapError(code: code, desc: desc))
                }
            }
        }
    }

    public func quitGroup(groupID: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.quitGroup(groupID: groupID) {
                cont.resume()
            } fail: { code, desc in
                // Owner cannot quit Meeting groups — ignore; dismiss handled separately.
                if code == 10009 {
                    cont.resume()
                } else {
                    cont.resume(throwing: Self.mapError(code: code, desc: desc))
                }
            }
        }
    }

    public func dismissGroup(groupID: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.dismissGroup(groupID: groupID) {
                cont.resume()
            } fail: { code, desc in
                if code == 10010 {
                    cont.resume()
                } else {
                    cont.resume(throwing: Self.mapError(code: code, desc: desc))
                }
            }
        }
    }

    public func leaveOrDismissGroup(roomId: String, shouldDismiss: Bool) async throws {
        let gid = Self.groupID(forRoomId: roomId)
        if shouldDismiss {
            try await dismissGroup(groupID: gid)
        } else {
            try await quitGroup(groupID: gid)
        }
    }

    // MARK: - Chat

    public func sendText(
        roomId: String,
        text: String,
        asSystem: Bool = false,
        senderId: String? = nil,
        senderNickname: String? = nil
    ) async throws -> ChatMessage {
        let gid = Self.groupID(forRoomId: roomId)
        let payload = asSystem ? Self.systemPrefix + text : text
        let messageId: String = try await withCheckedThrowingContinuation { cont in
            let box = MessageIDBox()
            box.id = manager.sendGroupTextMessage(
                text: payload,
                to: gid,
                priority: .PRIORITY_NORMAL,
                succ: {
                    cont.resume(returning: box.id.isEmpty ? UUID().uuidString : box.id)
                },
                fail: { code, desc in
                    cont.resume(throwing: Self.mapError(code: code, desc: desc))
                }
            ) ?? ""
        }
        let message = ChatMessage(
            id: messageId,
            roomId: roomId.lowercased(),
            senderId: asSystem ? nil : (senderId ?? currentUserId),
            senderNickname: asSystem ? "System" : (senderNickname ?? currentUserId ?? "Me"),
            text: text,
            kind: asSystem ? .system : .user
        )
        // Local echo — simple listener typically does not deliver own messages.
        let conts = lock.withLock {
            textContinuations[roomId.lowercased()]?.values.map { $0 } ?? []
        }
        conts.forEach { $0.yield(message) }
        return message
    }

    public func sendSystemText(roomId: String, text: String) async throws -> ChatMessage {
        try await sendText(roomId: roomId, text: text, asSystem: true)
    }

    /// The callback may execute on an SDK queue, so the value is synchronized.
    private final class MessageIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""

        var id: String {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    public func textMessages(roomId: String) -> AsyncStream<ChatMessage> {
        let key = roomId.lowercased()
        return AsyncStream { continuation in
            let token = UUID()
            self.lock.withLock {
                var map = self.textContinuations[key] ?? [:]
                map[token] = continuation
                self.textContinuations[key] = map
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    self.textContinuations[key]?[token] = nil
                    if self.textContinuations[key]?.isEmpty != false {
                        self.textContinuations[key] = nil
                    }
                }
            }
        }
    }

    // MARK: - Sync signaling

    public func sendSignal(roomId: String, signal: PlaybackSyncSignal) async throws {
        let gid = Self.groupID(forRoomId: roomId)
        let data = try JSONEncoder().encode(signal)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            _ = manager.sendGroupCustomMessage(
                customData: data,
                to: gid,
                priority: .PRIORITY_HIGH
            ) {
                cont.resume()
            } fail: { code, desc in
                cont.resume(throwing: Self.mapError(code: code, desc: desc))
            }
        }
    }

    public func signals(roomId: String) -> AsyncStream<PlaybackSyncSignal> {
        let key = roomId.lowercased()
        return AsyncStream { continuation in
            let token = UUID()
            self.lock.withLock {
                var map = self.signalContinuations[key] ?? [:]
                map[token] = continuation
                self.signalContinuations[key] = map
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    self.signalContinuations[key]?[token] = nil
                    if self.signalContinuations[key]?.isEmpty != false {
                        self.signalContinuations[key] = nil
                    }
                }
            }
        }
    }

    // MARK: - Listener callbacks

    fileprivate func handleKickedOffline() {
        lock.withLock {
            loggedInUserId = nil
        }
        NotificationCenter.default.post(name: .paircastIMKickedOffline, object: nil)
    }

    fileprivate func handleUserSigExpired() {
        lock.withLock {
            loggedInUserId = nil
        }
        NotificationCenter.default.post(name: .paircastIMUserSigExpired, object: nil)
    }

    fileprivate func handleGroupText(
        msgID: String,
        groupID: String?,
        sender: V2TIMGroupMemberInfo?,
        text: String?
    ) {
        guard let groupID, let text, !text.isEmpty else { return }
        let roomId = Self.roomId(fromGroupID: groupID)
        let isSystem = text.hasPrefix(Self.systemPrefix)
        let body = isSystem ? String(text.dropFirst(Self.systemPrefix.count)) : text
        let nick = sender?.nickName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = ChatMessage(
            id: msgID,
            roomId: roomId,
            senderId: sender?.userID,
            senderNickname: isSystem ? "System" : (nick?.isEmpty == false ? nick! : (sender?.userID ?? "Unknown")),
            text: body,
            kind: isSystem ? .system : .user
        )
        let conts = lock.withLock {
            textContinuations[roomId]?.values.map { $0 } ?? []
        }
        conts.forEach { $0.yield(message) }
    }

    fileprivate func handleGroupCustom(
        groupID: String?,
        customData: Data?
    ) {
        guard let groupID, let customData else { return }
        let roomId = Self.roomId(fromGroupID: groupID)
        guard let signal = try? JSONDecoder().decode(PlaybackSyncSignal.self, from: customData) else {
            return
        }
        // Drop echo of our own signals — local UI already applied host actions.
        if let selfId = currentUserId, signal.senderId == selfId {
            return
        }
        let conts = lock.withLock {
            signalContinuations[roomId]?.values.map { $0 } ?? []
        }
        conts.forEach { $0.yield(signal) }
    }

    // MARK: - Errors

    private static func mapLoginError(code: Int32, desc: String?) -> AppError {
        switch code {
        case 6206, 70001, 70009, 70013, 70014, 70016:
            return .invalidCredentials
        case 6208:
            return .kickedOffline
        case 6014, 6017:
            return .userSigExpired
        case 6013, 6015:
            return .imInitFailed
        default:
            return mapError(code: code, desc: desc)
        }
    }

    private static func mapError(code: Int32, desc: String?) -> AppError {
        let message = desc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if code == 6014 || code == 6206 {
            return .userSigExpired
        }
        if !message.isEmpty {
            return .unknown("IM(\(code)): \(message)")
        }
        return .network
    }
}

// MARK: - ObjC listener bridges

private final class SDKListenerBridge: NSObject, V2TIMSDKListener {
    weak var owner: TencentIMClient?

    init(owner: TencentIMClient) {
        self.owner = owner
    }

    func onKickedOffline() {
        owner?.handleKickedOffline()
    }

    func onUserSigExpired() {
        owner?.handleUserSigExpired()
    }
}

private final class SimpleMsgListenerBridge: NSObject, V2TIMSimpleMsgListener {
    weak var owner: TencentIMClient?

    init(owner: TencentIMClient) {
        self.owner = owner
    }

    func onRecvGroupTextMessage(msgID: String!, groupID: String?, sender: V2TIMGroupMemberInfo!, text: String?) {
        owner?.handleGroupText(msgID: msgID ?? UUID().uuidString, groupID: groupID, sender: sender, text: text)
    }

    func onRecvGroupCustomMessage(msgID: String!, groupID: String?, sender: V2TIMGroupMemberInfo!, customData: Data?) {
        owner?.handleGroupCustom(groupID: groupID, customData: customData)
    }
}
