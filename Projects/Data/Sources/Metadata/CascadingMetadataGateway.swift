import Foundation
import Domain

public struct CascadingMetadataGateway: MetadataGateway {
    private let session: URLSession
    private let cache: MetadataCache
    private let storage: MovieMetadataStorageGateway?

    public init(
        session: URLSession = .shared,
        cache: MetadataCache = .shared,
        storage: MovieMetadataStorageGateway? = nil
    ) {
        self.session = session
        self.cache = cache
        self.storage = storage
    }

    public func enrich(_ movie: Movie, config: AppCloudConfig) async -> Movie {
        if let cached = await cache.movie(for: movie.objectKey) {
            // UI may already show a TMDB CDN URL; keep retrying OSS persist until art is local.
            guard let storage, Self.needsOSSArtPersist(cached) else {
                return cached
            }
            let saved = await storage.save(cached, config: config)
            await cache.store(saved, for: movie.objectKey)
            return saved
        }

        let parsed = MovieCatalogRules.parseFilenameMetadata(from: movie.objectKey)
        var result = movie
        result.title = parsed.title
        result.year = parsed.year ?? result.year

        // Prefer existing OSS sidecars. Complete hit (with poster) skips scrape.
        // NFO-only / missing art falls through so we can still fetch and upload posters.
        if let storage, let stored = await storage.load(for: movie, config: config) {
            if stored.posterURL != nil {
                await cache.store(stored, for: movie.objectKey)
                return stored
            }
            result = stored
            if result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.title = parsed.title
            }
            if result.year == nil || result.year?.isEmpty == true {
                result.year = parsed.year ?? result.year
            }
        }

        // Use the official TMDB API only when the user supplies their own token.
        if result.posterURL == nil || Self.needsOSSArtPersist(result) || (result.overview ?? "").isEmpty {
            if let tmdb = await fetchTMDB(
                title: result.title,
                year: result.year,
                accessToken: config.tmdbAccessToken
            ) {
                result = merge(result, with: tmdb)
                PaircastLog.catalog.info(
                    "metadata tmdb hit movie=\(movie.objectKey, privacy: .public) title=\(result.title, privacy: .public) poster=\(result.posterURL != nil, privacy: .public)"
                )
            }
        }
        if result.posterURL == nil && (result.overview ?? "").isEmpty {
            PaircastLog.catalog.info(
                "metadata filename-only movie=\(movie.objectKey, privacy: .public) title=\(result.title, privacy: .public)"
            )
        }

        // Persist to object storage so the next launch reads sidecars instead of re-scraping.
        if let storage, result.posterURL != nil || !(result.overview ?? "").isEmpty {
            result = await storage.save(result, config: config)
            if Self.needsOSSArtPersist(result) {
                PaircastLog.catalog.error(
                    "metadata oss art still remote after save movie=\(movie.objectKey, privacy: .public)"
                )
            }
        }

        // Only cache successful enrichments so a token added later can retry.
        if result.posterURL != nil || !(result.overview ?? "").isEmpty {
            await cache.store(result, for: movie.objectKey)
        }
        return result
    }

    /// True when poster still points at TMDB CDN and needs upload to object storage.
    static func needsOSSArtPersist(_ movie: Movie) -> Bool {
        guard let host = movie.posterURL?.host?.lowercased() else { return false }
        return host == "image.tmdb.org" || host.hasSuffix(".tmdb.org")
    }

    // MARK: - TMDB

    private func fetchTMDB(
        title: String,
        year: String?,
        accessToken: String?
    ) async -> PartialMetadata? {
        guard let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let url = Self.tmdbSearchURL(
                title: title,
                year: year,
                language: Self.preferredTMDBLanguage()
              ) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                PaircastLog.catalog.error(
                    "tmdb search HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)"
                )
                return nil
            }
            let payload = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            guard let match = Self.pickTMDBResult(payload.results, preferringYear: year) else {
                return nil
            }
            return PartialMetadata(
                title: match.title.isEmpty ? match.originalTitle : match.title,
                year: match.releaseYear ?? year,
                overview: match.overview?.nilIfEmpty,
                posterURL: Self.tmdbImageURL(path: match.posterPath, size: "w500"),
                backdropURL: Self.tmdbImageURL(path: match.backdropPath, size: "w1280")
            )
        } catch {
            PaircastLog.catalog.error("tmdb search error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func tmdbSearchURL(title: String, year: String?, language: String) -> URL? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/movie")
        var items = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "page", value: "1"),
        ]
        if let year, !year.isEmpty {
            items.append(URLQueryItem(name: "primary_release_year", value: year))
        }
        components?.queryItems = items
        return components?.url
    }

    static func pickTMDBResult(
        _ results: [TMDBMovieResult],
        preferringYear year: String?
    ) -> TMDBMovieResult? {
        guard let year, !year.isEmpty else { return results.first }
        return results.first { $0.releaseYear == year }
    }

    static func tmdbImageURL(path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/"), !size.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    private static func preferredTMDBLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh-CN" : "en-US"
    }

    private func merge(_ movie: Movie, with meta: PartialMetadata) -> Movie {
        var next = movie
        if let title = meta.title, !title.isEmpty { next.title = title }
        if let year = meta.year, !year.isEmpty { next.year = year }
        if let overview = meta.overview, !overview.isEmpty { next.overview = overview }
        if let poster = meta.posterURL { next.posterURL = poster }
        if let backdrop = meta.backdropURL { next.backdropURL = backdrop }
        return next
    }

}

private struct PartialMetadata {
    var title: String?
    var year: String?
    var overview: String?
    var posterURL: URL?
    var backdropURL: URL?
}

struct TMDBSearchResponse: Decodable {
    var results: [TMDBMovieResult]
}

struct TMDBMovieResult: Decodable {
    var id: Int
    var title: String
    var originalTitle: String?
    var overview: String?
    var releaseDate: String?
    var posterPath: String?
    var backdropPath: String?

    var releaseYear: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case originalTitle = "original_title"
        case overview
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
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

    public func clear() {
        memory.removeAll()
    }
}
