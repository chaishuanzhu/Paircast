import Foundation

public enum SubtitleSource: String, Equatable, Sendable {
    case embedded
    case oss
    case online
    case off
}

public struct SubtitleTrack: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var language: String?
    public var source: SubtitleSource
    public var url: URL?
    /// VLC embedded track index when `source == .embedded`.
    public var embeddedIndex: Int?
    /// Secondary line in search results, e.g. "OpenSubtitles · 下载 12.4k · SRT".
    public var detail: String?
    /// Compact language badge, e.g. "简中".
    public var languageBadge: String?
    public var format: String?

    public init(
        id: String,
        label: String,
        language: String? = nil,
        source: SubtitleSource,
        url: URL? = nil,
        embeddedIndex: Int? = nil,
        detail: String? = nil,
        languageBadge: String? = nil,
        format: String? = nil
    ) {
        self.id = id
        self.label = label
        self.language = language
        self.source = source
        self.url = url
        self.embeddedIndex = embeddedIndex
        self.detail = detail
        self.languageBadge = languageBadge
        self.format = format
    }

    public var isChinesePreferred: Bool {
        let lang = (language ?? "").lowercased()
        let labelLower = label.lowercased()
        let badge = (languageBadge ?? "").lowercased()
        if lang.contains("zh") || lang.contains("chi") || lang.contains("cn") { return true }
        if badge.contains("简") || badge.contains("繁") || badge.contains("中") { return true }
        if labelLower.contains("简体") || labelLower.contains("中文") || labelLower.contains("chinese") {
            return true
        }
        return false
    }
}

public struct SubtitleState: Equatable, Sendable {
    public var movieId: String
    public var source: SubtitleSource
    public var trackId: String?
    public var url: URL?
    public var embeddedIndex: Int?
    public var offsetMs: Int

    public static let maxOffsetMs = 30_000
    public static let minOffsetMs = -30_000

    public init(
        movieId: String,
        source: SubtitleSource = .off,
        trackId: String? = nil,
        url: URL? = nil,
        embeddedIndex: Int? = nil,
        offsetMs: Int = 0
    ) {
        self.movieId = movieId
        self.source = source
        self.trackId = trackId
        self.url = url
        self.embeddedIndex = embeddedIndex
        self.offsetMs = Self.clamped(offsetMs)
    }

    public static func clamped(_ value: Int) -> Int {
        min(maxOffsetMs, max(minOffsetMs, value))
    }

    public mutating func applyOffsetDelta(_ deltaMs: Int) {
        offsetMs = Self.clamped(offsetMs + deltaMs)
    }

    public mutating func resetOffset() {
        offsetMs = 0
    }

    public static func resetForMovieChange(movieId: String) -> SubtitleState {
        SubtitleState(movieId: movieId, source: .off)
    }

    public var offsetLabel: String {
        let seconds = Double(offsetMs) / 1000
        if abs(seconds) < 0.05 {
            return "+0.0s"
        }
        return String(format: "%+.1fs", seconds)
    }
}
