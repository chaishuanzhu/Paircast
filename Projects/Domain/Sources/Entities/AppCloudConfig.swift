import Foundation

public struct AppCloudConfig: Equatable, Sendable {
    public var im: IMConfig
    public var qiniu: QiniuConfig
    public var subtitleApiKey: String?
    public var omdbApiKey: String?
    public var userSigExpireSeconds: Int
    public var updatedAt: Date
    public var configVersion: Int

    public init(
        im: IMConfig,
        qiniu: QiniuConfig,
        subtitleApiKey: String? = nil,
        omdbApiKey: String? = nil,
        userSigExpireSeconds: Int = 7 * 24 * 3600,
        updatedAt: Date = Date(),
        configVersion: Int = 1
    ) {
        self.im = im
        self.qiniu = qiniu
        self.subtitleApiKey = subtitleApiKey
        self.omdbApiKey = omdbApiKey
        self.userSigExpireSeconds = userSigExpireSeconds
        self.updatedAt = updatedAt
        self.configVersion = configVersion
    }

    public var isComplete: Bool {
        im.isComplete && qiniu.isComplete
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

public struct QiniuConfig: Equatable, Sendable {
    public var accessKey: String
    public var secretKey: String
    public var bucket: String
    public var endpoint: String
    public var domain: String?
    public var prefix: String?

    public init(
        accessKey: String,
        secretKey: String,
        bucket: String,
        endpoint: String,
        domain: String? = nil,
        prefix: String? = nil
    ) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.bucket = bucket
        self.endpoint = endpoint
        self.domain = domain
        self.prefix = prefix
    }

    public var isComplete: Bool {
        [
            accessKey,
            secretKey,
            bucket,
            endpoint,
        ].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
