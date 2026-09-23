import Foundation

/// Sticker wire payload (`[stk]` + JSON). Authority is `pack_id` + `sticker_id`.
public struct StickerRef: Sendable, Equatable, Codable {
    public var packId: String
    public var stickerId: String
    public var format: String
    public var width: Int
    public var height: Int
    /// Optional object key or absolute URL fallback; receivers prefer resolving via OSS.
    public var url: String?
    /// Optional file name inside the pack (e.g. `001-file_1437.gif`).
    public var file: String?

    public enum CodingKeys: String, CodingKey {
        case packId = "pack_id"
        case stickerId = "sticker_id"
        case format, width, height, url, file
    }

    public init(
        packId: String,
        stickerId: String,
        format: String = "png",
        width: Int = 240,
        height: Int = 240,
        url: String? = nil,
        file: String? = nil
    ) {
        self.packId = packId
        self.stickerId = stickerId
        self.format = format
        self.width = width
        self.height = height
        self.url = url
        self.file = file
    }

    public var bindKey: String { "\(packId)/\(stickerId)" }
}

public struct StickerItem: Sendable, Equatable, Identifiable {
    public var id: String { stickerId }
    public let packId: String
    public let stickerId: String
    public let fileName: String
    public let width: Int
    public let height: Int

    public init(packId: String, stickerId: String, fileName: String, width: Int = 240, height: Int = 240) {
        self.packId = packId
        self.stickerId = stickerId
        self.fileName = fileName
        self.width = width
        self.height = height
    }

    public func asRef() -> StickerRef {
        let ext = fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? "png"
        return StickerRef(
            packId: packId,
            stickerId: stickerId,
            format: ext.isEmpty ? "png" : ext,
            width: width,
            height: height,
            file: fileName
        )
    }
}

public struct StickerPack: Sendable, Equatable, Identifiable {
    public var id: String { packId }
    public let packId: String
    public let name: String
    public let version: Int
    public let coverFileName: String?
    public let stickers: [StickerItem]

    public init(
        packId: String,
        name: String,
        version: Int,
        coverFileName: String? = nil,
        stickers: [StickerItem] = []
    ) {
        self.packId = packId
        self.name = name
        self.version = version
        self.coverFileName = coverFileName
        self.stickers = stickers
    }
}

/// Index entry from `stickers/catalog.json` (full sticker list loaded from pack.json).
public struct StickerPackSummary: Sendable, Equatable, Identifiable {
    public var id: String { packId }
    public let packId: String
    public let name: String
    public let version: Int
    public let coverFileName: String?
    public let count: Int

    public init(
        packId: String,
        name: String,
        version: Int = 1,
        coverFileName: String? = nil,
        count: Int = 0
    ) {
        self.packId = packId
        self.name = name
        self.version = version
        self.coverFileName = coverFileName
        self.count = count
    }
}

// MARK: - Wire DTOs (ignore cdn_base / base_url)

public struct StickerCatalogDTO: Sendable, Equatable, Codable {
    public var version: Int?
    public var packs: [StickerPackSummaryDTO]

    public init(version: Int? = 1, packs: [StickerPackSummaryDTO]) {
        self.version = version
        self.packs = packs
    }
}

public struct StickerPackSummaryDTO: Sendable, Equatable, Codable {
    public var packId: String
    public var name: String
    public var version: Int?
    public var cover: String?
    public var count: Int?

    public enum CodingKeys: String, CodingKey {
        case packId = "pack_id"
        case name, version, cover, count
    }

    public func asSummary() -> StickerPackSummary {
        StickerPackSummary(
            packId: packId,
            name: name,
            version: version ?? 1,
            coverFileName: cover,
            count: count ?? 0
        )
    }
}

public struct StickerPackDTO: Sendable, Equatable, Codable {
    public var packId: String
    public var name: String
    public var version: Int?
    public var cover: String?
    public var stickers: [StickerItemDTO]

    public enum CodingKeys: String, CodingKey {
        case packId = "pack_id"
        case name, version, cover, stickers
    }

    public func asPack() -> StickerPack {
        let items = stickers.map {
            StickerItem(
                packId: packId,
                stickerId: $0.id,
                fileName: $0.file,
                width: $0.w ?? 240,
                height: $0.h ?? 240
            )
        }
        return StickerPack(
            packId: packId,
            name: name,
            version: version ?? 1,
            coverFileName: cover,
            stickers: items
        )
    }
}

public struct StickerItemDTO: Sendable, Equatable, Codable {
    public var id: String
    public var file: String
    public var w: Int?
    public var h: Int?
}
