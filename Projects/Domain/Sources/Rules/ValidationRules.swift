import Foundation

public enum ProfileRules {
    public static let nicknameMinLength = 1
    public static let nicknameMaxLength = 16
    public static let avatarMaxBytes = 1_048_576

    public static func validatedNickname(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.validation("Nickname cannot be empty")
        }
        guard trimmed.count <= nicknameMaxLength else {
            throw AppError.validation(
                "Nickname can be at most {{count}} characters",
                args: ["count": "\(nicknameMaxLength)"]
            )
        }
        return trimmed
    }

    public static func validatedAvatarData(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw AppError.validation("Please choose a profile photo")
        }
        guard data.count <= avatarMaxBytes else {
            throw AppError.validation("Avatar must be under 1 MB after compression")
        }
        return data
    }
}

public enum LoginRules {
    public static func validateUserId(_ userId: String) throws {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw AppError.validation("Please enter a user ID")
        }
    }
}

public enum ConfigValidation {
    public static func missingFields(in config: AppCloudConfig) -> [String] {
        var missing: [String] = []
        if config.im.sdkAppId <= 0 { missing.append("IM SDKAppID") }
        if config.im.secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("IM SecretKey")
        }
        let label = config.storage.provider.displayName
        if config.storage.accessKey.isEmpty { missing.append("\(label) AccessKey") }
        if config.storage.secretKey.isEmpty { missing.append("\(label) SecretKey") }
        if config.storage.bucket.isEmpty { missing.append("\(label) Bucket") }
        if config.storage.endpoint.isEmpty { missing.append("\(label) Endpoint") }
        return missing
    }

    public static func validate(_ config: AppCloudConfig) throws {
        let missing = missingFields(in: config)
        if !missing.isEmpty {
            throw AppError.incompleteConfig(missing: missing)
        }
        _ = try normalizedStorage(config.storage)
    }

    public static func normalized(_ config: AppCloudConfig) throws -> AppCloudConfig {
        try validate(config)
        return AppCloudConfig(
            im: config.im,
            storage: try normalizedStorage(config.storage),
            subtitleApiKey: config.subtitleApiKey,
            omdbApiKey: config.omdbApiKey,
            userSigExpireSeconds: config.userSigExpireSeconds,
            updatedAt: config.updatedAt,
            configVersion: config.configVersion
        )
    }

    public static func normalizedStorage(_ storage: ObjectStorageConfig) throws -> ObjectStorageConfig {
        let endpoint = try validatedEndpoint(storage.endpoint, provider: storage.provider)
        let domain = try validatedDomain(storage.domain, provider: storage.provider)
        let region = storage.region?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ObjectStorageConfig(
            provider: storage.provider,
            accessKey: storage.accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: storage.secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: storage.bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint,
            region: (region?.isEmpty == false) ? region : storage.provider.defaultRegion,
            domain: domain,
            prefix: normalizedPrefix(storage.prefix),
            useSSL: storage.useSSL,
            forcePathStyle: storage.forcePathStyle
        )
    }

    /// Host (+ optional port): `https://s3.cn-south-1.qiniucs.com/path` → `s3.cn-south-1.qiniucs.com`
    public static func normalizedHost(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "http://", with: "", options: [.caseInsensitive])
            .split(separator: "/")
            .first
            .map(String.init) ?? ""
    }

    public static func isAPIEndpointHost(_ host: String, provider: ObjectStorageProvider) -> Bool {
        let h = normalizedHost(host).lowercased()
        switch provider {
        case .qiniu:
            guard h.contains("qiniucs.com") else { return false }
            return h.hasPrefix("s3.") || h.hasPrefix("s3-")
        case .aliyunOSS:
            return h.contains("aliyuncs.com") && h.hasPrefix("oss-")
        case .tencentCOS:
            return h.contains("myqcloud.com") && h.hasPrefix("cos.")
        case .minio:
            return !h.isEmpty
        }
    }

    public static func validatedEndpoint(_ raw: String, provider: ObjectStorageProvider) throws -> String {
        let host = normalizedHost(raw)
        guard !host.isEmpty else {
            throw AppError.incompleteConfig(missing: ["\(provider.displayName) Endpoint"])
        }
        guard isAPIEndpointHost(host, provider: provider) else {
            throw AppError.validation(endpointHint(for: provider), args: endpointHintArgs(for: provider))
        }
        return host
    }

    public static func validatedDomain(_ raw: String?, provider: ObjectStorageProvider) throws -> String? {
        guard let raw else { return nil }
        let host = normalizedHost(raw)
        guard !host.isEmpty else { return nil }
        if isAPIEndpointHost(host, provider: provider) {
            throw AppError.validation("Custom domain cannot be an API endpoint. Use a CDN or public domain")
        }
        return host
    }

    private static func endpointHint(for provider: ObjectStorageProvider) -> String {
        switch provider {
        case .qiniu:
            return "Endpoint must be a Qiniu S3 host (e.g. {{example}})"
        case .aliyunOSS:
            return "Endpoint must be an Alibaba Cloud OSS host (e.g. {{example}})"
        case .tencentCOS:
            return "Endpoint must be a Tencent Cloud COS host (e.g. {{example}})"
        case .minio:
            return "Endpoint must be a MinIO host (e.g. {{example}})"
        }
    }

    private static func endpointHintArgs(for provider: ObjectStorageProvider) -> [String: String] {
        ["example": provider.endpointPlaceholder]
    }

    private static func normalizedPrefix(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
