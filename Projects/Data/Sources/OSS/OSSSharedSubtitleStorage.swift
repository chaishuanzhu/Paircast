import Foundation
import Domain

/// Host-shared subtitles saved beside the movie: `{movieBase}.{srt|vtt|ass}`.
public final class QiniuSharedSubtitleStorage: SharedSubtitleStorageGateway, @unchecked Sendable {
    public static let sigV4MaxExpiresSeconds = QiniuAvatarStorage.sigV4MaxExpiresSeconds
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func upload(
        fileURL: URL,
        roomId: String,
        movieId: String,
        config: AppCloudConfig
    ) async throws -> String {
        guard config.qiniu.isComplete else { throw AppError.notConfigured }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { throw AppError.subtitleShareFailed }

        let ext = SharedSubtitleObjectKey.normalizedExtension(fileURL.pathExtension)
        guard let key = SharedSubtitleObjectKey.sidecarKey(
            movieObjectKey: movieId,
            fileExtension: ext
        ) else {
            throw AppError.subtitleShareFailed
        }

        let objectURL = try objectURL(key: key, config: config)
        try await putObject(
            data: data,
            url: objectURL,
            config: config,
            contentType: contentType(for: ext)
        )
        TandemLog.catalog.info(
            "sidecar subtitle uploaded room=\(roomId, privacy: .public) movie=\(movieId, privacy: .public) key=\(key, privacy: .public)"
        )
        return key
    }

    public func download(objectKey: String, config: AppCloudConfig) async throws -> URL {
        guard config.qiniu.isComplete else { throw AppError.notConfigured }
        let key = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SharedSubtitleObjectKey.isValid(key) else {
            throw AppError.validation("无效的共享字幕 key")
        }
        let remote = try signedGETURL(objectKey: key, config: config)
        let (data, response) = try await session.data(from: remote)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.subtitleUnavailable
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("subtitles/shared", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = SharedSubtitleObjectKey.normalizedExtension((key as NSString).pathExtension)
        let stamp = String(format: "%08x", UInt32(truncatingIfNeeded: data.count) ^ UInt32(truncatingIfNeeded: data.hashValue))
        let local = dir.appendingPathComponent("\(stamp)-\(UUID().uuidString.lowercased()).\(ext)")
        try SubtitleEncodingNormalizer.writeUTF8File(raw: data, to: local)
        return local
    }

    // MARK: - Private

    private func signedGETURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        let url = try objectURL(key: objectKey, config: config)
        let region = AWSV4Signer.region(fromEndpoint: config.qiniu.endpoint)
        return try AWSV4Signer.presignGET(
            url: url,
            region: region,
            credentials: .init(accessKey: config.qiniu.accessKey, secretKey: config.qiniu.secretKey),
            expires: Self.sigV4MaxExpiresSeconds
        )
    }

    private func putObject(data: Data, url: URL, config: AppCloudConfig, contentType: String) async throws {
        let region = AWSV4Signer.region(fromEndpoint: config.qiniu.endpoint)
        let payloadHash = AWSV4Signer.sha256Hex(data)
        let signed = try AWSV4Signer.signHeader(
            method: "PUT",
            url: url,
            region: region,
            credentials: .init(accessKey: config.qiniu.accessKey, secretKey: config.qiniu.secretKey),
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
            let snippet = String(data: responseBody.prefix(400), encoding: .utf8) ?? ""
            TandemLog.catalog.error("sidecar subtitle PUT HTTP \(code, privacy: .public) \(snippet, privacy: .public)")
            throw AppError.subtitleShareFailed
        }
    }

    private func objectURL(key: String, config: AppCloudConfig) throws -> URL {
        let host = AWSV4Signer.normalizedHost(config.qiniu.endpoint)
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = "/" + ([config.qiniu.bucket] + key.split(separator: "/").map(String.init))
            .map { AWSV4Signer.uriEncodePublic($0) }
            .joined(separator: "/")
        guard let url = components.url else { throw AppError.subtitleShareFailed }
        return url
    }

    private func contentType(for ext: String) -> String {
        switch ext {
        case "vtt":
            return "text/vtt"
        case "ass", "ssa":
            return "text/x-ssa"
        default:
            return "application/x-subrip"
        }
    }
}
