import Foundation
import Domain

public final class TencentIMAuthGateway: AuthGateway, @unchecked Sendable {
    private let configGateway: ConfigGateway
    private let avatarStorage: AvatarStorageGateway
    private let client: TencentIMClient
    private let lock = NSLock()
    private var cachedUser: User?

    public init(
        configGateway: ConfigGateway,
        avatarStorage: AvatarStorageGateway = OSSAvatarStorage(),
        client: TencentIMClient = .shared
    ) {
        self.configGateway = configGateway
        self.avatarStorage = avatarStorage
        self.client = client
    }

    public func login(userId: String, userSig: String) async throws {
        guard let config = try await configGateway.load(), config.im.isComplete else {
            throw AppError.notConfigured
        }
        try await client.login(userId: userId, userSig: userSig, sdkAppId: config.im.sdkAppId)
        let profile = try await resolveAvatar(try await client.fetchProfile(userId: userId))
        lock.withLock {
            cachedUser = profile
        }
        try await configGateway.saveSessionUserId(userId)
    }

    public func logout() async throws {
        try? await client.logout()
        lock.withLock {
            cachedUser = nil
        }
        try await configGateway.clearSessionUserId()
    }

    public func currentUserId() async -> String? {
        if let id = client.currentUserId { return id }
        return lock.withLock { cachedUser?.id }
    }

    public func updateProfile(nickname: String, avatarData: Data?) async throws -> User {
        guard let userId = await currentUserId() else {
            throw AppError.userSigExpired
        }
        let previousKey = lock.withLock { cachedUser?.avatarKey }

        var uploadedKey: String?
        if let avatarData {
            guard let config = try await configGateway.load(), config.storage.isComplete else {
                throw AppError.notConfigured
            }
            do {
                uploadedKey = try await avatarStorage.uploadAvatar(
                    imageData: avatarData,
                    userId: userId,
                    config: config
                )
            } catch let error as AppError {
                throw error
            } catch is URLError {
                throw AppError.network
            } catch {
                throw AppError.avatarUploadFailed
            }
        }

        // Only touch IM faceURL when a new avatar was uploaded.
        let user = try await client.updateProfile(nickname: nickname, avatarKey: uploadedKey)
        var merged = user
        merged.avatarKey = uploadedKey ?? previousKey
        let resolved = try await resolveAvatar(merged)
        lock.withLock {
            cachedUser = resolved
        }
        return resolved
    }

    public func fetchProfile() async throws -> User {
        guard let userId = await currentUserId() else {
            throw AppError.userSigExpired
        }
        let resolved = try await resolveAvatar(try await client.fetchProfile(userId: userId))
        lock.withLock {
            cachedUser = resolved
        }
        return resolved
    }

    public func fetchUsers(userIds: [String]) async throws -> [User] {
        let profiles = try await client.fetchProfiles(userIds: userIds)
        var resolved: [User] = []
        resolved.reserveCapacity(profiles.count)
        for profile in profiles {
            resolved.append(try await resolveAvatar(profile))
        }
        return resolved
    }

    public func deleteAccount() async throws {
        let userId = await currentUserId()
        let avatarKey = lock.withLock { cachedUser?.avatarKey }
        if let userId {
            try? await client.updateProfile(nickname: userId, avatarKey: "")
        }
        if let avatarKey,
           let config = try? await configGateway.load(),
           config.storage.isComplete {
            try? await avatarStorage.deleteAvatar(objectKey: avatarKey, config: config)
        }
        try await logout()
    }

    /// Mints a SigV4 URL from the key stored in IM.
    private func resolveAvatar(_ user: User) async throws -> User {
        guard let key = user.avatarKey else { return user }
        guard let config = try await configGateway.load(), config.storage.isComplete else {
            return user
        }
        var copy = user
        do {
            copy.avatarURL = try avatarStorage.signedURL(objectKey: key, config: config)
        } catch {
            PaircastLog.catalog.error("avatar resolve failed key=\(key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            copy.avatarURL = nil
        }
        return copy
    }
}
