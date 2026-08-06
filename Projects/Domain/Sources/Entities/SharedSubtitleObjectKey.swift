import Foundation

/// Host-shared / sidecar subtitles live next to the movie object:
/// `films/Inception.2010.mkv` → `films/Inception.2010.srt`
public enum SharedSubtitleObjectKey {
    private static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    /// Same directory + same basename as the movie, with a subtitle extension.
    public static func sidecarKey(movieObjectKey: String, fileExtension: String) -> String? {
        let movieKey = movieObjectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !movieKey.isEmpty else { return nil }
        // Refuse writing into internal tandem prefixes.
        if movieKey.hasPrefix("_tandem/") { return nil }

        let base = (movieKey as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        let ext = normalizedExtension(fileExtension)
        return "\(base).\(ext)"
    }

    public static func isValid(_ objectKey: String) -> Bool {
        let key = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("_tandem/avatars/") else { return false }
        let ext = (key as NSString).pathExtension.lowercased()
        return subtitleExtensions.contains(ext)
    }

    public static func normalizedExtension(_ raw: String) -> String {
        let ext = raw.lowercased()
        return subtitleExtensions.contains(ext) ? ext : "srt"
    }
}
