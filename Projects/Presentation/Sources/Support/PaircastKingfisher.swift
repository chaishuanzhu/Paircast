import Foundation
import UIKit
import Kingfisher

/// Shared Kingfisher caches for Paircast network images.
enum PaircastKingfisher {
    /// Posters, avatars, Twemoji CDN fallbacks — static images, originals on disk.
    static let images: ImageCache = {
        let cache = ImageCache(name: "paircast.images")
        cache.memoryStorage.config.totalCostLimit = 64 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 128
        cache.memoryStorage.config.expiration = .days(7)
        cache.diskStorage.config.sizeLimit = 512 * 1024 * 1024
        cache.diskStorage.config.expiration = .days(30)
        return cache
    }()

    /// Sticker GIFs (tight memory, larger disk).
    static let stickers: ImageCache = {
        let cache = ImageCache(name: "paircast.stickers")
        cache.memoryStorage.config.totalCostLimit = 32 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 48
        cache.memoryStorage.config.expiration = .seconds(120)
        cache.diskStorage.config.sizeLimit = 512 * 1024 * 1024
        return cache
    }()

    static func clearStickerMemory() {
        stickers.clearMemoryCache()
    }
}

/// Back-compat alias used by the sticker panel.
enum StickerKingfisher {
    static var cache: ImageCache { PaircastKingfisher.stickers }

    static func clearMemory() {
        PaircastKingfisher.clearStickerMemory()
    }
}
