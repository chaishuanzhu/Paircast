import Foundation

public protocol LoginUseCase {
    var configGateway: ConfigGateway { get }
    var authGateway: AuthGateway { get }
    var userSigGateway: UserSigGateway { get }
}

public extension LoginUseCase {
    func login(userId: String) async throws {
        try LoginRules.validateUserId(userId)
        guard let config = try await configGateway.load() else {
            throw AppError.notConfigured
        }
        try ConfigValidation.validate(config)
        let trimmedId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let userSig = try userSigGateway.generateUserSig(userId: trimmedId, config: config)
        do {
            try await authGateway.login(userId: trimmedId, userSig: userSig)
            try await configGateway.saveSessionUserId(trimmedId)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.network
        }
    }
}

public protocol LogoutUseCase {
    var authGateway: AuthGateway { get }
    var configGateway: ConfigGateway { get }
}

public extension LogoutUseCase {
    func logout() async throws {
        try await authGateway.logout()
        try await configGateway.clearSessionUserId()
        // Cloud config is intentionally retained.
    }
}

public protocol DeleteAccountUseCase {
    var authGateway: AuthGateway { get }
    var configGateway: ConfigGateway { get }
}

public extension DeleteAccountUseCase {
    func deleteAccount() async throws {
        try await authGateway.deleteAccount()
        try await configGateway.clearAll()
    }
}

public protocol UpdateProfileUseCase {
    var authGateway: AuthGateway { get }
}

public extension UpdateProfileUseCase {
    func updateProfile(nickname: String, avatarData: Data?) async throws -> User {
        let name = try ProfileRules.validatedNickname(nickname)
        if let avatarData {
            _ = try ProfileRules.validatedAvatarData(avatarData)
        }
        return try await authGateway.updateProfile(nickname: name, avatarData: avatarData)
    }
}
