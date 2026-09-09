import Foundation
import Domain

/// Builds path-style (or virtual-hosted) object URLs for any S3-compatible provider.
public enum S3CompatibleURL {
    public static func credentials(_ storage: ObjectStorageConfig) -> AWSV4Signer.Credentials {
        .init(accessKey: storage.accessKey, secretKey: storage.secretKey)
    }

    public static func objectURL(objectKey: String, storage: ObjectStorageConfig) throws -> URL {
        var components = URLComponents()
        components.scheme = storage.useSSL ? "https" : "http"
        let endpoint = AWSV4Signer.normalizedHost(storage.endpoint)
        let (host, port) = splitHostPort(endpoint)
        let keySegments = objectKey.split(separator: "/").map(String.init)
        if storage.forcePathStyle {
            components.host = host
            components.port = port
            components.percentEncodedPath = "/" + ([storage.bucket] + keySegments)
                .map { AWSV4Signer.uriEncodePublic($0) }
                .joined(separator: "/")
        } else {
            components.host = "\(storage.bucket).\(host)"
            components.port = port
            components.percentEncodedPath = "/" + keySegments
                .map { AWSV4Signer.uriEncodePublic($0) }
                .joined(separator: "/")
        }
        guard let url = components.url else {
            throw AppError.playbackFailed
        }
        return url
    }

    public static func bucketURL(storage: ObjectStorageConfig) throws -> URL {
        var components = URLComponents()
        components.scheme = storage.useSSL ? "https" : "http"
        let endpoint = AWSV4Signer.normalizedHost(storage.endpoint)
        let (host, port) = splitHostPort(endpoint)
        if storage.forcePathStyle {
            components.host = host
            components.port = port
            components.path = "/\(storage.bucket)"
        } else {
            components.host = "\(storage.bucket).\(host)"
            components.port = port
            components.path = "/"
        }
        guard let url = components.url else {
            throw AppError.catalogUnauthorized
        }
        return url
    }

    private static func splitHostPort(_ endpoint: String) -> (String, Int?) {
        // IPv6 in brackets not supported in MVP endpoints.
        if let idx = endpoint.lastIndex(of: ":"),
           endpoint[..<idx].contains(".") || endpoint[..<idx].allSatisfy({ $0.isNumber || $0 == "." }),
           let port = Int(endpoint[endpoint.index(after: idx)...]),
           port > 0, port < 65536 {
            return (String(endpoint[..<idx]), port)
        }
        return (endpoint, nil)
    }
}
