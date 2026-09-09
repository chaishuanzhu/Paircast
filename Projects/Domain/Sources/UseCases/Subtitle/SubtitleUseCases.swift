import Foundation

public protocol ApplySubtitleOffsetUseCase {}

public extension ApplySubtitleOffsetUseCase {
    func applyOffset(state: SubtitleState, deltaMs: Int) -> SubtitleState {
        var next = state
        next.applyOffsetDelta(deltaMs)
        return next
    }

    func resetOffset(state: SubtitleState) -> SubtitleState {
        var next = state
        next.resetOffset()
        return next
    }

    func resetForMovieChange(movieId: String) -> SubtitleState {
        SubtitleState.resetForMovieChange(movieId: movieId)
    }
}

public protocol SearchOnlineSubtitlesUseCase {
    var subtitleGateway: SubtitleGateway { get }
    var configGateway: ConfigGateway { get }
}

public extension SearchOnlineSubtitlesUseCase {
    func searchOnlineSubtitles(query: String, year: String?) async throws -> [SubtitleTrack] {
        let config = try await configGateway.load()
        return try await subtitleGateway.searchOnline(
            query: query,
            year: year,
            apiKey: config?.subtitleApiKey
        )
    }
}

public protocol ListSubtitleTracksUseCase {
    var subtitleGateway: SubtitleGateway { get }
    var configGateway: ConfigGateway { get }
}

public extension ListSubtitleTracksUseCase {
    func listSubtitleTracks(for movie: Movie) async throws -> [SubtitleTrack] {
        let config = try await configGateway.load()
        var tracks: [SubtitleTrack] = [
            SubtitleTrack(id: "off", label: "Off", source: .off),
        ]
        tracks += try await subtitleGateway.listEmbedded(for: movie)
        if let config {
            tracks += try await subtitleGateway.listOSSSidecars(for: movie, config: config)
        }
        return tracks
    }
}
