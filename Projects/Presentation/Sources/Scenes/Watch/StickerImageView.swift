import SwiftUI
import Domain
import Kingfisher

/// Loads a sticker from the user's OSS `stickers/` catalog via Kingfisher.
///
/// - `animated`: full GIF playback (chat bubbles).
/// - `thumbnail`: first-frame / downsampled static image for the picker grid (cheap).
public struct StickerImageView: View {
    public enum Playback: Sendable {
        case animated
        case thumbnail
    }

    let ref: StickerRef
    let catalog: StickerCatalogGateway
    let config: AppCloudConfig?
    /// Fixed side length. Pass `nil` to fill the parent (e.g. grid cell).
    var side: CGFloat?
    var playback: Playback
    /// Pixel size used when `playback == .thumbnail` (screen points × scale applied by processor).
    var thumbnailPointSide: CGFloat

    @State private var url: URL?
    @State private var failed = false
    @Environment(\.displayScale) private var displayScale

    public init(
        ref: StickerRef,
        catalog: StickerCatalogGateway,
        config: AppCloudConfig?,
        side: CGFloat? = 120,
        playback: Playback = .animated,
        thumbnailPointSide: CGFloat = 72
    ) {
        self.ref = ref
        self.catalog = catalog
        self.config = config
        self.side = side
        self.playback = playback
        self.thumbnailPointSide = thumbnailPointSide
    }

    public var body: some View {
        Group {
            if failed {
                Text(ChatStickerCodec.fallbackText)
                    .font(.system(size: 14))
                    .foregroundStyle(TandemColors.secondaryLabel)
            } else if let url {
                switch playback {
                case .thumbnail:
                    thumbnailImage(url: url)
                case .animated:
                    animatedImage(url: url)
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: side == nil ? .infinity : nil, maxHeight: side == nil ? .infinity : nil)
        .clipped()
        .task(id: "\(ref.bindKey)|\(playback)") {
            await resolveURL()
        }
    }

    @ViewBuilder
    private func thumbnailImage(url: URL) -> some View {
        let pixels = thumbnailPointSide * displayScale
        KFImage.url(url, cacheKey: "\(ref.bindKey).thumb")
            .targetCache(StickerKingfisher.cache)
            .setProcessor(DownsamplingImageProcessor(size: CGSize(width: pixels, height: pixels)))
            .placeholder { ProgressView() }
            .onFailure { _ in failed = true }
            .cancelOnDisappear(true)
            .loadDiskFileSynchronously(false)
            .cacheOriginalImage(false)
            .resizable()
            .scaledToFit()
    }

    @ViewBuilder
    private func animatedImage(url: URL) -> some View {
        KFAnimatedImage.url(url, cacheKey: ref.bindKey)
            .targetCache(StickerKingfisher.cache)
            .placeholder { ProgressView() }
            .onFailure { _ in failed = true }
            .cancelOnDisappear(true)
            .loadDiskFileSynchronously(false)
            .configure { view in
                view.contentMode = .scaleAspectFit
                view.backgroundColor = .clear
                view.clipsToBounds = true
                view.autoPlayAnimatedImage = true
                // Keep only a couple of frames warm instead of the whole GIF.
                view.framePreloadCount = 2
                view.setContentHuggingPriority(.defaultLow, for: .horizontal)
                view.setContentHuggingPriority(.defaultLow, for: .vertical)
                view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            }
            .scaledToFit()
    }

    private func resolveURL() async {
        failed = false
        url = nil
        guard let config else {
            failed = true
            return
        }
        do {
            url = try await catalog.imageURL(for: ref, config: config)
        } catch {
            failed = true
        }
    }
}
