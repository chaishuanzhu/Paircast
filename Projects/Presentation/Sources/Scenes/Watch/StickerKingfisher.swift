import Foundation
import UIKit
import Kingfisher

/// Shared Kingfisher cache tuned for sticker GIFs (tight memory, larger disk).
enum StickerKingfisher {
    static let cache: ImageCache = {
        let cache = ImageCache(name: "paircast.stickers")
        // Decoded GIF frames are huge; keep a small working set only.
        cache.memoryStorage.config.totalCostLimit = 32 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 48
        cache.memoryStorage.config.expiration = .seconds(120)
        cache.diskStorage.config.sizeLimit = 512 * 1024 * 1024
        return cache
    }()

    static func clearMemory() {
        cache.clearMemoryCache()
    }
}
