import Foundation

public enum MovieCatalogRules {
    public static let allowedExtensions: Set<String> = ["mp4", "m4v", "mkv"]

    public static func isVideoObjectKey(_ key: String) -> Bool {
        let ext = (key as NSString).pathExtension.lowercased()
        return allowedExtensions.contains(ext)
    }

    public static func filterVideoKeys(_ keys: [String]) -> [String] {
        keys.filter(isVideoObjectKey)
    }

    public static func parseFilenameMetadata(from objectKey: String) -> (title: String, year: String?) {
        let filename = (objectKey as NSString).lastPathComponent
        let base = (filename as NSString).deletingPathExtension

        // `Title.2010.1080p` style
        let dotted = #"^(.+?)\.(\d{4})(?:\.|$)"#
        if let regex = try? NSRegularExpression(pattern: dotted),
           let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let titleRange = Range(match.range(at: 1), in: base),
           let yearRange = Range(match.range(at: 2), in: base) {
            return (
                String(base[titleRange]).replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: .whitespaces),
                String(base[yearRange])
            )
        }

        // `Title (2023)` / `Title（2023）` style (common for Chinese filenames)
        let paren = #"^(.+?)\s*[\(（](\d{4})[\)）]\s*$"#
        if let regex = try? NSRegularExpression(pattern: paren),
           let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let titleRange = Range(match.range(at: 1), in: base),
           let yearRange = Range(match.range(at: 2), in: base) {
            return (
                String(base[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                String(base[yearRange])
            )
        }

        return (base.replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: .whitespaces), nil)
    }
}
