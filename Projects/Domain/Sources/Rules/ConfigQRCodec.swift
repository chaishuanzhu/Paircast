import Foundation

public enum ConfigQRCodec {
    public static let payloadType = "tandem-config"
    public static let maxEncodedUTF8Bytes = 2_048

    public struct Payload: Codable, Equatable, Sendable {
        public var v: Int
        public var type: String
        public var im: IMPayload
        public var qiniu: QiniuPayload
        public var subtitleApiKey: String?
        public var omdbApiKey: String?

        public init(
            v: Int = 1,
            type: String = ConfigQRCodec.payloadType,
            im: IMPayload,
            qiniu: QiniuPayload,
            subtitleApiKey: String? = nil,
            omdbApiKey: String? = nil
        ) {
            self.v = v
            self.type = type
            self.im = im
            self.qiniu = qiniu
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

    public struct QiniuPayload: Codable, Equatable, Sendable {
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
    }

    public static func encode(_ config: AppCloudConfig) throws -> String {
        let payload = Payload(
            im: .init(sdkAppId: config.im.sdkAppId, secretKey: config.im.secretKey),
            qiniu: .init(
                accessKey: config.qiniu.accessKey,
                secretKey: config.qiniu.secretKey,
                bucket: config.qiniu.bucket,
                endpoint: config.qiniu.endpoint,
                domain: config.qiniu.domain,
                prefix: config.qiniu.prefix
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
        guard payload.type == payloadType, payload.v >= 1 else {
            throw AppError.invalidConfigQR
        }
        let config = AppCloudConfig(
            im: IMConfig(sdkAppId: payload.im.sdkAppId, secretKey: payload.im.secretKey),
            qiniu: QiniuConfig(
                accessKey: payload.qiniu.accessKey,
                secretKey: payload.qiniu.secretKey,
                bucket: payload.qiniu.bucket,
                endpoint: payload.qiniu.endpoint,
                domain: payload.qiniu.domain,
                prefix: payload.qiniu.prefix
            ),
            subtitleApiKey: payload.subtitleApiKey,
            omdbApiKey: payload.omdbApiKey
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
        AccessKey \(maskMiddle(config.qiniu.accessKey, keepPrefix: 2, keepSuffix: 0))
        Bucket \(config.qiniu.bucket)
        Endpoint \(truncate(config.qiniu.endpoint, max: 18))
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
