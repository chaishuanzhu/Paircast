import CryptoKit
import Foundation
import UIKit
import VLCKitSPM

/// Generates and caches a landscape cover from the video's five-second mark.
@MainActor
final class VideoCoverGenerator: NSObject, VLCMediaDelegate, VLCMediaThumbnailerDelegate {
    static let shared = VideoCoverGenerator()

    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var media: VLCMedia?
    private var thumbnailer: VLCMediaThumbnailer?
    private var activeCacheKey: String?

    func cachedImage(for cacheKey: String) -> UIImage? {
        UIImage(contentsOfFile: cacheURL(for: cacheKey).path)
    }

    func image(for url: URL, cacheKey: String) async -> UIImage? {
        if let cached = cachedImage(for: cacheKey) {
            return cached
        }

        // The watch scene only prepares one movie at a time.
        finish(with: nil)
        activeCacheKey = cacheKey

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<UIImage?, Never>) in
            self.continuation = continuation
            let media = VLCMedia(url: url)
            self.media = media
            media.delegate = self
            let result = media.parse(
                options: VLCMediaParsingOptions(rawValue: 1),
                timeout: 10_000
            )
            if result != 0 {
                startThumbnailing(durationMs: media.length.intValue)
            }
        }
    }

    func cancel() {
        finish(with: nil)
    }

    nonisolated func mediaDidFinishParsing(_ media: VLCMedia) {
        let durationMs = media.length.intValue
        Task { @MainActor [weak self] in
            self?.startThumbnailing(durationMs: durationMs)
        }
    }

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor [weak self] in
            self?.finish(with: nil)
        }
    }

    nonisolated func mediaThumbnailer(
        _ mediaThumbnailer: VLCMediaThumbnailer,
        didFinishThumbnail thumbnail: CGImage
    ) {
        let image = UIImage(cgImage: thumbnail)
        Task { @MainActor [weak self] in
            self?.finish(with: image)
        }
    }

    private func startThumbnailing(durationMs rawDurationMs: Int32) {
        guard let media else {
            finish(with: nil)
            return
        }
        let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
        thumbnailer.thumbnailWidth = 960
        thumbnailer.thumbnailHeight = 540
        thumbnailer.snapshotPosition = Self.snapshotPosition(durationMs: rawDurationMs)
        self.thumbnailer = thumbnailer
        thumbnailer.fetchThumbnail()
    }

    static func snapshotPosition(durationMs rawDurationMs: Int32) -> Float {
        let durationMs = max(rawDurationMs, 1)
        let fiveSeconds = min(5_000, max(durationMs / 2, 1))
        return min(0.99, Float(fiveSeconds) / Float(durationMs))
    }

    private func finish(with image: UIImage?) {
        guard let continuation else { return }
        if let image, let activeCacheKey {
            try? image.jpegData(compressionQuality: 0.82)?.write(
                to: cacheURL(for: activeCacheKey),
                options: .atomic
            )
        }
        self.continuation = nil
        self.media?.delegate = nil
        self.media = nil
        self.thumbnailer = nil
        self.activeCacheKey = nil
        continuation.resume(returning: image)
    }

    private func cacheURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Paircast/VideoCovers", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("\(digest).jpg")
    }
}
