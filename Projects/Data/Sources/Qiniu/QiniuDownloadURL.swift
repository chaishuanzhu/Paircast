import Foundation
import CryptoKit
import Domain

/// Qiniu private download URL (`e` + `token`) — supports long deadlines (e.g. 1 year).
public enum QiniuDownloadURL {
    public static let oneYearSeconds: Int = 365 * 24 * 3600

    public static func signedURL(
        resourceURL: URL,
        accessKey: String,
        secretKey: String,
        expiresInSeconds: Int = oneYearSeconds,
        now: Date = Date()
    ) throws -> URL {
        let deadline = Int(now.timeIntervalSince1970) + max(60, expiresInSeconds)
        var base = resourceURL.absoluteString
        if base.hasSuffix("?") {
            base.removeLast()
        }
        let separator = base.contains("?") ? "&" : "?"
        let urlWithDeadline = "\(base)\(separator)e=\(deadline)"
        let digest = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(urlWithDeadline.utf8),
            using: SymmetricKey(data: Data(secretKey.utf8))
        )
        let encodedSign = urlSafeBase64(Data(digest))
        let token = "\(accessKey):\(encodedSign)"
        // Keep token unescaped (`:` / `=`): Qiniu verifies against the literal URL string,
        // matching official SDK `private_download_url` concatenation.
        guard let signed = URL(string: "\(urlWithDeadline)&token=\(token)") else {
            throw AppError.avatarUploadFailed
        }
        return signed
    }

    public static func urlSafeBase64(_ data: Data) -> String {
        // Official Qiniu examples keep `=` padding on urlsafe base64.
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
