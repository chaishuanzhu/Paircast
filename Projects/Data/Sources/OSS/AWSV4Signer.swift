import Foundation
import CommonCrypto

/// AWS Signature Version 4 signer for S3-compatible APIs.
public enum AWSV4Signer {
    public static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public struct Credentials: Equatable, Sendable {
        public var accessKey: String
        public var secretKey: String
        public init(accessKey: String, secretKey: String) {
            self.accessKey = accessKey
            self.secretKey = secretKey
        }
    }

    public struct SignedRequest: Equatable, Sendable {
        public var url: URL
        public var headers: [String: String]
        public var method: String
    }

    public enum SignerError: Error, Equatable {
        case invalidURL
    }

    /// Signs a request using the Authorization header.
    public static func signHeader(
        method: String,
        url: URL,
        region: String,
        service: String = "s3",
        credentials: Credentials,
        headers: [String: String] = [:],
        payloadHash: String = emptyPayloadHash,
        date: Date = Date()
    ) throws -> SignedRequest {
        let amzDate = amzDateString(date)
        let dateStamp = String(amzDate.prefix(8))
        guard let host = url.host else {
            throw SignerError.invalidURL
        }
        let hostHeader = hostHeaderValue(host: host, port: url.port, scheme: url.scheme)

        var normalized: [String: String] = [:]
        for (key, value) in headers {
            normalized[key.lowercased()] = trimmedHeaderValue(value)
        }
        normalized["host"] = hostHeader
        normalized["x-amz-content-sha256"] = payloadHash
        normalized["x-amz-date"] = amzDate

        let signedHeaderNames = normalized.keys.sorted()
        let canonicalHeaders = signedHeaderNames
            .map { "\($0):\(normalized[$0]!)\n" }
            .joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        let canonicalRequest = [
            method.uppercased(),
            canonicalURIPath(url),
            canonicalQueryString(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(
            secretKey: credentials.secretKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = hmacSHA256Hex(key: signingKey, message: stringToSign)
        let authorization =
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var outputHeaders: [String: String] = [
            "Host": hostHeader,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate,
            "Authorization": authorization,
        ]
        for (key, value) in headers {
            if key.lowercased() == "host" { continue }
            outputHeaders[key] = value
        }

        return SignedRequest(url: url, headers: outputHeaders, method: method.uppercased())
    }

    /// Builds a presigned GET URL (query-string signature).
    public static func presignGET(
        url: URL,
        region: String,
        service: String = "s3",
        credentials: Credentials,
        expires: Int = 6 * 3600,
        date: Date = Date()
    ) throws -> URL {
        let amzDate = amzDateString(date)
        let dateStamp = String(amzDate.prefix(8))
        guard let host = url.host else {
            throw SignerError.invalidURL
        }
        let hostHeader = hostHeaderValue(host: host, port: url.port, scheme: url.scheme)
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let credential = "\(credentials.accessKey)/\(credentialScope)"

        var items: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", credential),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        if let existing = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in existing {
                items.append((item.name, item.value ?? ""))
            }
        }

        let canonicalPath = canonicalURIPath(url)
        let canonicalQuery = canonicalQueryPairs(items)
        let canonicalRequest = [
            "GET",
            canonicalPath,
            canonicalQuery,
            "host:\(hostHeader)\n",
            "host",
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(
            secretKey: credentials.secretKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = hmacSHA256Hex(key: signingKey, message: stringToSign)
        items.append(("X-Amz-Signature", signature))

        let signedQuery = canonicalQueryPairs(items)
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        components.port = url.port
        components.percentEncodedPath = canonicalPath
        components.percentEncodedQuery = signedQuery
        guard let signedURL = components.url else {
            throw SignerError.invalidURL
        }
        return signedURL
    }

    public static func hostHeaderValue(host: String, port: Int?, scheme: String?) -> String {
        guard let port else { return host }
        let scheme = (scheme ?? "https").lowercased()
        if scheme == "https", port == 443 { return host }
        if scheme == "http", port == 80 { return host }
        return "\(host):\(port)"
    }

    public static func amzDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    public static func region(fromEndpoint endpoint: String) -> String {
        let host = normalizedHost(endpoint)
        // s3.cn-east-1.qiniucs.com
        if let regex = try? NSRegularExpression(pattern: #"^s3\.([a-z0-9-]+)\."#),
           let match = regex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)),
           let range = Range(match.range(at: 1), in: host) {
            return String(host[range])
        }
        // s3-cn-east-1.qiniucs.com
        if let regex = try? NSRegularExpression(pattern: #"^s3-([a-z0-9-]+)\."#),
           let match = regex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)),
           let range = Range(match.range(at: 1), in: host) {
            return String(host[range])
        }
        return "cn-east-1"
    }

    public static func normalizedHost(_ endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/")
            .first
            .map(String.init) ?? endpoint
    }

    // MARK: - Internals

    static func canonicalURIPath(_ url: URL) -> String {
        // Prefer already-encoded path to avoid Foundation decoding `( )` inconsistently.
        if let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
           !encoded.isEmpty {
            return encoded
        }
        var path = url.path
        if path.isEmpty { path = "/" }
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0), encodeSlash: true) }
            .joined(separator: "/")
        return encoded.isEmpty ? "/" : encoded
    }

    static func canonicalQueryString(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else {
            return ""
        }
        return canonicalQueryPairs(items.map { ($0.name, $0.value ?? "") })
    }

    static func canonicalQueryPairs(_ pairs: [(String, String)]) -> String {
        let encoded: [(String, String)] = pairs.map { pair in
            (uriEncode(pair.0, encodeSlash: true), uriEncode(pair.1, encodeSlash: true))
        }
        // AWS SigV4: sort by encoded parameter name, then by encoded value.
        let sorted = encoded.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// AWS unreserved set is ASCII-only; do not use `CharacterSet.alphanumerics`
    /// (it can treat non-ASCII letters as unreserved on some platforms).
    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if !encodeSlash {
            allowed.insert(charactersIn: "/")
        }
        return string.utf8.map { byte -> String in
            let scalar = UnicodeScalar(byte)
            if allowed.contains(scalar) {
                return String(Character(scalar))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    static func trimmedHeaderValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func deriveSigningKey(secretKey: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), message: dateStamp)
        let kRegion = hmacSHA256(key: kDate, message: region)
        let kService = hmacSHA256(key: kRegion, message: service)
        return hmacSHA256(key: kService, message: "aws4_request")
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(key: Data, message: String) -> Data {
        hmacSHA256(key: key, message: Data(message.utf8))
    }

    static func hmacSHA256(key: Data, message: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBytes in
            message.withUnsafeBytes { msgBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress,
                    key.count,
                    msgBytes.baseAddress,
                    message.count,
                    &digest
                )
            }
        }
        return Data(digest)
    }

    static func hmacSHA256Hex(key: Data, message: String) -> String {
        hmacSHA256(key: key, message: message).map { String(format: "%02x", $0) }.joined()
    }
}
