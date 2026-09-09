import Foundation

public enum ConfigQRCodec {
    public static let payloadType = "tandem-config"
    public static let maxEncodedUTF8Bytes = 2_048

    public struct Payload: Codable, Equatable, Sendable {
        public var v: Int
        public var type: String
        public var im: IMPayload
        public var storage: StoragePayload
        public var subtitleApiKey: String?
        public var omdbApiKey: String?

        public init(
            v: Int = 2,
            type: String = ConfigQRCodec.payloadType,
            im: IMPayload,
            storage: StoragePayload,
            subtitleApiKey: String? = nil,
            omdbApiKey: String? = nil
        ) {
            self.v = v
            self.type = type
            self.im = im
            self.storage = storage
            self.subtitleApiKey = subtitleApiKey
            self.omdbApiKey = omdbApiKey
        }
    }

    public struct IMPayload: Codable, Equatable, Sendable {
        public var sdkAppId: Int
        public var secretKey: String
        public init(sdkAppId: Int, secretKey: String) {
            self.sdkAppId = sdkAppId
            self.secretKey = secretKey
        }
    }

    public struct StoragePayload: Codable, Equatable, Sendable {
        public var provider: ObjectStorageProvider
        public var accessKey: String
        public var secretKey: String
        public var bucket: String
        public var endpoint: String
        public var region: String?
        public var domain: String?
        public var prefix: String?
        public var useSSL: Bool
        public var forcePathStyle: Bool

        public init(
            provider: ObjectStorageProvider,
            accessKey: String,
            secretKey: String,
            bucket: String,
            endpoint: String,
            region: String? = nil,
            domain: String? = nil,
            prefix: String? = nil,
            useSSL: Bool,
            forcePathStyle: Bool
        ) {
            self.provider = provider
            self.accessKey = accessKey
            self.secretKey = secretKey
            self.bucket = bucket
            self.endpoint = endpoint
            self.region = region
            self.domain = domain
            self.prefix = prefix
            self.useSSL = useSSL
            self.forcePathStyle = forcePathStyle
        }
    }

    public static func encode(_ config: AppCloudConfig) throws -> String {
        let storage = config.storage
        let payload = Payload(
            im: .init(sdkAppId: config.im.sdkAppId, secretKey: config.im.secretKey),
            storage: .init(
                provider: storage.provider,
                accessKey: storage.accessKey,
                secretKey: storage.secretKey,
                bucket: storage.bucket,
                endpoint: storage.endpoint,
                region: storage.region,
                domain: storage.domain,
                prefix: storage.prefix,
                useSSL: storage.useSSL,
                forcePathStyle: storage.forcePathStyle
            ),
            subtitleApiKey: config.subtitleApiKey,
            omdbApiKey: config.omdbApiKey
        )
        let data = try JSONEncoder().encode(payload)
        if data.count > maxEncodedUTF8Bytes {
            throw AppError.configQRTooLarge
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw AppError.invalidConfigQR
        }
        return string
    }

    public static func decode(_ raw: String) throws -> AppCloudConfig {
        guard let data = raw.data(using: .utf8) else {
            throw AppError.invalidConfigQR
        }
        if data.count > maxEncodedUTF8Bytes {
            throw AppError.configQRTooLarge
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw AppError.invalidConfigQR
        }
        guard payload.type == payloadType, payload.v >= 2 else {
            throw AppError.invalidConfigQR
        }
        let config = AppCloudConfig(
            im: IMConfig(sdkAppId: payload.im.sdkAppId, secretKey: payload.im.secretKey),
            storage: ObjectStorageConfig(
                provider: payload.storage.provider,
                accessKey: payload.storage.accessKey,
                secretKey: payload.storage.secretKey,
                bucket: payload.storage.bucket,
                endpoint: payload.storage.endpoint,
                region: payload.storage.region,
                domain: payload.storage.domain,
                prefix: payload.storage.prefix,
                useSSL: payload.storage.useSSL,
                forcePathStyle: payload.storage.forcePathStyle
            ),
            subtitleApiKey: payload.subtitleApiKey,
            omdbApiKey: payload.omdbApiKey,
            configVersion: payload.v
        )
        guard config.isComplete else {
            throw AppError.invalidConfigQR
        }
        return config
    }

    public static func maskedPreview(of config: AppCloudConfig) -> String {
        """
        IM SDKAppID \(maskMiddle(String(config.im.sdkAppId), keepPrefix: 4, keepSuffix: 2))
        IM SecretKey \(maskSecret(config.im.secretKey))
        Storage \(config.storage.provider.displayName)
        AccessKey \(maskMiddle(config.storage.accessKey, keepPrefix: 2, keepSuffix: 0))
        Bucket \(config.storage.bucket)
        Endpoint \(truncate(config.storage.endpoint, max: 18))
        """
    }

    public static func maskedSDKAppId(_ value: Int) -> String {
        maskMiddle(String(value), keepPrefix: 4, keepSuffix: 2)
    }

    public static func maskedAccessKey(_ value: String) -> String {
        maskMiddle(value, keepPrefix: 2, keepSuffix: 0)
    }

    public static func maskSecret(_ value: String) -> String {
        String(repeating: "•", count: min(12, max(8, value.count)))
    }

    public static func truncate(_ value: String, max: Int) -> String {
        guard value.count > max else { return value }
        return String(value.prefix(max - 1)) + "…"
    }

    private static func maskMiddle(_ value: String, keepPrefix: Int, keepSuffix: Int) -> String {
        let chars = Array(value)
        guard chars.count > keepPrefix + keepSuffix else {
            return String(repeating: "•", count: max(4, chars.count))
        }
        let head = String(chars.prefix(keepPrefix))
        let tail = keepSuffix > 0 ? String(chars.suffix(keepSuffix)) : ""
        let hidden = max(4, chars.count - keepPrefix - keepSuffix)
        return head + String(repeating: "•", count: min(hidden, 8)) + tail
    }
}
