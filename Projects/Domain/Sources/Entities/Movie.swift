import Foundation

public struct Movie: Equatable, Sendable, Identifiable {
    public var id: String
    public var objectKey: String
    public var title: String
    public var year: String?
    public var overview: String?
    public var posterURL: URL?
    public var format: VideoFormat
    public var playURL: URL?

    public init(
        id: String,
        objectKey: String,
        title: String,
        year: String? = nil,
        overview: String? = nil,
        posterURL: URL? = nil,
        format: VideoFormat,
        playURL: URL? = nil
    ) {
        self.id = id
        self.objectKey = objectKey
        self.title = title
        self.year = year
        self.overview = overview
        self.posterURL = posterURL
        self.format = format
        self.playURL = playURL
    }
}

public enum VideoFormat: String, Equatable, Sendable {
    case mp4
    case mkv

    public init?(filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4": self = .mp4
        case "mkv": self = .mkv
        default: return nil
        }
    }
}
