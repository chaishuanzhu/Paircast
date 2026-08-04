import Foundation
import Domain

public final class InMemoryAuthGateway: AuthGateway, @unchecked Sendable {
    private var currentUser: User?
    public var registeredUserIds: Set<String>
    private let lock = NSLock()

    public init(registeredUserIds: Set<String> = []) {
        self.registeredUserIds = registeredUserIds
    }

    public func login(userId: String, userSig: String) async throws {
        lock.lock(); defer { lock.unlock() }
        if !registeredUserIds.isEmpty && !registeredUserIds.contains(userId) {
            throw AppError.accountUnavailable
        }
        guard !userSig.isEmpty else {
            throw AppError.invalidCredentials
        }
        currentUser = User(id: userId, nickname: userId)
    }

    public func logout() async throws {
        lock.lock(); defer { lock.unlock() }
        currentUser = nil
    }

    public func currentUserId() async -> String? {
        lock.lock(); defer { lock.unlock() }
        return currentUser?.id
    }

    public func updateProfile(nickname: String, avatarData: Data?) async throws -> User {
        lock.lock(); defer { lock.unlock() }
        guard var user = currentUser else {
            throw AppError.userSigExpired
        }
        user.nickname = nickname
        if avatarData != nil {
            let key = "\(AvatarObjectKey.prefix)\(user.id)/local.jpg"
            user.avatarKey = key
            user.avatarURL = URL(string: "tandem://avatar/\(key)")
        }
        currentUser = user
        return user
    }

    public func fetchProfile() async throws -> User {
        lock.lock(); defer { lock.unlock() }
        guard let user = currentUser else {
            throw AppError.userSigExpired
        }
        return user
    }

    public func fetchUsers(userIds: [String]) async throws -> [User] {
        lock.lock(); defer { lock.unlock() }
        return userIds.map { id in
            if let currentUser, currentUser.id == id { return currentUser }
            return User(id: id, nickname: id)
        }
    }
}
