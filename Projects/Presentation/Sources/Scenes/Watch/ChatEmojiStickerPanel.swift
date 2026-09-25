import SwiftUI
import Domain

/// Bottom accessory: Twemoji grid + OSS sticker packs.
struct ChatEmojiStickerPanel: View {
    enum Tab: Hashable {
        case emoji
        case stickers
    }

    private static let recentPageId = "__recent__"
    /// Only mount sticker grids for the current page ± this radius.
    private static let activePageRadius = 1

    @Binding var draft: String
    let catalog: StickerCatalogGateway
    let config: AppCloudConfig?
    let onSendSticker: (StickerRef) -> Void

    @State private var tab: Tab = .emoji
    @State private var summaries: [StickerPackSummary] = []
    @State private var selectedPackId: String = Self.recentPageId
    @State private var packsById: [String: StickerPack] = [:]
    @State private var recent: [StickerRef] = []
    @State private var loading = false
    @State private var loadFailed = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let recentKey = "paircast.stickers.recent"
    /// Emoji / sticker cell size is derived from available width so rows fill edge-to-edge.
    private static let emojiTargetSide: CGFloat = 40
    private static let emojiMinSide: CGFloat = 32
    private static let emojiMaxSide: CGFloat = 48
    private static let emojiSpacing: CGFloat = 4
    private static let stickerSpacing: CGFloat = 2
    private static let stickerTargetSide: CGFloat = 72
    private static let stickerMinSide: CGFloat = 56
    private static let stickerMaxSide: CGFloat = 96

    private var panelHeight: CGFloat {
        horizontalSizeClass == .regular ? 340 : 280
    }

    /// Column count from a target cell size, then grow/shrink cells to fill the row.
    private static func fillLayout(
        width: CGFloat,
        horizontalPadding: CGFloat,
        spacing: CGFloat,
        target: CGFloat,
        minSide: CGFloat,
        maxSide: CGFloat,
        minimumColumns: Int
    ) -> (columns: [GridItem], cell: CGFloat) {
        let usable = max(minSide, width - horizontalPadding)
        var count = max(minimumColumns, Int((usable + spacing) / (target + spacing)))
        var cell = (usable - CGFloat(count - 1) * spacing) / CGFloat(count)
        while cell > maxSide {
            count += 1
            cell = (usable - CGFloat(count - 1) * spacing) / CGFloat(count)
        }
        if cell < minSide {
            count = max(minimumColumns, Int((usable + spacing) / (minSide + spacing)))
            cell = (usable - CGFloat(count - 1) * spacing) / CGFloat(count)
        }
        cell = (cell * 2).rounded(.down) / 2
        let columns = Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: count)
        return (columns, cell)
    }

    private static func emojiLayout(width: CGFloat) -> (columns: [GridItem], cell: CGFloat) {
        fillLayout(
            width: width,
            horizontalPadding: 24,
            spacing: emojiSpacing,
            target: emojiTargetSide,
            minSide: emojiMinSide,
            maxSide: emojiMaxSide,
            minimumColumns: 8
        )
    }

    private static func stickerLayout(width: CGFloat) -> (columns: [GridItem], cell: CGFloat) {
        fillLayout(
            width: width,
            horizontalPadding: 8,
            spacing: stickerSpacing,
            target: stickerTargetSide,
            minSide: stickerMinSide,
            maxSide: stickerMaxSide,
            minimumColumns: 4
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Emoji").tag(Tab.emoji)
                Text("Stickers").tag(Tab.stickers)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Group {
                switch tab {
                case .emoji:
                    emojiGrid
                case .stickers:
                    stickerContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: panelHeight)
        .frame(maxWidth: .infinity)
        .background(TandemColors.secondaryGrouped)
        .task(id: configFingerprint) {
            await reloadCatalog()
            recent = loadRecent()
        }
        .onChange(of: tab) { _, new in
            if new == .stickers {
                if packsById.isEmpty, let first = summaries.first {
                    Task { await selectPack(first.packId) }
                }
            } else {
                // Drop decoded sticker bitmaps when leaving the stickers tab.
                StickerKingfisher.clearMemory()
                trimPackCache(around: selectedPackId)
            }
        }
        .onDisappear {
            StickerKingfisher.clearMemory()
        }
    }

    private var configFingerprint: String {
        guard let s = config?.storage else { return "" }
        return [s.bucket, s.endpoint, s.prefix ?? ""].joined(separator: "|")
    }

    /// Pages: Recent + each catalog pack (swipe horizontally).
    private var packPageIds: [String] {
        [Self.recentPageId] + summaries.map(\.packId)
    }

    private var selectedPageIndex: Int {
        packPageIds.firstIndex(of: selectedPackId) ?? 0
    }

    private var emojiGrid: some View {
        GeometryReader { geo in
            let layout = Self.emojiLayout(width: geo.size.width)
            // Glyph slightly smaller than the cell so taps stay comfortable.
            let glyph = min(layout.cell * 0.7, layout.cell - 8)
            ScrollView {
                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: 8) {
                    ForEach(Twemoji.pickerEmojis, id: \.self) { emoji in
                        Button {
                            draft.append(emoji)
                        } label: {
                            TwemojiImage(emoji: emoji, size: glyph)
                                .frame(width: layout.cell, height: layout.cell)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private var stickerContent: some View {
        if config == nil || !(config?.storage.isComplete ?? false) {
            emptyState("Finish service configuration to load stickers")
        } else if loading && summaries.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed || summaries.isEmpty {
            emptyState("Upload sticker packs to your bucket under stickers/")
        } else {
            VStack(spacing: 0) {
                packBar
                    .padding(.bottom, 4)
                stickerPager
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var packBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    packChip(id: Self.recentPageId, title: "Recent")
                    ForEach(summaries) { summary in
                        packChip(id: summary.packId, title: summary.name)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 28)
            .onChange(of: selectedPackId) { _, id in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func packChip(id: String, title: String) -> some View {
        Button {
            Task { await selectPack(id) }
        } label: {
            Text(shortTitle(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selectedPackId == id ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selectedPackId == id ? TandemColors.systemBlue : TandemColors.groupedBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(id)
    }

    private func shortTitle(_ title: String) -> String {
        if title.count <= 10 { return title }
        return String(title.prefix(10)) + "…"
    }

    private var stickerPager: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(packPageIds, id: \.self) { pageId in
                        Group {
                            if isPageActive(pageId) {
                                stickerPage(pageId: pageId)
                            } else {
                                // Keep page size for paging, but destroy image views off-screen.
                                Color.clear
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(pageId)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding(
                get: { Optional(selectedPackId) },
                set: { newValue in
                    guard let newValue, newValue != selectedPackId else { return }
                    selectedPackId = newValue
                }
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedPackId) { _, id in
            Task {
                await ensurePackLoaded(id)
                // Prefetch immediate neighbors' manifests only.
                await prefetchNeighborManifests(around: id)
                trimPackCache(around: id)
            }
        }
    }

    private func isPageActive(_ pageId: String) -> Bool {
        guard let idx = packPageIds.firstIndex(of: pageId) else { return false }
        return abs(idx - selectedPageIndex) <= Self.activePageRadius
    }

    private func stickerPage(pageId: String) -> some View {
        let items = items(for: pageId)
        return Group {
            if pageId != Self.recentPageId, packsById[pageId] == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await ensurePackLoaded(pageId) }
            } else if items.isEmpty {
                emptyState(pageId == Self.recentPageId ? "No recent stickers" : "No stickers in this pack")
            } else {
                GeometryReader { geo in
                    let layout = Self.stickerLayout(width: geo.size.width)
                    ScrollView {
                        LazyVGrid(
                            columns: layout.columns,
                            alignment: .leading,
                            spacing: Self.stickerSpacing
                        ) {
                            ForEach(items, id: \.bindKey) { ref in
                                Button {
                                    recordRecent(ref)
                                    onSendSticker(ref)
                                } label: {
                                    StickerImageView(
                                        ref: ref,
                                        catalog: catalog,
                                        config: config,
                                        side: layout.cell,
                                        playback: .thumbnail,
                                        thumbnailPointSide: layout.cell
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TandemColors.secondaryGrouped)
    }

    private func items(for pageId: String) -> [StickerRef] {
        if pageId == Self.recentPageId {
            return recent
        }
        return packsById[pageId]?.stickers.map { $0.asRef() } ?? []
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(TandemColors.secondaryLabel)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reloadCatalog() async {
        guard let config, config.storage.isComplete else {
            summaries = []
            packsById = [:]
            loadFailed = false
            return
        }
        loading = true
        loadFailed = false
        defer { loading = false }
        do {
            summaries = try await catalog.loadCatalog(config: config)
            packsById = [:]
            if let first = summaries.first {
                await selectPack(first.packId)
            } else {
                selectedPackId = Self.recentPageId
            }
        } catch {
            summaries = []
            packsById = [:]
            loadFailed = true
        }
    }

    private func selectPack(_ packId: String) async {
        selectedPackId = packId
        await ensurePackLoaded(packId)
        await prefetchNeighborManifests(around: packId)
        trimPackCache(around: packId)
    }

    private func ensurePackLoaded(_ packId: String) async {
        guard packId != Self.recentPageId else { return }
        if packsById[packId] != nil { return }
        guard let config else { return }
        do {
            let pack = try await catalog.loadPack(packId: packId, config: config)
            packsById[packId] = pack
        } catch {
            // Leave empty; page shows empty/failed state.
        }
    }

    private func prefetchNeighborManifests(around packId: String) async {
        guard let idx = packPageIds.firstIndex(of: packId) else { return }
        for offset in [-1, 1] {
            let neighbor = idx + offset
            guard packPageIds.indices.contains(neighbor) else { continue }
            await ensurePackLoaded(packPageIds[neighbor])
        }
    }

    /// Drop pack manifests that are far from the current page (views already unmounted).
    private func trimPackCache(around packId: String) {
        guard let idx = packPageIds.firstIndex(of: packId) else { return }
        let keepRadius = Self.activePageRadius + 1
        let keep = Set(
            packPageIds.indices
                .filter { abs($0 - idx) <= keepRadius }
                .map { packPageIds[$0] }
        )
        packsById = packsById.filter { keep.contains($0.key) }
    }

    private func recordRecent(_ ref: StickerRef) {
        var next = recent.filter { $0.bindKey != ref.bindKey }
        next.insert(ref, at: 0)
        if next.count > 24 { next = Array(next.prefix(24)) }
        recent = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
    }

    private func loadRecent() -> [StickerRef] {
        guard let data = UserDefaults.standard.data(forKey: recentKey),
              let decoded = try? JSONDecoder().decode([StickerRef].self, from: data) else {
            return []
        }
        return decoded
    }
}
