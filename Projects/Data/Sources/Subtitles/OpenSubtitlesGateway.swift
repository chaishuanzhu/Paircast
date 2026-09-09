import Foundation
import Domain

/// Lists OSS sidecar subtitles + OpenSubtitles online search/download.
public struct OpenSubtitlesGateway: SubtitleGateway {
    private let session: URLSession
    private let presignExpires: Int
    private let userAgent = "Tandem iOS v1.0"

    public init(
        session: URLSession = .shared,
        presignExpires: Int = OSSMovieCatalogGateway.defaultPresignExpiresSeconds
    ) {
        self.session = session
        self.presignExpires = presignExpires
    }

    public func listEmbedded(for movie: Movie) async throws -> [SubtitleTrack] {
        // Embedded tracks come from the live VLC player after media is parsed.
        _ = movie
        return []
    }

    public func listOSSSidecars(for movie: Movie, config: AppCloudConfig) async throws -> [SubtitleTrack] {
        let base = (movie.objectKey as NSString).deletingPathExtension
        guard !base.isEmpty else { return [] }

        // Prefer listing by movie basename prefix so we don't miss sidecars in large folders
        // (directory-wide ListObjects is capped and may truncate before subtitle keys).
        var keys: [String] = []
        do {
            keys = try await listAllObjectKeys(config: config, prefix: base)
        } catch {
            TandemLog.catalog.error(
                "listOSSSidecars list failed movie=\(movie.objectKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            keys = []
        }

        var sidecarKeys = Self.matchingSidecarKeys(from: keys, movieObjectKey: movie.objectKey)

        // Fallback: HEAD common sidecar names next to the video.
        if sidecarKeys.isEmpty {
            for key in Self.candidateSidecarKeys(base: base) {
                if let _ = try? await probeAndPresign(objectKey: key, config: config) {
                    sidecarKeys.append(key)
                }
            }
        }

        var tracks: [SubtitleTrack] = []
        for key in sidecarKeys.sorted() {
            guard let url = try? makePresignedGetURL(objectKey: key, config: config) else { continue }
            let leaf = (key as NSString).lastPathComponent
            let ext = (leaf as NSString).pathExtension.uppercased()
            let lang = Self.guessLanguage(from: leaf)
            tracks.append(
                SubtitleTrack(
                    id: "oss:\(key)",
                    label: Self.displayLabel(for: leaf, language: lang),
                    language: lang.code,
                    source: .oss,
                    url: url,
                    detail: "片库外挂 · \(ext)",
                    languageBadge: lang.badge,
                    format: ext
                )
            )
        }
        TandemLog.catalog.info(
            "listOSSSidecars movie=\(movie.objectKey, privacy: .public) tracks=\(tracks.count, privacy: .public)"
        )
        return tracks
    }

    public func searchOnline(query: String, year: String?, apiKey: String?) async throws -> [SubtitleTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let apiKey, !apiKey.isEmpty else {
            throw AppError.validation("请先在服务配置中填写 OpenSubtitles API Key")
        }

        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "languages", value: "zh-cn,zh-tw,en"),
            URLQueryItem(name: "order_by", value: "download_count"),
            URLQueryItem(name: "order_direction", value: "desc"),
        ]
        if let year, !year.isEmpty {
            items.append(URLQueryItem(name: "year", value: year))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.network
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AppError.validation("OpenSubtitles API Key 无效")
            }
            throw AppError.subtitleUnavailable
        }

        let decoded = try JSONDecoder().decode(OSSearchResponse.self, from: data)
        return decoded.data.compactMap { item -> SubtitleTrack? in
            guard let file = item.attributes.files?.first else { return nil }
            let fileId = file.fileId
            let name = file.fileName ?? item.attributes.release ?? "字幕 \(fileId)"
            let lang = item.attributes.language ?? ""
            let downloads = item.attributes.downloadCount ?? 0
            let format = ((name as NSString).pathExtension.uppercased()).nilIfEmpty ?? "SRT"
            let guessed = Self.guessLanguage(from: "\(name).\(lang)")
            let downloadLabel: String
            if downloads >= 1000 {
                downloadLabel = String(format: "%.1fk", Double(downloads) / 1000)
            } else {
                downloadLabel = "\(downloads)"
            }
            return SubtitleTrack(
                id: "os:\(fileId)",
                label: name,
                language: lang,
                source: .online,
                url: URL(string: "opensubtitles://file/\(fileId)"),
                detail: "OpenSubtitles · 下载 \(downloadLabel) · \(format)",
                languageBadge: guessed.badge.isEmpty ? lang.uppercased() : guessed.badge,
                format: format
            )
        }
    }

    public func download(_ track: SubtitleTrack, config: AppCloudConfig?) async throws -> URL {
        switch track.source {
        case .oss:
            if let key = Self.ossObjectKey(from: track),
               let config,
               config.storage.isComplete,
               let fresh = try? makePresignedGetURL(objectKey: key, config: config) {
                return try await downloadRemoteFile(fresh, suggestedName: track.label)
            }
            guard let remote = track.url else { throw AppError.subtitleUnavailable }
            return try await downloadRemoteFile(remote, suggestedName: track.label)
        case .online:
            let apiKey = config?.subtitleApiKey
            guard let apiKey, !apiKey.isEmpty else {
                throw AppError.validation("请先在服务配置中填写 OpenSubtitles API Key")
            }
            let fileId = try parseOpenSubtitlesFileId(from: track)
            let link = try await requestOpenSubtitlesDownloadLink(fileId: fileId, apiKey: apiKey)
            return try await downloadRemoteFile(link, suggestedName: track.label)
        case .embedded, .off:
            throw AppError.subtitleUnavailable
        }
    }

    // MARK: - OSS sidecar helpers

    /// Object keys that are sidecar subtitles for `movieObjectKey`.
    public static func matchingSidecarKeys(from keys: [String], movieObjectKey: String) -> [String] {
        let movieLeaf = (movieObjectKey as NSString).lastPathComponent
        let baseLeaf = ((movieObjectKey as NSString).deletingPathExtension as NSString).lastPathComponent
        let movieBase = baseLeaf.lowercased()
        guard !movieBase.isEmpty else { return [] }

        var seen = Set<String>()
        var result: [String] = []
        for key in keys {
            let leaf = (key as NSString).lastPathComponent
            guard leaf != movieLeaf else { continue }
            guard isSubtitleFilename(leaf) else { continue }
            let leafBase = (leaf as NSString).deletingPathExtension.lowercased()
            let matched = leafBase == movieBase
                || leafBase.hasPrefix(movieBase + ".")
                || leafBase.hasPrefix(movieBase + "_")
                || leafBase.hasPrefix(movieBase + "-")
            guard matched else { continue }
            if seen.insert(key).inserted {
                result.append(key)
            }
        }
        return result
    }

    public static func ossObjectKey(from track: SubtitleTrack) -> String? {
        guard track.source == .oss, track.id.hasPrefix("oss:") else { return nil }
        let key = String(track.id.dropFirst("oss:".count))
        return key.isEmpty ? nil : key
    }

    private static func candidateSidecarKeys(base: String) -> [String] {
        let suffixes = [
            ".srt", ".zh.srt", ".chi.srt", ".chs.srt", ".zh-cn.srt", ".zh_cn.srt",
            ".en.srt", ".eng.srt",
            ".vtt", ".zh.vtt", ".en.vtt",
            ".ass", ".ssa", ".zh.ass",
        ]
        return suffixes.map { base + $0 }
    }

    private static func isSubtitleFilename(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["srt", "vtt", "ass", "ssa"].contains(ext)
    }

    private static func displayLabel(for filename: String, language: (code: String?, badge: String)) -> String {
        if !language.badge.isEmpty {
            return "\(language.badge)（外挂）"
        }
        return filename
    }

    private static func guessLanguage(from name: String) -> (code: String?, badge: String) {
        let lower = name.lowercased()
        if lower.contains("zh-cn") || lower.contains("zh_cn") || lower.contains(".chs")
            || lower.contains("简体") || lower.contains("chi") || lower.contains(".zh.")
            || lower.hasSuffix(".zh") || lower.contains("chinese") {
            return ("zh", "简中")
        }
        if lower.contains("zh-tw") || lower.contains("zh_tw") || lower.contains(".cht") || lower.contains("繁体") {
            return ("zh-tw", "繁中")
        }
        if lower.contains(".en") || lower.contains("eng") || lower.contains("english") {
            return ("en", "English")
        }
        if lower.contains("双语") || lower.contains("dual") {
            return (nil, "双语")
        }
        return (nil, "")
    }

    private func listAllObjectKeys(config: AppCloudConfig, prefix: String) async throws -> [String] {
        var allKeys: [String] = []
        var continuationToken: String?
        var pageCount = 0
        repeat {
            pageCount += 1
            if pageCount > 20 { break }
            let page = try await listObjectKeysPage(
                config: config,
                prefix: prefix,
                continuationToken: continuationToken
            )
            allKeys.append(contentsOf: page.keys)
            if page.isTruncated, let next = page.nextContinuationToken, !next.isEmpty {
                continuationToken = next
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil
        return allKeys
    }

    private func listObjectKeysPage(
        config: AppCloudConfig,
        prefix: String,
        continuationToken: String?
    ) async throws -> S3ListObjectsV2Page {
        let region = config.storage.signingRegion
        let credentials = S3CompatibleURL.credentials(config.storage)

        var components = URLComponents(url: try S3CompatibleURL.bucketURL(storage: config.storage), resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: "1000"),
            URLQueryItem(name: "prefix", value: prefix),
        ]
        if let continuationToken, !continuationToken.isEmpty {
            query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw AppError.catalogUnauthorized }

        let signed = try AWSV4Signer.signHeader(
            method: "GET",
            url: url,
            region: region,
            credentials: credentials
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        for (key, value) in signed.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.catalogUnauthorized
        }
        return try S3ListObjectsV2Parser.parsePage(from: data)
    }

    private func probeAndPresign(objectKey: String, config: AppCloudConfig) async throws -> URL? {
        let region = config.storage.signingRegion
        let objectURL = try makeObjectURL(objectKey: objectKey, config: config)
        let signed = try AWSV4Signer.signHeader(
            method: "HEAD",
            url: objectURL,
            region: region,
            credentials: S3CompatibleURL.credentials(config.storage)
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = "HEAD"
        for (key, value) in signed.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return try makePresignedGetURL(objectKey: objectKey, config: config)
    }

    private func makeObjectURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        try S3CompatibleURL.objectURL(objectKey: objectKey, storage: config.storage)
    }

    private func makePresignedGetURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        let region = config.storage.signingRegion
        let url = try makeObjectURL(objectKey: objectKey, config: config)
        return try AWSV4Signer.presignGET(
            url: url,
            region: region,
            credentials: S3CompatibleURL.credentials(config.storage),
            expires: presignExpires
        )
    }

    // MARK: - OpenSubtitles download

    private func parseOpenSubtitlesFileId(from track: SubtitleTrack) throws -> Int {
        if track.id.hasPrefix("os:"), let id = Int(track.id.dropFirst(3)) {
            return id
        }
        if let url = track.url, url.scheme == "opensubtitles",
           let id = Int(url.lastPathComponent) {
            return id
        }
        throw AppError.subtitleUnavailable
    }

    private func requestOpenSubtitlesDownloadLink(fileId: Int, apiKey: String) async throws -> URL {
        let url = URL(string: "https://api.opensubtitles.com/api/v1/download")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileId])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.subtitleUnavailable
        }
        let decoded = try JSONDecoder().decode(OSDownloadResponse.self, from: data)
        guard let link = decoded.link, let fileURL = URL(string: link) else {
            throw AppError.subtitleUnavailable
        }
        return fileURL
    }

    private func downloadRemoteFile(_ remote: URL, suggestedName: String) async throws -> URL {
        let (data, response) = try await session.data(from: remote)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.subtitleUnavailable
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = suggestedName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let ext = (remote.pathExtension.isEmpty ? "srt" : remote.pathExtension)
        let fileName = safe.hasSuffix(".\(ext)") ? safe : "\(safe).\(ext)"
        // Unique cache file so stale wrong-encoding copies are not reused.
        let stamp = String(format: "%08x", UInt32(truncatingIfNeeded: data.count) ^ UInt32(truncatingIfNeeded: data.hashValue))
        let local = dir.appendingPathComponent("\(stamp)-\(fileName)")
        try SubtitleEncodingNormalizer.writeUTF8File(raw: data, to: local)
        return local
    }
}

// MARK: - OpenSubtitles JSON

private struct OSSearchResponse: Decodable {
    let data: [OSSearchItem]
}

private struct OSSearchItem: Decodable {
    let attributes: OSAttributes
}

private struct OSAttributes: Decodable {
    let language: String?
    let release: String?
    let downloadCount: Int?
    let files: [OSFile]?

    enum CodingKeys: String, CodingKey {
        case language, release, files
        case downloadCount = "download_count"
    }
}

private struct OSFile: Decodable {
    let fileId: Int
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileName = "file_name"
    }
}

private struct OSDownloadResponse: Decodable {
    let link: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
