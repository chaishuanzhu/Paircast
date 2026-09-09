import Foundation
import Security
import Domain

public final class KeychainConfigStore: ConfigGateway, @unchecked Sendable {
    private let configService = "com.chaisz.config"
    private let sessionService = "com.chaisz.session"
    private let configAccount = "cloud-config"
    private let sessionAccount = "user-id"
    private let lock = NSLock()

    public init() {}

    public func load() async throws -> AppCloudConfig? {
        try lock.withLock {
            guard let data = try read(service: configService, account: configAccount) else {
                return nil
            }
            return try JSONDecoder().decode(AppCloudConfigDTO.self, from: data).toDomain()
        }
    }

    public func save(_ config: AppCloudConfig) async throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(AppCloudConfigDTO(config))
            try write(data, service: configService, account: configAccount)
        }
    }

    public func clearSessionUserId() async throws {
        try lock.withLock {
            try delete(service: sessionService, account: sessionAccount)
        }
    }

    public func saveSessionUserId(_ userId: String) async throws {
        try lock.withLock {
            try write(Data(userId.utf8), service: sessionService, account: sessionAccount)
        }
    }

    public func loadSessionUserId() async throws -> String? {
        try lock.withLock {
            guard let data = try read(service: sessionService, account: sessionAccount) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    public func clearAll() async throws {
        try lock.withLock {
            try delete(service: configService, account: configAccount)
            try delete(service: sessionService, account: sessionAccount)
        }
    }

    private func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AppError.unknown("Keychain read failed: \(status)")
        }
        return data
    }

    private func write(_ data: Data, service: String, account: String) throws {
        try delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError.unknown("Keychain write failed: \(status)")
        }
    }

    private func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.unknown("Keychain delete failed: \(status)")
        }
    }
}

struct AppCloudConfigDTO: Codable {
    var imSdkAppId: Int
    var imSecretKey: String
    var storageProvider: String
    var storageAccessKey: String
    var storageSecretKey: String
    var storageBucket: String
    var storageEndpoint: String
    var storageRegion: String?
    var storageDomain: String?
    var storagePrefix: String?
    var storageUseSSL: Bool
    var storageForcePathStyle: Bool
    var subtitleApiKey: String?
    var omdbApiKey: String?
    var userSigExpireSeconds: Int
    var updatedAt: Date
    var configVersion: Int

    init(_ config: AppCloudConfig) {
        imSdkAppId = config.im.sdkAppId
        imSecretKey = config.im.secretKey
        storageProvider = config.storage.provider.rawValue
        storageAccessKey = config.storage.accessKey
        storageSecretKey = config.storage.secretKey
        storageBucket = config.storage.bucket
        storageEndpoint = config.storage.endpoint
        storageRegion = config.storage.region
        storageDomain = config.storage.domain
        storagePrefix = config.storage.prefix
        storageUseSSL = config.storage.useSSL
        storageForcePathStyle = config.storage.forcePathStyle
        subtitleApiKey = config.subtitleApiKey
        omdbApiKey = config.omdbApiKey
        userSigExpireSeconds = config.userSigExpireSeconds
        updatedAt = config.updatedAt
        configVersion = config.configVersion
    }

    func toDomain() -> AppCloudConfig {
        let provider = ObjectStorageProvider(rawValue: storageProvider) ?? .qiniu
        return AppCloudConfig(
            im: IMConfig(sdkAppId: imSdkAppId, secretKey: imSecretKey),
            storage: ObjectStorageConfig(
                provider: provider,
                accessKey: storageAccessKey,
                secretKey: storageSecretKey,
                bucket: storageBucket,
                endpoint: storageEndpoint,
                region: storageRegion,
                domain: storageDomain,
                prefix: storagePrefix,
                useSSL: storageUseSSL,
                forcePathStyle: storageForcePathStyle
            ),
            subtitleApiKey: subtitleApiKey,
            omdbApiKey: omdbApiKey,
            userSigExpireSeconds: userSigExpireSeconds,
            updatedAt: updatedAt,
            configVersion: configVersion
        )
    }
}
