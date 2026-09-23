import Foundation

/// Object keys under the user's bucket: `{prefix?}stickers/…`.
public enum StickersObjectKey {
    public static let folderName = "stickers"

    public static func root(storagePrefix: String?) -> String {
        join(storagePrefix: storagePrefix, relative: "\(folderName)/")
    }

    public static func catalogKey(storagePrefix: String?) -> String {
        join(storagePrefix: storagePrefix, relative: "\(folderName)/catalog.json")
    }

    public static func packManifestKey(packId: String, storagePrefix: String?) -> String {
        let safe = sanitizePathComponent(packId)
        return join(storagePrefix: storagePrefix, relative: "\(folderName)/\(safe)/pack.json")
    }

    public static func assetKey(packId: String, fileName: String, storagePrefix: String?) -> String {
        let safePack = sanitizePathComponent(packId)
        let safeFile = sanitizeFileName(fileName)
        return join(storagePrefix: storagePrefix, relative: "\(folderName)/\(safePack)/\(safeFile)")
    }

    /// Joins optional storage prefix with a relative path under the bucket.
    public static func join(storagePrefix: String?, relative: String) -> String {
        let rel = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let raw = storagePrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return rel
        }
        var prefix = raw
        while prefix.hasPrefix("/") { prefix.removeFirst() }
        if !prefix.hasSuffix("/") { prefix += "/" }
        return prefix + rel
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let joined = String(filtered)
        return joined.isEmpty ? "pack" : joined
    }

    private static func sanitizeFileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow nested-looking names but strip path separators.
        return trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }
}
