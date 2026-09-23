import Foundation
import UIKit
import Domain

/// Resolves Twemoji PNGs: bundled `Twemoji/{code}.png` first, then CDN cache.
enum TwemojiImageCache {
    private static let lock = NSLock()
    private static var memory: [String: UIImage] = [:]
    private static var inflight: [String: [(UIImage?) -> Void]] = [:]

    static func bundledImage(forEmoji emoji: String) -> UIImage? {
        let name = Twemoji.resourceName(forEmoji: emoji)
        guard !name.isEmpty else { return nil }
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Twemoji")
            ?? Bundle.main.url(forResource: name, withExtension: "png") {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }

    static func imageSyncIfCached(forEmoji emoji: String) -> UIImage? {
        let key = Twemoji.codepoints(for: emoji)
        lock.lock()
        if let cached = memory[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        if let bundled = bundledImage(forEmoji: emoji) {
            lock.lock()
            memory[key] = bundled
            lock.unlock()
            return bundled
        }
        return nil
    }

    static func image(forEmoji emoji: String, completion: @escaping (UIImage?) -> Void) {
        let key = Twemoji.codepoints(for: emoji)
        guard !key.isEmpty else {
            completion(nil)
            return
        }
        if let sync = imageSyncIfCached(forEmoji: emoji) {
            completion(sync)
            return
        }
        lock.lock()
        if inflight[key] != nil {
            inflight[key, default: []].append(completion)
            lock.unlock()
            return
        }
        inflight[key] = [completion]
        lock.unlock()

        guard let url = Twemoji.imageURL(forEmoji: emoji) else {
            finish(key: key, image: nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            finish(key: key, image: image)
        }.resume()
    }

    private static func finish(key: String, image: UIImage?) {
        lock.lock()
        if let image {
            memory[key] = image
        }
        let waiters = inflight.removeValue(forKey: key) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            waiters.forEach { $0(image) }
        }
    }
}
