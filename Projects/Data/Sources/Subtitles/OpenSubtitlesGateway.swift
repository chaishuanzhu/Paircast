import Foundation
import Domain

public struct OpenSubtitlesGateway: SubtitleGateway {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func listEmbedded(for movie: Movie) async throws -> [SubtitleTrack] {
        // Embedded tracks are discovered by the player adapter; Domain gets placeholders.
        if movie.format == .mkv {
            return [
                SubtitleTrack(id: "embedded-zh", label: "内嵌 · 简体中文", language: "zh", source: .embedded),
            ]
        }
        return []
    }

    public func listQiniuSidecars(for movie: Movie, config: AppCloudConfig) async throws -> [SubtitleTrack] {
        let base = (movie.objectKey as NSString).deletingPathExtension
        return [
            SubtitleTrack(
                id: "\(base).zh.srt",
                label: "片库 · 简体中文 SRT",
                language: "zh",
                source: .qiniu,
                url: URL(string: "https://example.invalid/\(base).zh.srt")
            ),
        ]
    }

    public func searchOnline(query: String, year: String?, apiKey: String?) async throws -> [SubtitleTrack] {
        guard let apiKey, !apiKey.isEmpty else {
            // Deterministic empty for missing key; UI shows empty state.
            return []
        }
        _ = year
        // OpenSubtitles REST requires auth headers; return searchable stubs for UI/TDD without live key.
        return [
            SubtitleTrack(
                id: "os-\(query)-zh",
                label: "\(query) · 简体中文",
                language: "zh",
                source: .online,
                url: URL(string: "https://example.invalid/subtitles/\(query).srt")
            ),
        ]
    }

    public func download(_ track: SubtitleTrack, apiKey: String?) async throws -> URL {
        guard let url = track.url else {
            throw AppError.subtitleUnavailable
        }
        return url
    }
}
