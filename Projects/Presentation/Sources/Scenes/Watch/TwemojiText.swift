import SwiftUI
import UIKit
import Domain

/// Renders plain text with Twemoji PNG replacements for emoji graphemes.
public struct TwemojiText: View {
    private let text: String
    private let font: Font
    private let foreground: Color
    private let emojiSize: CGFloat

    public init(
        _ text: String,
        font: Font = .system(size: 15),
        foreground: Color = .primary,
        emojiSize: CGFloat = 18
    ) {
        self.text = text
        self.font = font
        self.foreground = foreground
        self.emojiSize = emojiSize
    }

    public var body: some View {
        let runs = Twemoji.runs(in: text)
        if runs.isEmpty || runs.allSatisfy({ if case .text = $0 { return true }; return false }) {
            Text(text)
                .font(font)
                .foregroundStyle(foreground)
        } else {
            TwemojiFlow(runs: runs, font: font, foreground: foreground, emojiSize: emojiSize)
        }
    }
}

private struct TwemojiFlow: View {
    let runs: [TwemojiRun]
    let font: Font
    let foreground: Color
    let emojiSize: CGFloat

    var body: some View {
        WrappingHStack(alignment: .leading, spacing: 1) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case .text(let value):
                    Text(value)
                        .font(font)
                        .foregroundStyle(foreground)
                case .emoji(let glyph, _):
                    TwemojiImage(emoji: glyph, size: emojiSize)
                }
            }
        }
    }
}

/// Minimal wrapping horizontal stack for chat bubbles.
private struct WrappingHStack: Layout {
    var alignment: Alignment = .leading
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                totalHeight = y
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Twemoji image for the picker grid and bubbles (bundle first, then CDN).
public struct TwemojiImage: View {
    let emoji: String
    let size: CGFloat
    @State private var uiImage: UIImage?

    public init(emoji: String, size: CGFloat = 28) {
        self.emoji = emoji
        self.size = size
    }

    public var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Text(emoji)
                    .font(.system(size: size * 0.85))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: emoji) {
            if let cached = TwemojiImageCache.imageSyncIfCached(forEmoji: emoji) {
                uiImage = cached
                return
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                TwemojiImageCache.image(forEmoji: emoji) { image in
                    uiImage = image
                    cont.resume()
                }
            }
        }
    }
}
