import SwiftUI
import Domain

/// Bottom accessory: Twemoji grid + OSS sticker packs.
struct ChatEmojiStickerPanel: View {
    enum Tab: Hashable {
        case emoji
        case stickers
    }

    @Binding var draft: String
    let catalog: StickerCatalogGateway
    let config: AppCloudConfig?
    let onSendSticker: (StickerRef) -> Void

    @State private var tab: Tab = .emoji
    @State private var summaries: [StickerPackSummary] = []
    @State private var selectedPackId: String?
    @State private var pack: StickerPack?
    @State private var recent: [StickerRef] = []
    @State private var loading = false
    @State private var loadFailed = false

    private let recentKey = "paircast.stickers.recent"
    private let panelHeight: CGFloat = 280

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
            if new == .stickers, pack == nil, let first = summaries.first {
                Task { await selectPack(first.packId) }
            }
        }
    }

    private var configFingerprint: String {
        guard let s = config?.storage else { return "" }
        return [s.bucket, s.endpoint, s.prefix ?? ""].joined(separator: "|")
    }

    private var emojiGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8),
                spacing: 10
            ) {
                ForEach(Twemoji.pickerEmojis, id: \.self) { emoji in
                    Button {
                        draft.append(emoji)
                    } label: {
                        TwemojiImage(emoji: emoji, size: 28)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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
                stickerGrid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var packBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                packChip(id: "__recent__", title: "Recent")
                ForEach(summaries) { summary in
                    packChip(id: summary.packId, title: summary.name)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 28)
    }

    private func packChip(id: String, title: String) -> some View {
        Button {
            Task {
                if id == "__recent__" {
                    selectedPackId = "__recent__"
                    pack = nil
                } else {
                    await selectPack(id)
                }
            }
        } label: {
            Text(shortTitle(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected(id) ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected(id) ? TandemColors.systemBlue : TandemColors.groupedBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shortTitle(_ title: String) -> String {
        if title.count <= 10 { return title }
        return String(title.prefix(10)) + "…"
    }

    private func isSelected(_ id: String) -> Bool {
        if id == "__recent__" {
            return selectedPackId == "__recent__"
        }
        return selectedPackId == id
    }

    private var stickerGrid: some View {
        let items: [StickerRef] = {
            if selectedPackId == "__recent__" {
                return recent
            }
            return pack?.stickers.map { $0.asRef() } ?? []
        }()

        return Group {
            if items.isEmpty {
                emptyState(selectedPackId == "__recent__" ? "No recent stickers" : "No stickers in this pack")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 2), count: 4),
                        spacing: 2
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
                                    side: nil
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            }
        }
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
            loadFailed = false
            return
        }
        loading = true
        loadFailed = false
        defer { loading = false }
        do {
            summaries = try await catalog.loadCatalog(config: config)
            if let first = summaries.first {
                await selectPack(first.packId)
            }
        } catch {
            summaries = []
            loadFailed = true
        }
    }

    private func selectPack(_ packId: String) async {
        selectedPackId = packId
        guard let config else { return }
        do {
            pack = try await catalog.loadPack(packId: packId, config: config)
        } catch {
            pack = nil
        }
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
