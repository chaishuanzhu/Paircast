import Foundation
import Domain

/// Uploads avatars to `_tandem/avatars/{userId}/{uuid}.jpg` via Qiniu S3 Endpoint.
/// IM stores only the object key; signed GET URLs are minted on login / profile fetch.
public final class QiniuAvatarStorage: AvatarStorageGateway, @unchecked Sendable {
    public static let objectKeyPrefix = AvatarObjectKey.prefix
    /// Qiniu rejects longer query-presign lifetimes (`ErrAuthorizationQuery`).
    public static let sigV4MaxExpiresSeconds = 7 * 24 * 3600
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func uploadAvatar(imageData: Data, userId: String, config: AppCloudConfig) async throws -> String {
        let data = try ProfileRules.validatedAvatarData(imageData)
        guard config.qiniu.isComplete else { throw AppError.notConfigured }

        let safeUser = sanitize(userId)
        let key = "\(Self.objectKeyPrefix)\(safeUser)/\(UUID().uuidString.lowercased()).jpg"
        let objectURL = try objectURL(key: key, config: config)
        try await putObject(data: data, url: objectURL, config: config, contentType: "image/jpeg")
        return key
    }

    public func signedURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        guard config.qiniu.isComplete else { throw AppError.notConfigured }
        let key = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix(Self.objectKeyPrefix) else {
            throw AppError.validation("无效的头像 key")
        }
        let url = try objectURL(key: key, config: config)
        let region = AWSV4Signer.region(fromEndpoint: config.qiniu.endpoint)
        return try AWSV4Signer.presignGET(
            url: url,
            region: region,
            credentials: .init(accessKey: config.qiniu.accessKey, secretKey: config.qiniu.secretKey),
            expires: Self.sigV4MaxExpiresSeconds
        )
    }

    // MARK: - PUT

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
            TandemLog.catalog.error("avatar PUT HTTP \(code, privacy: .public) \(snippet, privacy: .public)")
            throw AppError.avatarUploadFailed
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
        guard let url = components.url else { throw AppError.avatarUploadFailed }
        return url
    }

    private func sanitize(_ userId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let joined = String(filtered)
        return joined.isEmpty ? "user" : String(joined.prefix(64))
    }
}
