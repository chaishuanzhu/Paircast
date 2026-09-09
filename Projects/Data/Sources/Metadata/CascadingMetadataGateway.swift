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
            return cached
        }

        // Prefer existing OSS NFO / art sidecars — skip live scrape when present.
        if let storage,
           let stored = await storage.load(for: movie, config: config) {
            await cache.store(stored, for: movie.objectKey)
            return stored
        }

        let parsed = MovieCatalogRules.parseFilenameMetadata(from: movie.objectKey)
        var result = movie
        result.title = parsed.title
        result.year = parsed.year ?? result.year

        // Guideline 5.2: do not scrape Douban / IMDb. Cover art comes from
        // OSS NFO sidecars, or OMDb when the user supplies their own key.
        if result.posterURL == nil || (result.overview ?? "").isEmpty {
            if let omdb = await fetchOMDb(title: result.title, year: result.year, apiKey: config.omdbApiKey) {
                result = merge(result, with: omdb)
                PaircastLog.catalog.info(
                    "metadata omdb hit movie=\(movie.objectKey, privacy: .public) title=\(result.title, privacy: .public) poster=\(result.posterURL != nil, privacy: .public)"
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
        }

        // Only cache successful enrichments so missing OMDb keys can retry later.
        if result.posterURL != nil || !(result.overview ?? "").isEmpty {
            await cache.store(result, for: movie.objectKey)
        }
        return result
    }

    // MARK: - Douban

    private func fetchDouban(title: String, year: String?) async -> PartialMetadata? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let suggest = await doubanSuggest(query: trimmed) else { return nil }
        let pick = pickSuggestion(suggest, preferringYear: year)
        guard let pick else { return nil }

        var overview: String?
        if let id = pick.id, !id.isEmpty {
            overview = await doubanOverview(subjectId: id)
        }

        let poster = pick.img
            .map { $0.replacingOccurrences(of: "\\/", with: "/") }
            .flatMap(Self.validHTTPURL)

        return PartialMetadata(
            title: pick.title ?? trimmed,
            year: pick.year ?? year,
            overview: overview,
            posterURL: poster
        )
    }

    private func doubanSuggest(query: String) async -> [DoubanSuggestDTO]? {
        var components = URLComponents(string: "https://movie.douban.com/j/subject_suggest")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                PaircastLog.catalog.error(
                    "douban suggest HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)"
                )
                return nil
            }
            return try JSONDecoder().decode([DoubanSuggestDTO].self, from: data)
        } catch {
            PaircastLog.catalog.error("douban suggest error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func pickSuggestion(_ items: [DoubanSuggestDTO], preferringYear year: String?) -> DoubanSuggestDTO? {
        let movies = items.filter { item in
            let type = (item.type ?? "movie").lowercased()
            return type == "movie" || type.isEmpty
        }
        let pool = movies.isEmpty ? items : movies
        if let year {
            if let exact = pool.first(where: { $0.year == year }) {
                return exact
            }
        }
        return pool.first
    }

    private func doubanOverview(subjectId: String) async -> String? {
        guard let url = URL(string: "https://m.douban.com/movie/subject/\(subjectId)/") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }
            return Self.parseDoubanIntro(from: html)
        } catch {
            PaircastLog.catalog.error("douban overview error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func parseDoubanIntro(from html: String) -> String? {
        // Mobile page: 简介：……
        if let regex = try? NSRegularExpression(pattern: #"简介[：:]\s*([^<"\n]{10,600})"#),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let text = String(html[range])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        if let regex = try? NSRegularExpression(pattern: #"<meta[^>]+name="description"[^>]+content="([^"]+)""#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let text = String(html[range])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 10 { return text }
        }
        return nil
    }

    // MARK: - IMDb

    /// Undocumented public suggestion API used by imdb.com search box — no API key.
    private func fetchIMDb(title: String, year: String?) async -> PartialMetadata? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = Self.imdbSuggestionURL(for: trimmed) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.imdb.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                PaircastLog.catalog.error(
                    "imdb suggest HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)"
                )
                return nil
            }
            let dto = try JSONDecoder().decode(IMDbSuggestResponse.self, from: data)
            guard let pick = Self.pickIMDbSuggestion(dto.d ?? [], preferringYear: year) else { return nil }
            let poster = pick.i?.imageUrl.flatMap(Self.validHTTPURL)
            guard poster != nil else { return nil }
            return PartialMetadata(
                title: pick.l,
                year: pick.y.map(String.init) ?? year,
                overview: nil,
                posterURL: poster
            )
        } catch {
            PaircastLog.catalog.error("imdb suggest error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func imdbSuggestionURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let first = lowered.first.map(String.init) ?? "x"
        let isASCIILetterOrDigit: Bool = {
            guard let ch = first.first, ch.isASCII else { return false }
            return ch.isLetter || ch.isNumber
        }()
        let bucket = isASCIILetterOrDigit ? first : "x"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = lowered.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://v3.sg.media-imdb.com/suggestion/\(bucket)/\(encoded).json")
    }

    static func pickIMDbSuggestion(_ items: [IMDbSuggestItem], preferringYear year: String?) -> IMDbSuggestItem? {
        let movies = items.filter { item in
            guard let id = item.id, id.hasPrefix("tt") else { return false }
            let qid = (item.qid ?? item.q ?? "").lowercased()
            // Prefer theatrical movies; allow empty qid.
            if qid.isEmpty || qid == "movie" || qid == "feature" { return true }
            return false
        }
        let pool = movies.isEmpty ? items.filter { $0.id?.hasPrefix("tt") == true } : movies
        if let year {
            let matched = pool.filter { $0.y.map(String.init) == year }
            if let first = matched.first { return first }
            // Don't invent a wrong cover when the year is known but unmatched.
            return nil
        }
        return pool.first
    }

    // MARK: - OMDb

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
            let poster = dto.Poster.flatMap(Self.validHTTPURL)
            return PartialMetadata(
                title: dto.Title,
                year: dto.Year,
                overview: dto.Plot.flatMap { $0 == "N/A" ? nil : $0 },
                posterURL: poster
            )
        } catch {
            PaircastLog.catalog.error("omdb error=\(String(describing: error), privacy: .public)")
            return nil
        }
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

    static func validHTTPURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.uppercased() != "N/A",
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        // Prefer HTTPS for ATS.
        if scheme == "http", let host = url.host {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            return comps?.url ?? URL(string: "https://\(host)\(url.path)")
        }
        return url
    }

    private static let browserUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}

private struct PartialMetadata {
    var title: String?
    var year: String?
    var overview: String?
    var posterURL: URL?
    var backdropURL: URL?
}

private struct DoubanSuggestDTO: Decodable {
    var id: String?
    var title: String?
    var sub_title: String?
    var year: String?
    var img: String?
    var type: String?
    var url: String?
}

struct IMDbSuggestResponse: Decodable {
    var d: [IMDbSuggestItem]?
}

struct IMDbSuggestItem: Decodable {
    var id: String?
    var l: String?
    var q: String?
    var qid: String?
    var y: Int?
    var i: IMDbSuggestImage?
}

struct IMDbSuggestImage: Decodable {
    var imageUrl: String?
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

    public func clear() {
        memory.removeAll()
    }
}
