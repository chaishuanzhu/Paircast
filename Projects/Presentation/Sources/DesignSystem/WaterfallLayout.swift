import SwiftUI

/// Masonry / Pinterest-style waterfall using SwiftUI `Layout`.
/// Column count adapts to container width (phone → iPad / Stage Manager).
public struct WaterfallLayout: Layout {
    public var minColumnWidth: CGFloat
    public var maxColumns: Int
    public var spacing: CGFloat

    public init(
        minColumnWidth: CGFloat = 168,
        maxColumns: Int = 5,
        spacing: CGFloat = 12
    ) {
        self.minColumnWidth = minColumnWidth
        self.maxColumns = maxColumns
        self.spacing = spacing
    }

    public struct Cache {
        var columnCount: Int = 0
        var columnWidth: CGFloat = 0
        var placements: [CGPoint] = []
        var itemHeights: [CGFloat] = []
        var totalSize: CGSize = .zero
    }

    public func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 0 else {
            return CGSize(width: 0, height: proposal.height ?? 0)
        }
        computeLayout(width: width, subviews: subviews, cache: &cache)
        return cache.totalSize
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.placements.count != subviews.count
            || abs(cache.totalSize.width - bounds.width) > 0.5 {
            computeLayout(width: bounds.width, subviews: subviews, cache: &cache)
        }

        for index in subviews.indices {
            guard index < cache.placements.count else { break }
            let height = cache.itemHeights[index]
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + cache.placements[index].x,
                    y: bounds.minY + cache.placements[index].y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cache.columnWidth, height: height)
            )
        }
    }

    public static func columnCount(
        for width: CGFloat,
        minColumnWidth: CGFloat = 168,
        maxColumns: Int = 5,
        spacing: CGFloat = 12
    ) -> Int {
        guard width > 0 else { return 2 }
        let raw = Int(floor((width + spacing) / (minColumnWidth + spacing)))
        return max(2, min(maxColumns, max(1, raw)))
    }

    private func computeLayout(
        width: CGFloat,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let columns = Self.columnCount(
            for: width,
            minColumnWidth: minColumnWidth,
            maxColumns: maxColumns,
            spacing: spacing
        )
        let totalSpacing = spacing * CGFloat(columns - 1)
        let columnWidth = max(0, (width - totalSpacing) / CGFloat(columns))

        var columnHeights = Array(repeating: CGFloat.zero, count: columns)
        var placements: [CGPoint] = []
        var heights: [CGFloat] = []
        placements.reserveCapacity(subviews.count)
        heights.reserveCapacity(subviews.count)

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            var shortest = 0
            for i in 1..<columns where columnHeights[i] < columnHeights[shortest] {
                shortest = i
            }
            let x = CGFloat(shortest) * (columnWidth + spacing)
            let y = columnHeights[shortest]
            placements.append(CGPoint(x: x, y: y))
            heights.append(size.height)
            columnHeights[shortest] += size.height + spacing
        }

        let contentHeight = (columnHeights.max() ?? 0) - (subviews.isEmpty ? 0 : spacing)
        cache.columnCount = columns
        cache.columnWidth = columnWidth
        cache.placements = placements
        cache.itemHeights = heights
        cache.totalSize = CGSize(width: width, height: max(0, contentHeight))
    }
}
