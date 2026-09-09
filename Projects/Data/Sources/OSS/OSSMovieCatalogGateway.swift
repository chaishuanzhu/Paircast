import Foundation
import Domain

/// S3-compatible object storage via ListObjectsV2 + SigV4 (with pagination).
public struct OSSMovieCatalogGateway: MovieCatalogGateway {
    private let session: URLSession
    private let presignExpires: Int
    private let maxKeysPerPage: Int
    private let maxPages: Int

    /// Default play URL lifetime: 6 hours (AWS SigV4 `X-Amz-Expires`).
    public static let defaultPresignExpiresSeconds = 6 * 3600

    public init(
        session: URLSession = .shared,
        presignExpires: Int = Self.defaultPresignExpiresSeconds,
        maxKeysPerPage: Int = 1000,
        maxPages: Int = 50
    ) {
        self.session = session
        self.presignExpires = presignExpires
        self.maxKeysPerPage = maxKeysPerPage
        self.maxPages = maxPages
    }

    public func listMovies(config: AppCloudConfig) async throws -> [Movie] {
        let host = AWSV4Signer.normalizedHost(config.storage.endpoint)
        let region = config.storage.signingRegion
        TandemLog.catalog.info(
            "listMovies begin bucket=\(config.storage.bucket, privacy: .public) host=\(host, privacy: .public) region=\(region, privacy: .public) prefix=\(config.storage.prefix ?? "", privacy: .public) provider=\(config.storage.provider.rawValue, privacy: .public)"
        )
        do {
            let keys = try await listAllObjectKeys(config: config)
            let movies = keys.compactMap { key -> Movie? in
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
            TandemLog.catalog.info(
                "listMovies done objects=\(keys.count, privacy: .public) videos=\(movies.count, privacy: .public)"
            )
            return movies
        } catch {
            TandemLog.catalog.error("listMovies failed error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func playURL(for movie: Movie, config: AppCloudConfig) async throws -> URL {
        if let playURL = movie.playURL {
            TandemLog.catalog.info(
                "playURL using embedded url movie=\(movie.objectKey, privacy: .public) \(TandemLog.redactedURL(playURL), privacy: .public)"
            )
            return playURL
        }
        // Always AWS SigV4 query-presign against the S3 endpoint (private bucket).
        do {
            let url = try makePresignedGetURL(objectKey: movie.objectKey, config: config)
            TandemLog.catalog.info(
                "playURL presigned expires=\(self.presignExpires, privacy: .public)s movie=\(movie.objectKey, privacy: .public) \(TandemLog.redactedURL(url), privacy: .public)"
            )
            return url
        } catch {
            TandemLog.catalog.error(
                "playURL presign failed movie=\(movie.objectKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Paginated list

    private func listAllObjectKeys(config: AppCloudConfig) async throws -> [String] {
        var allKeys: [String] = []
        var continuationToken: String?
        var pageCount = 0

        repeat {
            try Task.checkCancellation()
            pageCount += 1
            if pageCount > maxPages {
                break
            }
            let page = try await listObjectKeysPage(config: config, continuationToken: continuationToken)
            allKeys.append(contentsOf: page.keys)
            TandemLog.catalog.debug(
                "listObjects page=\(pageCount, privacy: .public) keys=\(page.keys.count, privacy: .public) truncated=\(page.isTruncated, privacy: .public)"
            )
            if page.isTruncated, let next = page.nextContinuationToken, !next.isEmpty {
                continuationToken = next
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil

        return allKeys
    }

    private func listObjectKeysPage(
        config: AppCloudConfig,
        continuationToken: String?
    ) async throws -> S3ListObjectsV2Page {
        let region = config.storage.signingRegion
        let credentials = S3CompatibleURL.credentials(config.storage)

        var components = URLComponents(url: try S3CompatibleURL.bucketURL(storage: config.storage), resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: String(maxKeysPerPage)),
        ]
        if let prefix = config.storage.prefix, !prefix.isEmpty {
            query.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let continuationToken, !continuationToken.isEmpty {
            query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
        }
        components?.queryItems = query

        guard let url = components?.url else {
            throw AppError.catalogUnauthorized
        }

        let signed = try AWSV4Signer.signHeader(
            method: "GET",
            url: url,
            region: region,
            credentials: credentials
        )

        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        request.timeoutInterval = 30
        for (key, value) in signed.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AppError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.catalogUnauthorized
        }

        if !(200..<300).contains(http.statusCode) {
            TandemLog.catalog.error(
                "listObjects HTTP \(http.statusCode, privacy: .public) \(TandemLog.redactedURL(signed.url), privacy: .public)"
            )
            throw mapListFailure(data: data, statusCode: http.statusCode)
        }

        do {
            return try S3ListObjectsV2Parser.parsePage(from: data)
        } catch S3ListObjectsV2Parser.ParseError.errorResponse(let code, let message) {
            throw mapS3Error(code: code, message: message)
        } catch {
            throw AppError.unknown("Failed to parse listing")
        }
    }

    private func makeObjectURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        try S3CompatibleURL.objectURL(objectKey: objectKey, storage: config.storage)
    }

    private func makePresignedGetURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        let region = config.storage.signingRegion
        let url = try makeObjectURL(objectKey: objectKey, config: config)
        do {
            return try AWSV4Signer.presignGET(
                url: url,
                region: region,
                credentials: S3CompatibleURL.credentials(config.storage),
                expires: presignExpires
            )
        } catch {
            throw AppError.playbackFailed
        }
    }

    private func mapListFailure(data: Data, statusCode: Int) -> AppError {
        do {
            _ = try S3ListObjectsV2Parser.parsePage(from: data)
        } catch S3ListObjectsV2Parser.ParseError.errorResponse(let code, let message) {
            return mapS3Error(code: code, message: message)
        } catch {
            // fall through
        }
        if statusCode == 403 || statusCode == 401 {
            return .catalogUnauthorized
        }
        return .unknown("Failed to list objects (HTTP \(statusCode))")
    }

    private func mapS3Error(code: String, message: String) -> AppError {
        switch code {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "AccessDenied", "InvalidToken":
            return .catalogUnauthorized
        case "NoSuchBucket":
            return .incompleteConfig(missing: ["Bucket"])
        default:
            return .unknown("Object storage: \(code) — \(message)")
        }
    }
}

extension AWSV4Signer {
    public static func uriEncodePublic(_ string: String) -> String {
        uriEncode(string, encodeSlash: true)
    }
}
