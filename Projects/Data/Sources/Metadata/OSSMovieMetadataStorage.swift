import Foundation
import Domain

/// Persists scraped metadata beside the movie in object storage:
/// `{base}.nfo`, `{base}-poster.jpg`, `{base}-fanart.jpg`.
public final class OSSMovieMetadataStorage: MovieMetadataStorageGateway, @unchecked Sendable {
    public static let sigV4MaxExpiresSeconds = OSSAvatarStorage.sigV4MaxExpiresSeconds
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func load(for movie: Movie, config: AppCloudConfig) async -> Movie? {
        guard config.storage.isComplete else { return nil }
        guard let nfoKey = MovieMetadataObjectKey.nfoKey(for: movie.objectKey) else { return nil }

        guard let nfoData = try? await getObject(objectKey: nfoKey, config: config),
              let payload = MovieNFOCodec.decode(nfoData) else {
            return nil
        }

        var result = movie
        result.title = payload.title
        if let year = payload.year, !year.isEmpty { result.year = year }
        if let overview = payload.overview, !overview.isEmpty { result.overview = overview }

        let posterKey = MovieMetadataObjectKey.posterKey(for: movie.objectKey)
            ?? directoryJoined(movieObjectKey: movie.objectKey, fileName: payload.posterFileName)
        let fanartKey = MovieMetadataObjectKey.fanartKey(for: movie.objectKey)
            ?? directoryJoined(movieObjectKey: movie.objectKey, fileName: payload.fanartFileName)

        if let posterKey, await objectExists(objectKey: posterKey, config: config) {
            result.posterURL = try? signedGETURL(objectKey: posterKey, config: config)
        }
        if let fanartKey, await objectExists(objectKey: fanartKey, config: config) {
            result.backdropURL = try? signedGETURL(objectKey: fanartKey, config: config)
        }

        PaircastLog.catalog.info(
            "metadata oss hit movie=\(movie.objectKey, privacy: .public) title=\(result.title, privacy: .public) poster=\(result.posterURL != nil, privacy: .public) fanart=\(result.backdropURL != nil, privacy: .public)"
        )
        return result
    }

    public func save(_ movie: Movie, config: AppCloudConfig) async -> Movie {
        guard config.storage.isComplete else { return movie }
        guard let nfoKey = MovieMetadataObjectKey.nfoKey(for: movie.objectKey),
              let posterKey = MovieMetadataObjectKey.posterKey(for: movie.objectKey),
              let fanartKey = MovieMetadataObjectKey.fanartKey(for: movie.objectKey) else {
            return movie
        }

        var result = movie
        let posterLeaf = (posterKey as NSString).lastPathComponent
        let fanartLeaf = (fanartKey as NSString).lastPathComponent

        // Upload art first so NFO can reference local filenames.
        var posterBytes: Data?
        var posterContentType = "image/jpeg"
        if let remotePoster = movie.posterURL {
            if let downloaded = await downloadImage(from: remotePoster) {
                posterBytes = downloaded.data
                posterContentType = downloaded.contentType
                do {
                    try await putObject(
                        data: downloaded.data,
                        objectKey: posterKey,
                        config: config,
                        contentType: downloaded.contentType
                    )
                    result.posterURL = try signedGETURL(objectKey: posterKey, config: config)
                } catch {
                    PaircastLog.catalog.error(
                        "metadata poster upload failed key=\(posterKey, privacy: .public)"
                    )
                }
            }
        }

        if let remoteFanart = movie.backdropURL,
           remoteFanart != movie.posterURL {
            if let uploaded = await uploadImage(from: remoteFanart, objectKey: fanartKey, config: config) {
                result.backdropURL = uploaded
            }
        } else if let posterBytes {
            // No distinct backdrop from scrape — reuse poster as fanart sidecar.
            do {
                try await putObject(
                    data: posterBytes,
                    objectKey: fanartKey,
                    config: config,
                    contentType: posterContentType
                )
                result.backdropURL = try signedGETURL(objectKey: fanartKey, config: config)
            } catch {
                PaircastLog.catalog.error(
                    "metadata fanart upload failed key=\(fanartKey, privacy: .public)"
                )
            }
        }

        let hasLocalPoster = await objectExists(objectKey: posterKey, config: config)
        let hasLocalFanart = await objectExists(objectKey: fanartKey, config: config)
        let payload = MovieNFOCodec.Payload(
            title: result.title,
            year: result.year,
            overview: result.overview,
            posterFileName: hasLocalPoster ? posterLeaf : nil,
            fanartFileName: hasLocalFanart ? fanartLeaf : nil
        )
        do {
            try await putObject(
                data: MovieNFOCodec.encode(payload),
                objectKey: nfoKey,
                config: config,
                contentType: "application/xml; charset=utf-8"
            )
            if hasLocalPoster {
                result.posterURL = try? signedGETURL(objectKey: posterKey, config: config)
            }
            if hasLocalFanart {
                result.backdropURL = try? signedGETURL(objectKey: fanartKey, config: config)
            }
            PaircastLog.catalog.info(
                "metadata oss saved movie=\(movie.objectKey, privacy: .public) nfo=\(nfoKey, privacy: .public)"
            )
        } catch {
            PaircastLog.catalog.error(
                "metadata oss save failed movie=\(movie.objectKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
        return result
    }

    // MARK: - Art upload

    private func uploadImage(from remote: URL, objectKey: String, config: AppCloudConfig) async -> URL? {
        guard let downloaded = await downloadImage(from: remote) else { return nil }
        do {
            try await putObject(
                data: downloaded.data,
                objectKey: objectKey,
                config: config,
                contentType: downloaded.contentType
            )
            return try signedGETURL(objectKey: objectKey, config: config)
        } catch {
            PaircastLog.catalog.error(
                "metadata art upload failed key=\(objectKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private func downloadImage(from remote: URL) async -> (data: Data, contentType: String)? {
        do {
            var request = URLRequest(url: remote)
            request.timeoutInterval = 30
            if let host = remote.host?.lowercased(),
               host.contains("doubanio.com") || host.contains("douban.com") {
                request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
                request.setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                    forHTTPHeaderField: "User-Agent"
                )
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                return nil
            }
            let rawType = http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
            let contentType = rawType.contains("image") ? rawType : "image/jpeg"
            return (data, contentType)
        } catch {
            PaircastLog.catalog.error(
                "metadata art download failed error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - S3 helpers

    private func getObject(objectKey: String, config: AppCloudConfig) async throws -> Data {
        let url = try signedGETURL(objectKey: objectKey, config: config)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.network
        }
        return data
    }

    private func objectExists(objectKey: String, config: AppCloudConfig) async -> Bool {
        do {
            let objectURL = try makeObjectURL(objectKey: objectKey, config: config)
            let region = config.storage.signingRegion
            let signed = try AWSV4Signer.signHeader(
                method: "HEAD",
                url: objectURL,
                region: region,
                credentials: S3CompatibleURL.credentials(config.storage)
            )
            var request = URLRequest(url: signed.url)
            request.httpMethod = "HEAD"
            for (key, value) in signed.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func putObject(
        data: Data,
        objectKey: String,
        config: AppCloudConfig,
        contentType: String
    ) async throws {
        let url = try makeObjectURL(objectKey: objectKey, config: config)
        let region = config.storage.signingRegion
        let payloadHash = AWSV4Signer.sha256Hex(data)
        let signed = try AWSV4Signer.signHeader(
            method: "PUT",
            url: url,
            region: region,
            credentials: S3CompatibleURL.credentials(config.storage),
            headers: ["content-type": contentType],
            payloadHash: payloadHash
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        request.httpBody = data
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 60
        for (key, value) in signed.headers where key.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (responseBody, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: responseBody.prefix(200), encoding: .utf8) ?? ""
            PaircastLog.catalog.error("metadata PUT HTTP \(code, privacy: .public) \(snippet, privacy: .public)")
            throw AppError.network
        }
    }

    private func signedGETURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        let url = try makeObjectURL(objectKey: objectKey, config: config)
        let region = config.storage.signingRegion
        return try AWSV4Signer.presignGET(
            url: url,
            region: region,
            credentials: S3CompatibleURL.credentials(config.storage),
            expires: Self.sigV4MaxExpiresSeconds
        )
    }

    private func makeObjectURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        try S3CompatibleURL.objectURL(objectKey: objectKey, storage: config.storage)
    }

    private func directoryJoined(movieObjectKey: String, fileName: String?) -> String? {
        guard let fileName, !fileName.isEmpty else { return nil }
        if fileName.contains("/") { return fileName }
        let parent = (movieObjectKey as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." { return fileName }
        return parent + "/" + fileName
    }
}
