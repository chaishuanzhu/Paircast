import SwiftUI
import UIKit

/// Loads remote posters with the headers Douban CDN requires (`Referer` / UA).
/// Plain `AsyncImage` gets HTTP 418 and shows nothing.
struct PosterImage: View {
    let url: URL?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
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
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        if isDoubanHost(url.host) {
            request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }

    private func isDoubanHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host.contains("doubanio.com") || host.contains("douban.com")
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
