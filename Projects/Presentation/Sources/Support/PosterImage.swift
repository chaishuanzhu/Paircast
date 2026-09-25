import SwiftUI
import UIKit

/// Loads and caches remote poster images.
struct PosterImage: View {
    let url: URL?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        // Size to the offered frame, not the bitmap's intrinsic size — otherwise
        // scaledToFill posters inflate parent ZStacks (e.g. watch chrome).
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed || url == nil {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .task(id: url?.absoluteString) {
                await load()
            }
    }

    private func load() async {
        image = nil
        failed = false
        guard let url else {
            failed = true
            return
        }
        if let cached = PosterImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let loaded = try await PosterImageLoader.shared.load(url)
            PosterImageCache.shared.store(loaded, for: url)
            image = loaded
        } catch {
            failed = true
        }
    }
}

actor PosterImageLoader {
    static let shared = PosterImageLoader()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func load(_ url: URL) async throws -> UIImage {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }
}

final class PosterImageCache: @unchecked Sendable {
    static let shared = PosterImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()

    func image(for url: URL) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return cache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: UIImage, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }
}
