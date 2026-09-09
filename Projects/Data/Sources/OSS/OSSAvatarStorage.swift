import Foundation
import Domain

/// Uploads avatars to `_tandem/avatars/{userId}/{uuid}.jpg` via S3-compatible Endpoint.
/// IM stores only the object key; signed GET URLs are minted on login / profile fetch.
public final class OSSAvatarStorage: AvatarStorageGateway, @unchecked Sendable {
    public static let objectKeyPrefix = AvatarObjectKey.prefix
    /// Some providers reject longer query-presign lifetimes (`ErrAuthorizationQuery`).
    public static let sigV4MaxExpiresSeconds = 7 * 24 * 3600
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func uploadAvatar(imageData: Data, userId: String, config: AppCloudConfig) async throws -> String {
        let data = try ProfileRules.validatedAvatarData(imageData)
        guard config.storage.isComplete else { throw AppError.notConfigured }

        let safeUser = sanitize(userId)
        let key = "\(Self.objectKeyPrefix)\(safeUser)/\(UUID().uuidString.lowercased()).jpg"
        let objectURL = try objectURL(key: key, config: config)
        try await putObject(data: data, url: objectURL, config: config, contentType: "image/jpeg")
        return key
    }

    public func signedURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        guard config.storage.isComplete else { throw AppError.notConfigured }
        let key = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix(Self.objectKeyPrefix) else {
            throw AppError.validation("无效的头像 key")
        }
        let url = try objectURL(key: key, config: config)
        let region = config.storage.signingRegion
        return try AWSV4Signer.presignGET(
            url: url,
            region: region,
            credentials: S3CompatibleURL.credentials(config.storage),
            expires: Self.sigV4MaxExpiresSeconds
        )
    }

    public func deleteAvatar(objectKey: String, config: AppCloudConfig) async throws {
        guard config.storage.isComplete else { throw AppError.notConfigured }
        let key = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix(Self.objectKeyPrefix) else { return }
        let url = try objectURL(key: key, config: config)
        let region = config.storage.signingRegion
        let signed = try AWSV4Signer.signHeader(
            method: "DELETE",
            url: url,
            region: region,
            credentials: S3CompatibleURL.credentials(config.storage)
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        request.timeoutInterval = 20
        for (header, value) in signed.headers where header.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.network }
        guard http.statusCode == 404 || (200..<300).contains(http.statusCode) else {
            TandemLog.catalog.error("avatar DELETE HTTP \(http.statusCode, privacy: .public)")
            throw AppError.network
        }
    }

    // MARK: - PUT

    private func putObject(data: Data, url: URL, config: AppCloudConfig, contentType: String) async throws {
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
            let snippet = String(data: responseBody.prefix(400), encoding: .utf8) ?? ""
            TandemLog.catalog.error("avatar PUT HTTP \(code, privacy: .public) \(snippet, privacy: .public)")
            throw AppError.avatarUploadFailed
        }
    }

    private func objectURL(key: String, config: AppCloudConfig) throws -> URL {
        try S3CompatibleURL.objectURL(objectKey: key, storage: config.storage)
    }

    private func sanitize(_ userId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let joined = String(filtered)
        return joined.isEmpty ? "user" : String(joined.prefix(64))
    }
}
