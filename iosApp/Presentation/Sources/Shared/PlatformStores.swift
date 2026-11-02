import Foundation
import PaircastShared
import Security

/// Keychain-backed secret store for the shared module (cloud config JSON, GO-IM session).
public final class KeychainSecureStore: SecureStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    public init(service: String = "com.chaisz.paircast.secure") {
        self.service = service
    }

    public func read(key: String) -> String? {
        lock.withLock {
            var query = baseQuery(key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    public func write(key: String, value: String) {
        lock.withLock {
            let data = Data(value.utf8)
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
            if status == errSecSuccess { return }
            if status != errSecItemNotFound {
                SecItemDelete(baseQuery(key) as CFDictionary)
            }
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            if added != errSecSuccess {
                PaircastLog.app.error("keychain write failed status=\(added, privacy: .public)")
            }
        }
    }

    public func delete(key: String) {
        lock.withLock {
            _ = SecItemDelete(baseQuery(key) as CFDictionary)
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// `UserDefaults` for non-secret preferences (subtitle offsets, local block list).
public final class UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func getString(key: String) -> String? {
        if let string = defaults.string(forKey: key) { return string }
        // 1.x stored subtitle offsets as Int.
        if let number = defaults.object(forKey: key) as? NSNumber { return number.stringValue }
        return nil
    }

    public func putString(key: String, value: String) {
        defaults.set(value, forKey: key)
    }

    public func remove(key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// Imports 1.x Keychain storage settings (Tencent IM era) once; the IM server address stays empty.
enum LegacyConfigMigration {
    private static let service = "com.chaisz.config"
    private static let account = "cloud-config"
    private static let sessionService = "com.chaisz.session"
    private static let sessionAccount = "user-id"

    private struct LegacyDTO: Decodable {
        var storageProvider: String
        var storageAccessKey: String
        var storageSecretKey: String
        var storageBucket: String
        var storageEndpoint: String
        var storageRegion: String?
        var storagePrefix: String?
        var storageUseSSL: Bool
        var storageForcePathStyle: Bool
        var subtitleApiKey: String?
        var tmdbAccessToken: String?
    }

    static func migrateIfNeeded(into configGateway: ConfigGateway) async {
        guard (try? await configGateway.load()) == nil, let data = readLegacy() else { return }
        defer { deleteLegacy() }
        guard let dto = try? JSONDecoder().decode(LegacyDTO.self, from: data) else { return }
        let provider = ObjectStorageProvider.allCases.first { $0.rawValue == dto.storageProvider } ?? .qiniu
        let config = AppCloudConfig(
            im: IMConfig(serverUrl: ""),
            storage: ObjectStorageConfig(
                provider: provider,
                accessKey: dto.storageAccessKey,
                secretKey: dto.storageSecretKey,
                bucket: dto.storageBucket,
                endpoint: dto.storageEndpoint,
                region: dto.storageRegion,
                prefix: dto.storagePrefix,
                useSSL: dto.storageUseSSL,
                forcePathStyle: dto.storageForcePathStyle
            ),
            subtitleApiKey: dto.subtitleApiKey,
            tmdbAccessToken: dto.tmdbAccessToken,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            configVersion: AppCloudConfig.companion.CURRENT_VERSION
        )
        try? await configGateway.save(config: config)
        PaircastLog.app.info("migrated 1.x storage config; IM server address required")
    }

    private static func readLegacy() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func deleteLegacy() {
        for (svc, acct) in [(service, account), (sessionService, sessionAccount)] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: acct,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
