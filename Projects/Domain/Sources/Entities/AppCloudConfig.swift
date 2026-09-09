import Foundation

public struct AppCloudConfig: Equatable, Sendable {
    public var im: IMConfig
    public var storage: ObjectStorageConfig
    public var subtitleApiKey: String?
    public var omdbApiKey: String?
    public var userSigExpireSeconds: Int
    public var updatedAt: Date
    public var configVersion: Int

    public init(
        im: IMConfig,
        storage: ObjectStorageConfig,
        subtitleApiKey: String? = nil,
        omdbApiKey: String? = nil,
        userSigExpireSeconds: Int = 7 * 24 * 3600,
        updatedAt: Date = Date(),
        configVersion: Int = 2
    ) {
        self.im = im
        self.storage = storage
        self.subtitleApiKey = subtitleApiKey
        self.omdbApiKey = omdbApiKey
        self.userSigExpireSeconds = userSigExpireSeconds
        self.updatedAt = updatedAt
        self.configVersion = configVersion
    }

    public var isComplete: Bool {
        im.isComplete && storage.isComplete
    }
}

public struct IMConfig: Equatable, Sendable {
    public var sdkAppId: Int
    public var secretKey: String

    public init(sdkAppId: Int, secretKey: String) {
        self.sdkAppId = sdkAppId
        self.secretKey = secretKey
    }

    public var isComplete: Bool {
        sdkAppId > 0 && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var maskedSummary: String {
        let id = String(sdkAppId)
        let suffix = id.suffix(4)
        return "IM AppID …\(suffix)"
    }
}

public enum ObjectStorageProvider: String, Codable, CaseIterable, Sendable {
    case qiniu
    case aliyunOSS
    case tencentCOS
    case minio

    public var displayName: String {
        switch self {
        case .qiniu: return "七牛云"
        case .aliyunOSS: return "阿里云 OSS"
        case .tencentCOS: return "腾讯云 COS"
        case .minio: return "MinIO"
        }
    }

    public var endpointPlaceholder: String {
        switch self {
        case .qiniu: return "s3.cn-south-1.qiniucs.com"
        case .aliyunOSS: return "oss-cn-hangzhou.aliyuncs.com"
        case .tencentCOS: return "cos.ap-guangzhou.myqcloud.com"
        case .minio: return "192.168.1.10:9000"
        }
    }

    public var regionPlaceholder: String {
        switch self {
        case .qiniu: return "cn-south-1"
        case .aliyunOSS: return "cn-hangzhou"
        case .tencentCOS: return "ap-guangzhou"
        case .minio: return "us-east-1"
        }
    }

    public var defaultUseSSL: Bool {
        self != .minio
    }

    public var defaultForcePathStyle: Bool { true }

    public var defaultRegion: String? {
        switch self {
        case .minio: return "us-east-1"
        case .qiniu, .aliyunOSS, .tencentCOS: return nil
        }
    }
}

public struct ObjectStorageConfig: Equatable, Sendable {
    public var provider: ObjectStorageProvider
    public var accessKey: String
    public var secretKey: String
    public var bucket: String
    /// API host, optionally with port (`minio.local:9000`). No scheme/path.
    public var endpoint: String
    public var region: String?
    public var domain: String?
    public var prefix: String?
    public var useSSL: Bool
    public var forcePathStyle: Bool

    public init(
        provider: ObjectStorageProvider = .qiniu,
        accessKey: String,
        secretKey: String,
        bucket: String,
        endpoint: String,
        region: String? = nil,
        domain: String? = nil,
        prefix: String? = nil,
        useSSL: Bool? = nil,
        forcePathStyle: Bool? = nil
    ) {
        self.provider = provider
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.bucket = bucket
        self.endpoint = endpoint
        self.region = region
        self.domain = domain
        self.prefix = prefix
        self.useSSL = useSSL ?? provider.defaultUseSSL
        self.forcePathStyle = forcePathStyle ?? provider.defaultForcePathStyle
    }

    public var isComplete: Bool {
        [
            accessKey,
            secretKey,
            bucket,
            endpoint,
        ].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Region used for AWS SigV4. Explicit config wins; otherwise infer from endpoint / provider.
    public var signingRegion: String {
        if let region, !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return region.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.inferredRegion(provider: provider, endpoint: endpoint)
    }

    public static func inferredRegion(provider: ObjectStorageProvider, endpoint: String) -> String {
        let host = ConfigValidation.normalizedHost(endpoint).lowercased()
        switch provider {
        case .qiniu:
            if let match = host.firstMatch(of: /^s3[.-]([a-z0-9-]+)\./) {
                return String(match.1)
            }
            return "cn-east-1"
        case .aliyunOSS:
            if let match = host.firstMatch(of: /^oss-([a-z0-9-]+)\./) {
                return String(match.1)
            }
            return "cn-hangzhou"
        case .tencentCOS:
            if let match = host.firstMatch(of: /^cos\.([a-z0-9-]+)\./) {
                return String(match.1)
            }
            return "ap-guangzhou"
        case .minio:
            return "us-east-1"
        }
    }
}
