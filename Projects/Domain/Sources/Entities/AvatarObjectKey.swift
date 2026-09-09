import Foundation

/// Object key stored in Tencent IM `faceURL` (not a downloadable HTTPS URL).
/// Display URLs are resolved at login / profile fetch via S3 SigV4.
public enum AvatarObjectKey {
    public static let prefix = "_tandem/avatars/"

    /// Parses IM `faceURL` into a storage object key.
    /// Supports raw keys, `tandem://avatar/…`, and legacy HTTPS signed URLs.
    public static func parse(fromFaceURL raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix(prefix) {
            return raw
        }
        if let url = URL(string: raw), url.scheme?.lowercased() == "tandem", url.host?.lowercased() == "avatar" {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.hasPrefix(prefix) { return path }
        }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return extractFromHTTPSPath(url.path)
        }
        return nil
    }

    /// Value written to IM `faceURL`.
    public static func faceURLValue(forKey key: String) -> String {
        key
    }

    private static func extractFromHTTPSPath(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let idx = parts.firstIndex(of: "_tandem"),
              idx + 1 < parts.count,
              parts[idx + 1] == "avatars" else {
            return nil
        }
        return parts[idx...].joined(separator: "/")
    }
}
