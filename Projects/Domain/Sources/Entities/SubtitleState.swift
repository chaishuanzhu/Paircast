import Foundation

public enum SubtitleSource: String, Equatable, Sendable {
    case embedded
    case qiniu
    case online
    case off
}

public struct SubtitleTrack: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var language: String?
    public var source: SubtitleSource
    public var url: URL?

    public init(
        id: String,
        label: String,
        language: String? = nil,
        source: SubtitleSource,
        url: URL? = nil
    ) {
        self.id = id
        self.label = label
        self.language = language
        self.source = source
        self.url = url
    }
}

public struct SubtitleState: Equatable, Sendable {
    public var movieId: String
    public var source: SubtitleSource
    public var trackId: String?
    public var url: URL?
    public var offsetMs: Int

    public static let maxOffsetMs = 30_000
    public static let minOffsetMs = -30_000

    public init(
        movieId: String,
        source: SubtitleSource = .off,
        trackId: String? = nil,
        url: URL? = nil,
        offsetMs: Int = 0
    ) {
        self.movieId = movieId
        self.source = source
        self.trackId = trackId
        self.url = url
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
}
