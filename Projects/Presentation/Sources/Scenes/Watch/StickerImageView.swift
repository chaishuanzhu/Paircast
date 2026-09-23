import SwiftUI
import Domain
import Kingfisher

/// Loads a sticker from the user's OSS `stickers/` catalog via Kingfisher (GIF-capable).
public struct StickerImageView: View {
    let ref: StickerRef
    let catalog: StickerCatalogGateway
    let config: AppCloudConfig?
    /// Fixed side length. Pass `nil` to fill the parent (e.g. grid cell).
    var side: CGFloat?

    @State private var url: URL?
    @State private var failed = false

    public init(
        ref: StickerRef,
        catalog: StickerCatalogGateway,
        config: AppCloudConfig?,
        side: CGFloat? = 120
    ) {
        self.ref = ref
        self.catalog = catalog
        self.config = config
        self.side = side
    }

    public var body: some View {
        Group {
            if failed {
                Text(ChatStickerCodec.fallbackText)
                    .font(.system(size: 14))
                    .foregroundStyle(TandemColors.secondaryLabel)
            } else if let url {
                KFAnimatedImage.url(url, cacheKey: ref.bindKey)
                    .placeholder {
                        ProgressView()
                    }
                    .onFailure { _ in
                        failed = true
                    }
                    .cancelOnDisappear(true)
                    .loadDiskFileSynchronously(false)
                    .configure { view in
                        view.contentMode = .scaleAspectFit
                        view.backgroundColor = .clear
                        view.clipsToBounds = true
                        view.autoPlayAnimatedImage = true
                        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
                        view.setContentHuggingPriority(.defaultLow, for: .vertical)
                        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                    }
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: side == nil ? .infinity : nil, maxHeight: side == nil ? .infinity : nil)
        .clipped()
        .task(id: ref.bindKey) {
            await resolveURL()
        }
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
