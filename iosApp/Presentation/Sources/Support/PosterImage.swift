import SwiftUI
import Kingfisher

/// Loads and caches remote poster images via Kingfisher (originals on disk).
struct PosterImage: View {
    let url: URL?

    var body: some View {
        // Size to the offered frame, not the bitmap's intrinsic size — otherwise
        // scaledToFill posters inflate parent ZStacks (e.g. watch chrome).
        Color.clear
            .overlay {
                if let url {
                    KFImage.url(url)
                        .targetCache(PaircastKingfisher.images)
                        .cacheOriginalImage(true)
                        .placeholder { ProgressView() }
                        .onFailure { _ in }
                        .cancelOnDisappear(true)
                        .loadDiskFileSynchronously(false)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
    }
}
