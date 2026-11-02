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

/// Purges 1.x Keychain storage settings (Tencent IM era): the media library is configured on the
/// server now, so nothing from them is migrated.
enum LegacyConfigMigration {
    private static let service = "com.chaisz.config"
    private static let account = "cloud-config"
    private static let sessionService = "com.chaisz.session"
    private static let sessionAccount = "user-id"

    static func migrateIfNeeded(into configGateway: ConfigGateway) async {
        guard readLegacy() != nil else { return }
        deleteLegacy()
        PaircastLog.app.info("purged 1.x storage config")
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
