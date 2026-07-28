import Foundation

public protocol LoginUseCase {
    var configGateway: ConfigGateway { get }
    var authGateway: AuthGateway { get }
    var userSigGateway: UserSigGateway { get }
}

public extension LoginUseCase {
    func login(userId: String, password: String) async throws {
        try LoginRules.validateCredentials(userId: userId, password: password)
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

public protocol UpdateProfileUseCase {
    var authGateway: AuthGateway { get }
}

public extension UpdateProfileUseCase {
    func updateProfile(nickname: String, avatarData: Data?) async throws -> User {
        let name = try ProfileRules.validatedNickname(nickname)
        return try await authGateway.updateProfile(nickname: name, avatarData: avatarData)
    }
}
