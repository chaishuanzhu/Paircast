import Foundation
import Domain

/// Loads sticker packs from the user's bucket `stickers/` via SigV4 GET.
public actor StickerCatalogStore: StickerCatalogGateway {
    public static let sigV4MaxExpiresSeconds = 7 * 24 * 3600

    private let session: URLSession
    private var memoryImages: [String: Data] = [:]
    private var packCache: [String: StickerPack] = [:]
    private var catalogCacheFingerprint: String?
    private var catalogCache: [StickerPackSummary] = []
    private let diskRoot: URL

    public init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        diskRoot = base.appendingPathComponent("Paircast/Stickers", isDirectory: true)
        try? fileManager.createDirectory(at: diskRoot, withIntermediateDirectories: true)
    }

    public func loadCatalog(config: AppCloudConfig) async throws -> [StickerPackSummary] {
        guard config.storage.isComplete else { throw AppError.notConfigured }
        let fingerprint = configFingerprint(config)
        if catalogCacheFingerprint == fingerprint, !catalogCache.isEmpty {
            return catalogCache
        }
        let key = StickersObjectKey.catalogKey(storagePrefix: config.storage.prefix)
        let data = try await getObject(objectKey: key, config: config)
        let dto = try JSONDecoder().decode(StickerCatalogDTO.self, from: data)
        let summaries = dto.packs.map { $0.asSummary() }
        if catalogCacheFingerprint != fingerprint {
            packCache.removeAll()
            memoryImages.removeAll()
        }
        catalogCache = summaries
        catalogCacheFingerprint = fingerprint
        return summaries
    }

    public func loadPack(packId: String, config: AppCloudConfig) async throws -> StickerPack {
        guard config.storage.isComplete else { throw AppError.notConfigured }
        let cacheKey = "\(configFingerprint(config))|\(packId)"
        if let cached = packCache[cacheKey] {
            return cached
        }
        let key = StickersObjectKey.packManifestKey(packId: packId, storagePrefix: config.storage.prefix)
        let data = try await getObject(objectKey: key, config: config)
        let dto = try JSONDecoder().decode(StickerPackDTO.self, from: data)
        let pack = dto.asPack()
        packCache[cacheKey] = pack
        return pack
    }

    public func imageData(packId: String, fileName: String, config: AppCloudConfig) async throws -> Data {
        guard config.storage.isComplete else { throw AppError.notConfigured }
        let memKey = "\(configFingerprint(config))|\(packId)|\(fileName)"
        if let cached = memoryImages[memKey] {
            return cached
        }
        let diskURL = diskFileURL(packId: packId, fileName: fileName, fingerprint: configFingerprint(config))
        if let disk = try? Data(contentsOf: diskURL), !disk.isEmpty {
            memoryImages[memKey] = disk
            return disk
        }
        let key = StickersObjectKey.assetKey(
            packId: packId,
            fileName: fileName,
            storagePrefix: config.storage.prefix
        )
        let data = try await getObject(objectKey: key, config: config)
        memoryImages[memKey] = data
        try? FileManager.default.createDirectory(
            at: diskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: diskURL, options: .atomic)
        return data
    }

    public func imageData(for ref: StickerRef, config: AppCloudConfig) async throws -> Data {
        let fileName = try await resolveFileName(for: ref, config: config)
        return try await imageData(packId: ref.packId, fileName: fileName, config: config)
    }

    public func imageURL(for ref: StickerRef, config: AppCloudConfig) async throws -> URL {
        guard config.storage.isComplete else { throw AppError.notConfigured }
        let fileName = try await resolveFileName(for: ref, config: config)
        let key = StickersObjectKey.assetKey(
            packId: ref.packId,
            fileName: fileName,
            storagePrefix: config.storage.prefix
        )
        return try signedGETURL(objectKey: key, config: config)
    }

    // MARK: - Private

    private func resolveFileName(for ref: StickerRef, config: AppCloudConfig) async throws -> String {
        if let file = ref.file, !file.isEmpty {
            return file
        }
        let pack = try await loadPack(packId: ref.packId, config: config)
        if let item = pack.stickers.first(where: { $0.stickerId == ref.stickerId }) {
            return item.fileName
        }
        return "\(ref.stickerId).\(ref.format)"
    }

    private func getObject(objectKey: String, config: AppCloudConfig) async throws -> Data {
        let url = try signedGETURL(objectKey: objectKey, config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.network
        }
        return data
    }

    private func signedGETURL(objectKey: String, config: AppCloudConfig) throws -> URL {
        let objectURL = try S3CompatibleURL.objectURL(objectKey: objectKey, storage: config.storage)
        return try AWSV4Signer.presignGET(
            url: objectURL,
            region: config.storage.signingRegion,
            credentials: S3CompatibleURL.credentials(config.storage),
            expires: Self.sigV4MaxExpiresSeconds
        )
    }

    private func configFingerprint(_ config: AppCloudConfig) -> String {
        let s = config.storage
        return [s.bucket, s.endpoint, s.prefix ?? "", s.domain ?? ""].joined(separator: "|")
    }

    private func diskFileURL(packId: String, fileName: String, fingerprint: String) -> URL {
        let safeFp = fingerprint
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return diskRoot
            .appendingPathComponent(safeFp, isDirectory: true)
            .appendingPathComponent(packId, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
