import Foundation

public protocol SaveCloudConfigUseCase {
    var configGateway: ConfigGateway { get }
}

public extension SaveCloudConfigUseCase {
    func saveCloudConfig(_ config: AppCloudConfig) async throws {
        var stored = try ConfigValidation.normalized(config)
        stored.updatedAt = Date()
        try await configGateway.save(stored)
    }
}

public protocol ImportConfigQRUseCase {
    var configGateway: ConfigGateway { get }
}

public extension ImportConfigQRUseCase {
    /// Decodes a share link / encrypted args / legacy JSON and persists only after validation.
    /// Invalid payloads never overwrite existing Keychain config.
    func importConfigQR(_ raw: String) async throws -> AppCloudConfig {
        let existing = try await configGateway.load()
        do {
            let decoded = try ConfigShareLink.decode(raw)
            let normalized = try ConfigValidation.normalized(decoded)
            try await configGateway.save(normalized)
            return normalized
        } catch {
            // Preserve existing config on failure.
            if let existing {
                _ = existing
            }
            if let appError = error as? AppError {
                throw appError
            }
            throw AppError.invalidConfigQR
        }
    }
}

public protocol ExportConfigQRUseCase {
    var configGateway: ConfigGateway { get }
}

public extension ExportConfigQRUseCase {
    /// Returns an encrypted share deep link: `tandem://config?args=…`
    func exportConfigQR() async throws -> String {
        guard let config = try await configGateway.load() else {
            throw AppError.notConfigured
        }
        return try ConfigShareLink.shareURL(for: config).absoluteString
    }
}

public protocol LoadCloudConfigUseCase {
    var configGateway: ConfigGateway { get }
}

public extension LoadCloudConfigUseCase {
    func loadCloudConfig() async throws -> AppCloudConfig? {
        try await configGateway.load()
    }
}
