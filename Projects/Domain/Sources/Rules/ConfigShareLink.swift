import Foundation
import CryptoKit

/// Encrypts cloud config into a shareable deep link:
/// `tandem://config?args=<base64url(AES-GCM sealed box)>`
///
/// The symmetric key is app-embedded (transport obfuscation / casual snooping),
/// not a substitute for trusting the recipient — the payload still contains secrets.
public enum ConfigShareLink {
    public static let urlScheme = "tandem"
    public static let urlHost = "config"
    public static let argsQueryName = "args"
    public static let maxArgsUTF8Bytes = 3_500

    /// Builds `tandem://config?args=…` from the current config.
    public static func shareURL(for config: AppCloudConfig) throws -> URL {
        let args = try encodeArgs(for: config)
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = urlHost
        components.queryItems = [URLQueryItem(name: argsQueryName, value: args)]
        guard let url = components.url else {
            throw AppError.invalidConfigQR
        }
        return url
    }

    public static func encodeArgs(for config: AppCloudConfig) throws -> String {
        let plaintext = try ConfigQRCodec.encode(config)
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: symmetricKey)
        guard let combined = sealed.combined else {
            throw AppError.invalidConfigQR
        }
        let args = base64URLEncode(combined)
        guard args.utf8.count <= maxArgsUTF8Bytes else {
            throw AppError.configQRTooLarge
        }
        return args
    }

    /// Accepts a full `tandem://config?args=…` URL, raw `args` token, or legacy plaintext JSON.
    public static func decode(_ input: String) throws -> AppCloudConfig {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.invalidConfigQR }

        if let url = URL(string: trimmed), isConfigShareURL(url) {
            return try decode(url: url)
        }
        if let embedded = extractShareURL(from: trimmed) {
            return try decode(url: embedded)
        }
        if trimmed.hasPrefix("{") {
            return try ConfigQRCodec.decode(trimmed)
        }
        return try decodeArgs(trimmed)
    }

    public static func decode(url: URL) throws -> AppCloudConfig {
        guard isConfigShareURL(url) else { throw AppError.invalidConfigQR }
        let args = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == argsQueryName })?
            .value
        guard let args, !args.isEmpty else { throw AppError.invalidConfigQR }
        return try decodeArgs(args)
    }

    public static func isConfigShareURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == urlScheme && url.host?.lowercased() == urlHost
    }

    public static func decodeArgs(_ args: String) throws -> AppCloudConfig {
        guard args.utf8.count <= maxArgsUTF8Bytes else {
            throw AppError.configQRTooLarge
        }
        guard let data = base64URLDecode(args) else {
            throw AppError.invalidConfigQR
        }
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: data)
        } catch {
            throw AppError.invalidConfigQR
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: symmetricKey)
        } catch {
            throw AppError.invalidConfigQR
        }
        guard let json = String(data: plaintext, encoding: .utf8) else {
            throw AppError.invalidConfigQR
        }
        return try ConfigQRCodec.decode(json)
    }

    // MARK: - Crypto

    private static var symmetricKey: SymmetricKey {
        let material = Data("Tandem.iOS.ConfigShare.v1".utf8)
        return SymmetricKey(data: SHA256.hash(data: material))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    /// Pulls the first `tandem://config?…` substring from pasted chat text.
    private static func extractShareURL(from text: String) -> URL? {
        guard let range = text.range(of: "\(urlScheme)://\(urlHost)", options: .caseInsensitive) else {
            return nil
        }
        let fromScheme = text[range.lowerBound...]
        let end = fromScheme.firstIndex(where: { $0.isWhitespace || $0 == "\n" || $0 == "\"" }) ?? fromScheme.endIndex
        return URL(string: String(fromScheme[..<end]))
    }
}
