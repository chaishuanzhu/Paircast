import Foundation

/// Local persistence for per-movie subtitle offset (device-only).
public enum SubtitleOffsetStore {
    private static let prefix = "tandem.subtitle.offset."

    public static func load(movieId: String) -> Int {
        UserDefaults.standard.integer(forKey: prefix + movieId)
    }

    public static func save(movieId: String, offsetMs: Int) {
        UserDefaults.standard.set(SubtitleState.clamped(offsetMs), forKey: prefix + movieId)
    }

    public static func clear(movieId: String) {
        UserDefaults.standard.removeObject(forKey: prefix + movieId)
    }
}
