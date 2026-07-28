import Foundation
import CommonCrypto
import Domain

/// Minimal TLSSigAPI-compatible HMAC-SHA256 UserSig generator for MVP.
public struct LocalUserSigGateway: UserSigGateway {
    public init() {}

    public func generateUserSig(userId: String, config: AppCloudConfig) throws -> String {
        let sdkAppId = config.im.sdkAppId
        let expire = config.userSigExpireSeconds
        let now = Int(Date().timeIntervalSince1970)
        let content = "TLS.identifier:\(userId)\nTLS.sdkAppID:\(sdkAppId)\nTLS.time:\(now)\nTLS.expire:\(expire)\n"
        let sig = hmacSHA256(key: config.im.secretKey, content: content)
        let payload: [String: Any] = [
            "TLS.ver": "2.0",
            "TLS.identifier": userId,
            "TLS.sdkAppID": sdkAppId,
            "TLS.expire": expire,
            "TLS.time": now,
            "TLS.sig": sig,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "*")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "=", with: "_")
    }

    private func hmacSHA256(key: String, content: String) -> String {
        let keyData = Data(key.utf8)
        let message = Data(content.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            message.withUnsafeBytes { msgBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress,
                    keyData.count,
                    msgBytes.baseAddress,
                    message.count,
                    &digest
                )
            }
        }
        return Data(digest).base64EncodedString()
    }
}
