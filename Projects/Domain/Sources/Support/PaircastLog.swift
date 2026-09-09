import Foundation
import os

/// Shared app loggers. Prefer these over `print` so Console.app can filter by category.
public enum PaircastLog {
    public static let catalog = Logger(subsystem: "com.chaisz.tandem", category: "catalog")
    public static let playback = Logger(subsystem: "com.chaisz.tandem", category: "playback")

    /// Host + path + safe query keys only (no Signature / Credential secrets).
    /// Note: `X-Amz-Credential` is shown as `<present>` so logs are not mistaken for usable URLs.
    public static func redactedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        let allowed: Set<String> = [
            "X-Amz-Algorithm",
            "X-Amz-Date",
            "X-Amz-Expires",
            "X-Amz-SignedHeaders",
            "list-type",
            "max-keys",
            "prefix",
            "continuation-token",
        ]
        if let items = components.queryItems {
            let hadCredential = items.contains(where: { $0.name == "X-Amz-Credential" })
            let hadSignature = items.contains(where: { $0.name == "X-Amz-Signature" })
            components.queryItems = items.compactMap { item in
                guard allowed.contains(item.name) else { return nil }
                if item.name == "continuation-token" {
                    return URLQueryItem(name: item.name, value: "<redacted>")
                }
                return item
            }
            if hadCredential {
                components.queryItems?.append(URLQueryItem(name: "X-Amz-Credential", value: "<present>"))
            }
            if hadSignature {
                components.queryItems?.append(URLQueryItem(name: "X-Amz-Signature", value: "<redacted>"))
            }
        }
        return components.string ?? url.absoluteString
    }
}
