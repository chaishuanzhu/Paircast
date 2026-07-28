import Foundation
import Domain

public struct CascadingMetadataGateway: MetadataGateway {
    private let session: URLSession
    private let cache: MetadataCache

    public init(session: URLSession = .shared, cache: MetadataCache = .shared) {
        self.session = session
        self.cache = cache
    }

    public func enrich(_ movie: Movie, config: AppCloudConfig) async -> Movie {
        if let cached = await cache.movie(for: movie.objectKey) {
            return cached
        }
        var result = movie
        if let douban = await fetchDouban(title: movie.title, year: movie.year) {
            result = merge(result, with: douban)
        } else if let omdb = await fetchOMDb(title: movie.title, year: movie.year, apiKey: config.omdbApiKey) {
            result = merge(result, with: omdb)
        } else {
            let parsed = MovieCatalogRules.parseFilenameMetadata(from: movie.objectKey)
            result.title = parsed.title
            result.year = parsed.year ?? result.year
        }
        await cache.store(result, for: movie.objectKey)
        return result
    }

    private func fetchDouban(title: String, year: String?) async -> PartialMetadata? {
        // Douban public API is unavailable; intentionally skip without failing the chain.
        _ = title
        _ = year
        return nil
    }

    private func fetchOMDb(title: String, year: String?, apiKey: String?) async -> PartialMetadata? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.omdbapi.com/")
        var items = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "t", value: title),
            URLQueryItem(name: "plot", value: "short"),
        ]
        if let year { items.append(URLQueryItem(name: "y", value: year)) }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let dto = try JSONDecoder().decode(OMDbDTO.self, from: data)
            guard dto.Response == "True" else { return nil }
            return PartialMetadata(
                title: dto.Title,
                year: dto.Year,
                overview: dto.Plot,
                posterURL: dto.Poster.flatMap(URL.init(string:))
            )
        } catch {
            return nil
        }
    }

    private func merge(_ movie: Movie, with meta: PartialMetadata) -> Movie {
        var next = movie
        if let title = meta.title { next.title = title }
        if let year = meta.year { next.year = year }
        if let overview = meta.overview { next.overview = overview }
        if let poster = meta.posterURL { next.posterURL = poster }
        return next
    }
}

private struct PartialMetadata {
    var title: String?
    var year: String?
    var overview: String?
    var posterURL: URL?
}

private struct OMDbDTO: Decodable {
    var Title: String?
    var Year: String?
    var Plot: String?
    var Poster: String?
    var Response: String?
}

public actor MetadataCache {
    public static let shared = MetadataCache()
    private var memory: [String: (movie: Movie, storedAt: Date)] = [:]
    private let ttl: TimeInterval = 7 * 24 * 3600

    public init() {}

    public func movie(for key: String) -> Movie? {
        guard let entry = memory[key], Date().timeIntervalSince(entry.storedAt) < ttl else {
            return nil
        }
        return entry.movie
    }

    public func store(_ movie: Movie, for key: String) {
        memory[key] = (movie, Date())
    }
}
