import Foundation
import Domain

public final class TencentIMAuthGateway: AuthGateway, @unchecked Sendable {
    private let configGateway: ConfigGateway
    private let client: TencentIMClient
    private let lock = NSLock()
    private var cachedUser: User?

    public init(configGateway: ConfigGateway, client: TencentIMClient = .shared) {
        self.configGateway = configGateway
        self.client = client
    }

    public func login(userId: String, userSig: String) async throws {
        guard let config = try await configGateway.load(), config.im.isComplete else {
            throw AppError.notConfigured
        }
        try await client.login(userId: userId, userSig: userSig, sdkAppId: config.im.sdkAppId)
        let profile = try await client.fetchProfile(userId: userId)
        lock.lock()
        cachedUser = profile
        lock.unlock()
        try await configGateway.saveSessionUserId(userId)
    }

    public func logout() async throws {
        try? await client.logout()
        lock.lock()
        cachedUser = nil
        lock.unlock()
        try await configGateway.clearSessionUserId()
    }

    public func currentUserId() async -> String? {
        if let id = client.currentUserId { return id }
        lock.lock(); defer { lock.unlock() }
        return cachedUser?.id
    }

    public func updateProfile(nickname: String, avatarData: Data?) async throws -> User {
        // Avatar upload to object storage is out of MVP scope; nickname syncs to IM profile.
        _ = avatarData
        let user = try await client.updateProfile(nickname: nickname, avatarURL: nil)
        lock.lock()
        cachedUser = user
        lock.unlock()
        return user
    }

    public func fetchProfile() async throws -> User {
        guard let userId = await currentUserId() else {
            throw AppError.userSigExpired
        }
        let profile = try await client.fetchProfile(userId: userId)
        lock.lock()
        cachedUser = profile
        lock.unlock()
        return profile
    }
}
