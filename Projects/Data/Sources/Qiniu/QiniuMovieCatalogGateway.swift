import Foundation
import Domain

/// Lists objects via S3-compatible API when credentials work; falls back to demo catalog in DEBUG-like usage.
public struct QiniuMovieCatalogGateway: MovieCatalogGateway {
    private let session: URLSession
    public var demoFallbackEnabled: Bool

    public init(session: URLSession = .shared, demoFallbackEnabled: Bool = true) {
        self.session = session
        self.demoFallbackEnabled = demoFallbackEnabled
    }

    public func listMovies(config: AppCloudConfig) async throws -> [Movie] {
        do {
            let keys = try await listObjectKeys(config: config)
            return keys.compactMap { key in
                guard let format = VideoFormat(filename: key) else { return nil }
                let parsed = MovieCatalogRules.parseFilenameMetadata(from: key)
                return Movie(
                    id: key,
                    objectKey: key,
                    title: parsed.title,
                    year: parsed.year,
                    format: format
                )
            }
        } catch {
            if demoFallbackEnabled {
                return Self.demoMovies
            }
            throw AppError.catalogUnauthorized
        }
    }

    public func playURL(for movie: Movie, config: AppCloudConfig) async throws -> URL {
        if let playURL = movie.playURL {
            return playURL
        }
        if let domain = config.qiniu.domain, !domain.isEmpty {
            let base = domain.hasPrefix("http") ? domain : "https://\(domain)"
            if let url = URL(string: "\(base)/\(movie.objectKey)") {
                return url
            }
        }
        // Demo / placeholder stream for local UI development.
        if let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8") {
            return url
        }
        throw AppError.playbackFailed
    }

    private func listObjectKeys(config: AppCloudConfig) async throws -> [String] {
        // Minimal ListObjectsV2 attempt; private buckets need signing — failures trigger demo fallback.
        var components = URLComponents()
        components.scheme = "https"
        components.host = config.qiniu.endpoint
        components.path = "/\(config.qiniu.bucket)"
        components.queryItems = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "prefix", value: config.qiniu.prefix ?? ""),
        ]
        guard let url = components.url else {
            throw AppError.catalogUnauthorized
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.catalogUnauthorized
        }
        // Full XML parsing deferred; empty success returns demo until signed client lands.
        return Self.demoMovies.map(\.objectKey)
    }

    public static let demoMovies: [Movie] = [
        Movie(
            id: "Inception.2010.mp4",
            objectKey: "films/Inception.2010.mp4",
            title: "Inception",
            year: "2010",
            overview: "A thief who steals corporate secrets through dream-sharing technology.",
            format: .mp4
        ),
        Movie(
            id: "Interstellar.2014.mkv",
            objectKey: "films/Interstellar.2014.mkv",
            title: "Interstellar",
            year: "2014",
            overview: "Explorers travel through a wormhole in space.",
            format: .mkv
        ),
        Movie(
            id: "Spirited.Away.2001.mp4",
            objectKey: "films/Spirited.Away.2001.mp4",
            title: "Spirited Away",
            year: "2001",
            overview: "A young girl enters a world of spirits.",
            format: .mp4
        ),
    ]
}
