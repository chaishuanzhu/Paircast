import Foundation
import CommonCrypto
import zlib
import Domain

/// TLSSigAPIv2 HMAC-SHA256 UserSig (matches Tencent GenerateTestUserSig / official client demo).
/// Debug/MVP only — SecretKey on device; production should move signing to a BFF.
public struct LocalUserSigGateway: UserSigGateway {
    public init() {}

    public func generateUserSig(userId: String, config: AppCloudConfig) throws -> String {
        let sdkAppId = config.im.sdkAppId
        let expire = config.userSigExpireSeconds
        let tlsTime = Int(Date().timeIntervalSince1970)

        var obj: [String: Any] = [
            "TLS.ver": "2.0",
            "TLS.identifier": userId,
            "TLS.sdkappid": sdkAppId,
            "TLS.expire": expire,
            "TLS.time": tlsTime,
        ]

        // Sign these fields in this exact order (official TLSSigAPIv2).
        let keyOrder = ["TLS.identifier", "TLS.sdkappid", "TLS.time", "TLS.expire"]
        var stringToSign = ""
        for key in keyOrder {
            if let value = obj[key] {
                stringToSign += "\(key):\(value)\n"
            }
        }

        guard let sig = hmacSHA256Base64(plainText: stringToSign, secretKey: config.im.secretKey) else {
            throw AppError.imInitFailed
        }
        obj["TLS.sig"] = sig

        guard let jsonData = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            throw AppError.imInitFailed
        }
        guard let compressed = zlibCompress(jsonData) else {
            throw AppError.imInitFailed
        }
        return base64URL(compressed)
    }

    // MARK: - TLSSigAPIv2 helpers

    private func hmacSHA256Base64(plainText: String, secretKey: String) -> String? {
        // Official demo uses ASCII for both key and message.
        guard let cKey = secretKey.cString(using: .ascii),
              let cData = plainText.cString(using: .ascii) else {
            return nil
        }
        let cKeyLen = secretKey.lengthOfBytes(using: .ascii)
        let cDataLen = plainText.lengthOfBytes(using: .ascii)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBufferPointer { buffer in
            CCHmac(
                CCHmacAlgorithm(kCCHmacAlgSHA256),
                cKey,
                cKeyLen,
                cData,
                cDataLen,
                buffer.baseAddress
            )
        }
        return Data(digest).base64EncodedString()
    }

    private func zlibCompress(_ data: Data) -> Data? {
        let srcLen = uLongf(data.count)
        let bound = compressBound(srcLen)
        var destLen = bound
        var dest = Data(count: Int(bound))
        let result: Int32 = dest.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                guard let destBase = destPtr.bindMemory(to: Bytef.self).baseAddress,
                      let srcBase = srcPtr.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_BUF_ERROR
                }
                return compress2(destBase, &destLen, srcBase, srcLen, Z_BEST_SPEED)
            }
        }
        guard result == Z_OK else { return nil }
        dest.count = Int(destLen)
        return dest
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "*")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "=", with: "_")
    }
}
