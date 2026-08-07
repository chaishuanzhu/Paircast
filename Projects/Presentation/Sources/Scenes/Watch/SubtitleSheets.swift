import SwiftUI
import Domain

// MARK: - Subtitle panel (design 08)

struct SubtitlePanelView: View {
    @ObservedObject var viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSearch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionLabel("当前")
                    groupCard {
                        trackRow(
                            title: "关闭字幕",
                            selected: viewModel.subtitleState.source == .off
                                || viewModel.subtitleState.trackId == "off"
                                || viewModel.subtitleState.trackId == nil
                        ) {
                            Task { await viewModel.selectTrack(.offTrack) }
                        }
                        if let selected = viewModel.selectedSubtitleTrack, selected.source != .off {
                            Divider().padding(.leading, 16)
                            trackRow(title: selected.label, selected: true) {
                                // already selected
                            }
                        }
                    }

                    let embedded = viewModel.subtitleTracks.filter { $0.source == .embedded }
                    if !embedded.isEmpty {
                        sectionLabel("内嵌")
                        groupCard {
                            ForEach(Array(embedded.enumerated()), id: \.element.id) { index, track in
                                if index > 0 { Divider().padding(.leading, 16) }
                                trackRow(
                                    title: track.label,
                                    selected: viewModel.subtitleState.trackId == track.id,
                                    showsChevron: false
                                ) {
                                    Task { await viewModel.selectTrack(track) }
                                }
                            }
                        }
                    }

                    let sidecars = viewModel.subtitleTracks.filter { $0.source == .qiniu }
                    if !sidecars.isEmpty {
                        sectionLabel("片库外挂")
                        groupCard {
                            ForEach(Array(sidecars.enumerated()), id: \.element.id) { index, track in
                                if index > 0 { Divider().padding(.leading, 16) }
                                trackRow(
                                    title: track.label,
                                    subtitle: track.detail,
                                    selected: viewModel.subtitleState.trackId == track.id
                                ) {
                                    Task { await viewModel.selectTrack(track) }
                                }
                            }
                        }
                    }

                    sectionLabel("更多")
                    groupCard {
                        Button {
                            showSearch = true
                        } label: {
                            rowContent(title: "在线搜索", trailing: .chevron)
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 16)

                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                viewModel.showSubtitleSync = true
                            }
                        } label: {
                            rowContent(
                                title: "字幕同步",
                                trailing: .value(viewModel.subtitleState.offsetLabel)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarDoneButton { dismiss() }
                }
            }
            .overlay {
                if viewModel.isApplyingSubtitle {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView("加载字幕…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .sheet(isPresented: $showSearch) {
                OnlineSubtitleSearchView(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task {
                await viewModel.refreshSubtitles()
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(TandemColors.secondaryLabel)
            .padding(.horizontal, 4)
    }

    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(TandemColors.secondaryGrouped)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func trackRow(
        title: String,
        subtitle: String? = nil,
        selected: Bool,
        showsChevron: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            rowContent(
                title: title,
                subtitle: subtitle,
                trailing: selected ? .check : (showsChevron ? .chevron : .none)
            )
        }
        .buttonStyle(.plain)
    }

    private enum Trailing {
        case none
        case check
        case chevron
        case value(String)
    }

    private func rowContent(title: String, subtitle: String? = nil, trailing: Trailing) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(TandemColors.secondaryLabel)
                        .lineLimit(1)
                }
            }
            Spacer()
            switch trailing {
            case .none:
                EmptyView()
            case .check:
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TandemColors.systemBlue)
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TandemColors.tertiaryLabel)
            case .value(let text):
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(TandemColors.secondaryLabel)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TandemColors.tertiaryLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

private extension SubtitleTrack {
    static var offTrack: SubtitleTrack {
        SubtitleTrack(id: "off", label: "关闭字幕", source: .off)
    }
}

// MARK: - Subtitle sync (design 07)

struct SubtitleSyncView: View {
    @ObservedObject var viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(viewModel.subtitleState.offsetLabel.replacingOccurrences(of: "s", with: " s"))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                Text("提前字幕 · 延迟字幕")
                    .font(.system(size: 13))
                    .foregroundStyle(TandemColors.secondaryLabel)

                HStack(spacing: 12) {
                    syncButton("− 0.5s") { viewModel.adjustSubtitle(deltaMs: -500) }
                    syncButton("重置", emphasized: false) { viewModel.resetSubtitleOffset() }
                    syncButton("+ 0.5s", primary: true) { viewModel.adjustSubtitle(deltaMs: 500) }
                }

                HStack(spacing: 12) {
                    syncButton("− 0.1s") { viewModel.adjustSubtitle(deltaMs: -100) }
                    syncButton("+ 0.1s") { viewModel.adjustSubtitle(deltaMs: 100) }
                }

                Button("完成") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("字幕同步")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func syncButton(
        _ title: String,
        primary: Bool = false,
        emphasized: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(primary ? Color.white : TandemColors.systemBlue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(primary ? TandemColors.systemBlue : TandemColors.secondaryGrouped)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(emphasized || primary ? 1 : 1)
    }
}

// MARK: - Online search (design 09 / 20)

struct OnlineSubtitleSearchView: View {
    @ObservedObject var viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("片名 年份", text: $viewModel.onlineQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(TandemColors.secondaryGrouped)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button("搜索") {
                        Task { await viewModel.searchOnline() }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(TandemColors.systemBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(viewModel.isSearchingOnline || viewModel.onlineQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if viewModel.isSearchingOnline {
                    ProgressView("搜索中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.onlineSearchError {
                    ContentUnavailableView {
                        Label("搜索失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重新搜索") { Task { await viewModel.searchOnline() } }
                    }
                } else if viewModel.didSearchOnline && viewModel.onlineResults.isEmpty {
                    ContentUnavailableView {
                        Label("未找到字幕", systemImage: "captions.bubble")
                    } description: {
                        Text("换个关键词试试，或稍后重试")
                    } actions: {
                        Button("重新搜索") { Task { await viewModel.searchOnline() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if !viewModel.onlineResults.isEmpty {
                                Text("搜索结果")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(TandemColors.secondaryLabel)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                            }
                            ForEach(viewModel.onlineResults) { track in
                                Button {
                                    Task {
                                        await viewModel.selectTrack(track)
                                        dismiss()
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(track.label)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(Color.primary)
                                                .multilineTextAlignment(.leading)
                                            if let detail = track.detail {
                                                Text(detail)
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(TandemColors.secondaryLabel)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        if let badge = track.languageBadge, !badge.isEmpty {
                                            Text(badge)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(TandemColors.systemBlue)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(TandemColors.systemBlue.opacity(0.12))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .padding(12)
                                    .background(TandemColors.secondaryGrouped)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("在线搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarCloseButton { dismiss() }
                }
            }
            .overlay {
                if viewModel.isApplyingSubtitle {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView("加载字幕…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .task {
                if viewModel.onlineQuery.isEmpty, let movie = viewModel.movie {
                    viewModel.onlineQuery = [movie.title, movie.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                }
            }
        }
    }
}
