import Foundation

public enum ProfileRules {
    public static let nicknameMinLength = 1
    public static let nicknameMaxLength = 16
    public static let avatarMaxBytes = 1_048_576

    public static func validatedNickname(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.validation("昵称不能为空")
        }
        guard trimmed.count <= nicknameMaxLength else {
            throw AppError.validation("昵称最多 \(nicknameMaxLength) 字")
        }
        return trimmed
    }

    public static func validatedAvatarData(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw AppError.validation("请选择头像图片")
        }
        guard data.count <= avatarMaxBytes else {
            throw AppError.validation("头像需压缩到 1MB 以内")
        }
        return data
    }
}

public enum LoginRules {
    public static func validateCredentials(userId: String, password: String) throws {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw AppError.validation("请输入用户名")
        }
        // Scheme A: password only needs to be non-empty; real auth is IM login.
        guard !password.isEmpty else {
            throw AppError.validation("请输入密码")
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
        if config.qiniu.accessKey.isEmpty { missing.append("七牛 AccessKey") }
        if config.qiniu.secretKey.isEmpty { missing.append("七牛 SecretKey") }
        if config.qiniu.bucket.isEmpty { missing.append("七牛 Bucket") }
        if config.qiniu.endpoint.isEmpty { missing.append("七牛 Endpoint") }
        return missing
    }

    public static func validate(_ config: AppCloudConfig) throws {
        let missing = missingFields(in: config)
        if !missing.isEmpty {
            throw AppError.incompleteConfig(missing: missing)
        }
        _ = try normalizedQiniu(config.qiniu)
    }

    /// Strips schemes/paths and enforces Endpoint = S3 API host, Domain = CDN host only.
    public static func normalized(_ config: AppCloudConfig) throws -> AppCloudConfig {
        try validate(config)
        let qiniu = try normalizedQiniu(config.qiniu)
        return AppCloudConfig(
            im: config.im,
            qiniu: qiniu,
            subtitleApiKey: config.subtitleApiKey,
            omdbApiKey: config.omdbApiKey,
            userSigExpireSeconds: config.userSigExpireSeconds,
            updatedAt: config.updatedAt,
            configVersion: config.configVersion
        )
    }

    public static func normalizedQiniu(_ qiniu: QiniuConfig) throws -> QiniuConfig {
        let endpoint = try validatedEndpoint(qiniu.endpoint)
        let domain = try validatedDomain(qiniu.domain)
        return QiniuConfig(
            accessKey: qiniu.accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: qiniu.secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: qiniu.bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint,
            domain: domain,
            prefix: normalizedPrefix(qiniu.prefix)
        )
    }

    /// Host only: `https://s3.cn-south-1.qiniucs.com/path` → `s3.cn-south-1.qiniucs.com`
    public static func normalizedHost(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "http://", with: "", options: [.caseInsensitive])
            .split(separator: "/")
            .first
            .map(String.init) ?? ""
    }

    public static func isQiniuS3APIHost(_ host: String) -> Bool {
        let h = normalizedHost(host).lowercased()
        guard h.contains("qiniucs.com") else { return false }
        return h.hasPrefix("s3.") || h.hasPrefix("s3-")
    }

    public static func validatedEndpoint(_ raw: String) throws -> String {
        let host = normalizedHost(raw)
        guard !host.isEmpty else {
            throw AppError.incompleteConfig(missing: ["七牛 Endpoint"])
        }
        guard isQiniuS3APIHost(host) else {
            throw AppError.validation(
                "Endpoint 需为七牛 S3 地址（如 s3.cn-south-1.qiniucs.com）。自定义域名请填到「自定义域名」，填错会导致片库列表无法加载"
            )
        }
        return host
    }

    public static func validatedDomain(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let host = normalizedHost(raw)
        guard !host.isEmpty else { return nil }
        if isQiniuS3APIHost(host) {
            throw AppError.validation("自定义域名不能填写 S3 Endpoint，请填写已绑定的 CDN 域名（如 qiniu.example.com）")
        }
        return host
    }

    private static func normalizedPrefix(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
