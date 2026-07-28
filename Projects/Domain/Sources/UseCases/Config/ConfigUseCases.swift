import Foundation

public protocol SaveCloudConfigUseCase {
    var configGateway: ConfigGateway { get }
}

public extension SaveCloudConfigUseCase {
    func saveCloudConfig(_ config: AppCloudConfig) async throws {
        try ConfigValidation.validate(config)
        var stored = config
        stored.updatedAt = Date()
        try await configGateway.save(stored)
    }
}

public protocol ImportConfigQRUseCase {
    var configGateway: ConfigGateway { get }
}

public extension ImportConfigQRUseCase {
    /// Decodes and persists only after validation. Invalid payloads never overwrite.
    func importConfigQR(_ raw: String) async throws -> AppCloudConfig {
        let existing = try await configGateway.load()
        do {
            let decoded = try ConfigQRCodec.decode(raw)
            try ConfigValidation.validate(decoded)
            try await configGateway.save(decoded)
            return decoded
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
    func exportConfigQR() async throws -> String {
        guard let config = try await configGateway.load() else {
            throw AppError.notConfigured
        }
        return try ConfigQRCodec.encode(config)
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
