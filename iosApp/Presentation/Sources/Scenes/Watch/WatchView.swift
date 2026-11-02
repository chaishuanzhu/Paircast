import SwiftUI
import UIKit
import PaircastShared

/// SwiftUI adapter over the shared `WatchSession` (join, sync, chat, subtitles live in Kotlin).
/// Only presentation state (sheets, drafts, queries) is owned here.
@MainActor
public final class WatchViewModel: ObservableObject {
    @Published public private(set) var room: WatchRoom?
    @Published public private(set) var movie: Movie?
    @Published public private(set) var playback = PlaybackState(positionMs: 0, isPaused: true, movieId: "", lastSeq: 0)
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public var draft = ""
    @Published public var showSwitchMovie = false
    @Published public var showSwitchConfirm = false
    @Published public var pendingMovie: Movie?
    @Published public var showSubtitlePanel = false
    @Published public var showSubtitleSync = false
    @Published public var showInvite = false
    @Published public private(set) var subtitleTracks: [SubtitleTrack] = []
    @Published public private(set) var subtitleState = SubtitleState.companion.create(movieId: "", offsetMs: 0)
    @Published public var onlineQuery = ""
    @Published public private(set) var onlineResults: [SubtitleTrack] = []
    @Published public private(set) var isSearchingOnline = false
    @Published public private(set) var didSearchOnline = false
    @Published public private(set) var onlineSearchError: String?
    @Published public private(set) var isApplyingSubtitle = false
    @Published public var errorMessage: String?
    @Published public private(set) var libraryMovies: [Movie] = []
    @Published public var switchQuery = ""
    @Published public private(set) var isSwitchingMovie = false
    @Published public private(set) var isLoadingLibraryForSwitch = false
    @Published public private(set) var memberProfiles: [String: User] = [:]
    @Published private var uiState: WatchUiState?

    let session: AppSession
    let player = VLCPlayerController()
    private let watch: WatchSession
    private var stateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var lastStateError: UiText?
    private var lastSuggestedQuery = ""

    public init(session: AppSession, roomId: String?, movieId: String?, hostUserId: String? = nil) {
        self.session = session
        self.watch = session.graph.watchSession(
            player: player,
            roomId: roomId,
            movieId: movieId,
            hostUserId: hostUserId
        )
    }

    public var isHost: Bool { uiState?.isHost ?? false }

    public var filteredLibraryMovies: [Movie] {
        let query = switchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return libraryMovies }
        return libraryMovies.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.year?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    public var selectedSubtitleTrack: SubtitleTrack? { uiState?.selectedSubtitleTrack }

    public func start() async {
        guard stateTask == nil else { return }
        let stateFlow = watch.state
        stateTask = Task { [weak self] in
            for await state in stateFlow {
                self?.apply(state)
            }
        }
        let events = watch.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        watch.start()
    }

    public func stop() {
        stateTask?.cancel()
        eventTask?.cancel()
        stateTask = nil
        eventTask = nil
        watch.close()
    }

    private func apply(_ state: WatchUiState) {
        uiState = state
        room = state.room
        movie = state.movie
        playback = state.playback
        messages = state.messages
        subtitleTracks = state.subtitleTracks
        subtitleState = state.subtitleState
        onlineResults = state.onlineResults
        isSearchingOnline = state.isSearchingOnline
        didSearchOnline = state.didSearchOnline
        onlineSearchError = state.onlineSearchError.map { TandemL10n.format($0) }
        isApplyingSubtitle = state.isApplyingSubtitle
        libraryMovies = state.libraryMovies
        isSwitchingMovie = state.isSwitchingMovie
        isLoadingLibraryForSwitch = state.isLoadingLibraryForSwitch
        memberProfiles = state.memberProfiles
        if state.suggestedOnlineQuery != lastSuggestedQuery {
            lastSuggestedQuery = state.suggestedOnlineQuery
            onlineQuery = state.suggestedOnlineQuery
        }
        if state.error != lastStateError {
            lastStateError = state.error
            if let error = state.error {
                errorMessage = TandemL10n.format(error)
            }
        }
    }

    private func handle(_ event: WatchEvent) {
        switch onEnum(of: event) {
        case .toast(let toast):
            session.showToast(TandemL10n.format(toast.text))
        case .left:
            session.popLibraryToRoot()
        }
    }

    /// Playback fraction 0...1 for a member's progress ring.
    /// Self uses the local player; others use last applied sync position (follow model).
    public func memberPlaybackProgress(for memberId: String) -> Double {
        watch.memberPlaybackProgress(memberId: memberId)
    }

    public func memberDisplayName(for memberId: String) -> String {
        if memberId == session.currentUser?.id, let nick = session.currentUser?.nickname, !nick.isEmpty {
            return nick
        }
        return uiState?.memberDisplayName(memberId: memberId) ?? memberId
    }

    public func memberAvatarURL(for memberId: String) -> URL? {
        if memberId == session.currentUser?.id, let url = session.currentUser?.avatarURL {
            return url
        }
        return uiState?.memberAvatarUrl(memberId: memberId).flatMap(URL.init(string:))
    }

    public func togglePlay() {
        watch.togglePlay()
    }

    public func seekTo(ms: Int64) {
        watch.seekTo(positionMs: ms)
    }

    public func seekToProgress(_ progress: Double) {
        watch.seekToProgress(progress: progress)
    }

    public func requestSwitch(_ movie: Movie) {
        guard isHost else {
            session.showToast(TandemL10n.format(AppError.onlyHostCanSwitchMovie))
            return
        }
        if movie.id == self.movie?.id {
            showSwitchMovie = false
            session.showToast(TandemL10n.string("Already playing"))
            return
        }
        pendingMovie = movie
        showSwitchMovie = false
        // Dismiss sheet first so the confirm alert isn't buried under it.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            self?.showSwitchConfirm = true
        }
    }

    public func cancelSwitchConfirm() {
        showSwitchConfirm = false
        pendingMovie = nil
    }

    public func loadLibraryForSwitch() async {
        switchQuery = ""
        watch.loadLibraryForSwitch()
    }

    public func confirmSwitch() async {
        // Snapshot before the alert dismisses — do not clear pendingMovie on alert close,
        // or this guard fails and the switch silently no-ops.
        guard let target = pendingMovie, !isSwitchingMovie else { return }
        showSwitchConfirm = false
        pendingMovie = nil
        showSwitchMovie = false
        watch.confirmSwitch(target: target)
    }

    public func sendChat() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        watch.sendChat(text: text)
    }

    public func sendSticker(_ sticker: StickerRef) async {
        watch.sendSticker(sticker: sticker)
    }

    public func canModerate(_ message: ChatMessage) -> Bool {
        uiState?.canModerate(message: message) ?? false
    }

    public func blockSender(of message: ChatMessage) {
        watch.blockSender(message: message)
    }

    public func report(_ message: ChatMessage) {
        watch.report(message: message)
    }

    public var chatReportURL: URL {
        URL(string: ChatSafetyStore.companion.REPORT_URL)!
    }

    public func refreshSubtitles(autoSelectChinese: Bool = false) async {
        watch.refreshSubtitles(autoSelectChinese: autoSelectChinese)
    }

    public func selectTrack(_ track: SubtitleTrack) async {
        watch.selectTrack(track: track)
    }

    public func adjustSubtitle(deltaMs: Int) {
        watch.adjustSubtitle(deltaMs: Int32(deltaMs))
    }

    public func resetSubtitleOffset() {
        watch.resetSubtitleOffset()
    }

    public func searchOnline() async {
        watch.searchOnline(query: onlineQuery)
    }

    public func inviteURL() -> URL {
        URL(string: watch.inviteUrl()) ?? URL(string: InviteLinks.shared.INVITE_BASE)!
    }

    public func inviteMessage() -> String {
        let inviter = session.currentUser?.nickname ?? session.currentUser?.id ?? ""
        return TandemL10n.format(
            "{{inviter}} invites you to watch {{title}}. Come join!",
            [
                "inviter": inviter,
                "title": movie?.title ?? "",
            ]
        )
    }

    public func leave() async {
        guard room != nil else {
            stop()
            session.popLibraryToRoot()
            return
        }
        watch.leave()
    }
}

public extension SubtitleTrack {
    static var offTrack: SubtitleTrack { SubtitleTrack.companion.OFF }
}

public struct WatchView: View {
    @ObservedObject var session: AppSession
    @ObservedObject var theme: ThemeStore
    @StateObject private var viewModel: WatchViewModel
    @State private var showMoreMenu = false
    @State private var showPlayerChrome = true
    @State private var isFullscreen = false
    @State private var scrubProgress: CGFloat?
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var showEmojiPanel = false
    /// True while the text field is first-responder (more reliable than keyboard frame alone).
    @State private var isComposerFocused = false
    /// Bumped to ask `TwemojiComposerField` to become first responder (emoji → keyboard).
    @State private var composerFocusRequest = 0
    @StateObject private var keyboardInset = KeyboardInsetObserver()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale

    private static let chromeAutoHideSeconds: UInt64 = 5_000_000_000
    private static let compactStageHeight: CGFloat = 248

    public init(session: AppSession, theme: ThemeStore, roomId: String?, movieId: String?, hostUserId: String? = nil) {
        self.session = session
        self.theme = theme
        _viewModel = StateObject(wrappedValue: WatchViewModel(
            session: session,
            roomId: roomId,
            movieId: movieId,
            hostUserId: hostUserId
        ))
    }

    public var body: some View {
        // 播放器必须始终处在视图树的同一位置：一旦 SwiftUI 因分支切换重建
        // VLCPlayerView，VLC 的 drawable 会被摘出窗口，vout 销毁后不再重建（黑屏）。
        GeometryReader { proxy in
            let stageH = isFullscreen ? proxy.size.height : stageHeight(in: proxy.size)
            // Reserve space above the keyboard for chat + input; video stays fixed.
            let keyboardLift = (isFullscreen || showEmojiPanel) ? 0 : keyboardInset.inset
            // Members hide only while actively composing — don't tie this to keyboard
            // frame (inset can lag / stick after emoji ↔ keyboard switches).
            let composing = showEmojiPanel || isComposerFocused

            VStack(spacing: 0) {
                playerStage(height: isFullscreen ? nil : stageH)
                    .frame(height: stageH)
                    .frame(maxWidth: .infinity)

                if !isFullscreen {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if !composing {
                                membersBar
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            chatList
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .layoutPriority(0)
                                .contentShape(Rectangle())
                                .onTapGesture { dismissKeyboardAndEmojiPanel() }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()

                        VStack(spacing: 0) {
                            chatInput
                            if showEmojiPanel {
                                ChatEmojiStickerPanel(
                                    draft: $viewModel.draft,
                                    catalog: session.stickerCatalog,
                                    config: session.config,
                                    onSendSticker: { ref in
                                        Task { await viewModel.sendSticker(ref) }
                                    }
                                )
                            }
                            // Fill the reserved strip above the keyboard (and home
                            // indicator when idle) with the toolbar color.
                            TandemColors.secondaryGrouped
                                .frame(height: keyboardLift)
                                .frame(maxWidth: .infinity)
                        }
                        .layoutPriority(1)
                        .background(TandemColors.secondaryGrouped.ignoresSafeArea(edges: .bottom))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .animation(.easeInOut(duration: 0.22), value: composing)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .disableHostingKeyboardAvoidance()
        .background(TandemColors.groupedBackground.ignoresSafeArea())
        .ignoresSafeArea(edges: isFullscreen ? .all : [])
        .statusBarHidden(isFullscreen)
        .onChange(of: isFullscreen) { _, fullscreen in
            applyFullscreenOrientation(fullscreen)
        }
        .onChange(of: showEmojiPanel) { _, open in
            if open {
                isComposerFocused = false
                keyboardInset.reset()
            }
        }
        .task {
            await viewModel.start()
            revealPlayerChrome()
        }
        .onDisappear {
            chromeHideTask?.cancel()
            keyboardInset.reset()
            OrientationLock.lock(.portrait)
            viewModel.stop()
        }
        .onReceive(viewModel.player.$lastError.compactMap { $0 }) { message in
            viewModel.errorMessage = message
        }
        .sheet(isPresented: $viewModel.showSwitchMovie) {
            SwitchMovieSheet(viewModel: viewModel)
                .environment(\.locale, locale)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "Switch movie",
            isPresented: $viewModel.showSwitchConfirm
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelSwitchConfirm()
            }
            Button("Switch") {
                Task { await viewModel.confirmSwitch() }
            }
        } message: {
            if let title = viewModel.pendingMovie?.title {
                Text(TandemL10n.format(
                    "Switch to “{{title}}” and play from the start. Everyone syncs to the new movie.",
                    ["title": title]
                ))
            } else {
                Text("Playback will restart from the beginning. Everyone syncs to the new movie.")
            }
        }
        .sheet(isPresented: $viewModel.showSubtitlePanel) {
            SubtitlePanelView(viewModel: viewModel)
                .environment(\.locale, locale)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showSubtitleSync) {
            SubtitleSyncView(viewModel: viewModel)
                .environment(\.locale, locale)
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showInvite) {
            InviteSheetView(url: viewModel.inviteURL(), message: viewModel.inviteMessage())
                .environment(\.locale, locale)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("More", isPresented: $showMoreMenu, titleVisibility: .hidden) {
            Button("Subtitles") { viewModel.showSubtitlePanel = true }
            Button("Subtitle Sync") { viewModel.showSubtitleSync = true }
            Button("Cancel", role: .cancel) {}
        }
        .overlay {
            if viewModel.isSwitchingMovie {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("Switching movie…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .allowsHitTesting(true)
            }
        }
    }

    // MARK: - Player chrome visibility

    private func revealPlayerChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showPlayerChrome = true
        }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task {
            try? await Task.sleep(nanoseconds: Self.chromeAutoHideSeconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard scrubProgress == nil else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    showPlayerChrome = false
                }
            }
        }
    }

    private func togglePlayerChrome() {
        if showPlayerChrome {
            chromeHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) {
                showPlayerChrome = false
            }
        } else {
            revealPlayerChrome()
        }
    }

    private func notePlayerInteraction() {
        revealPlayerChrome()
    }

    private func applyFullscreenOrientation(_ fullscreen: Bool) {
        OrientationLock.lock(fullscreen ? .landscape : .portrait)
        if fullscreen {
            revealPlayerChrome()
        }
    }

    /// iPad portrait gives the stage a full-width 16:9 box; compact widths keep the fixed bar.
    private func stageHeight(in container: CGSize) -> CGFloat {
        let isRegularPortrait = horizontalSizeClass == .regular && container.height >= container.width
        guard isRegularPortrait, container.width > 0 else { return Self.compactStageHeight }
        let sixteenByNine = container.width * 9 / 16
        return min(sixteenByNine, container.height * 0.5).rounded()
    }

    private func playerStage(height: CGFloat?) -> some View {
        ZStack {
            VLCPlayerView(videoView: viewModel.player.videoView) {
                viewModel.player.refreshDrawable()
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // UIViewRepresentable 会吞掉触摸，不能依赖它上面的 onTapGesture

            // Prefer landscape fanart; fall back to poster. Bound to the stage so
            // portrait posters cannot inflate the chrome VStack.
            if !viewModel.player.hasStartedPlayback {
                GeometryReader { coverProxy in
                    PosterImage(
                        url: viewModel.movie?.backdropURL ?? viewModel.movie?.posterURL
                    )
                    .frame(width: coverProxy.size.width, height: coverProxy.size.height)
                    .clipped()
                }
                .allowsHitTesting(false)
            }

            // 透明点击层：点画面切换工具栏。必须盖在 VLC 之上，
            // 否则自动隐藏后无法再唤出（UIKit 视频视图不转发手势给 SwiftUI）。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { togglePlayerChrome() }

            LinearGradient(
                colors: [
                    Color.black.opacity(showPlayerChrome ? 0.55 : 0),
                    Color.clear,
                    Color.black.opacity(showPlayerChrome ? 0.72 : 0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: showPlayerChrome)

            VStack(spacing: 0) {
                watchChrome
                    .padding(.top, isFullscreen ? 12 : 8)
                // 中间留空把点击交给下层，避免挡住「点视频切换工具栏」
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                playerBottomChrome
            }
            .padding(.horizontal, 12)
            .padding(.bottom, isFullscreen ? 20 : 10)
            .opacity(showPlayerChrome ? 1 : 0)
            .allowsHitTesting(showPlayerChrome)
            .animation(.easeInOut(duration: 0.2), value: showPlayerChrome)

            if !viewModel.player.isReady {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Buffering…")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .background(Color.black)
        .overlay(alignment: .top) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(TandemColors.danger.opacity(0.9))
                    .clipShape(Capsule())
                    .padding(.top, isFullscreen ? 56 : 52)
            }
        }
    }

    private var movieTitleLabel: Text {
        if let title = viewModel.movie?.title, !title.isEmpty {
            Text(title)
        } else {
            Text("Movie")
        }
    }

    private var watchChrome: some View {
        HStack(spacing: 6) {
            Button {
                notePlayerInteraction()
                if isFullscreen {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isFullscreen = false
                    }
                } else {
                    Task { await viewModel.leave() }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            }
            .accessibilityLabel(isFullscreen ? "Exit fullscreen" : "Back")

            movieTitleLabel
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                notePlayerInteraction()
                if viewModel.isHost {
                    viewModel.showSwitchMovie = true
                } else {
                    session.showToast(TandemL10n.format(AppError.onlyHostCanSwitchMovie))
                }
            } label: {
                Text("Switch")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(viewModel.isHost ? 1 : 0.55))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.black.opacity(viewModel.isHost ? 0.18 : 0.08))
                    .overlay {
                        Capsule().stroke(Color.white.opacity(viewModel.isHost ? 0.85 : 0.4), lineWidth: 1)
                    }
                    .clipShape(Capsule())
            }
            .accessibilityLabel("Switch movie")
            .accessibilityHint(viewModel.isHost ? "Open the library to switch the current movie" : "Only the host can switch movies")

            Button {
                notePlayerInteraction()
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("More")
        }
    }

    private var playerBottomChrome: some View {
        VStack(spacing: 8) {
            if viewModel.subtitleState.source != .off, viewModel.subtitleState.offsetMs != 0 {
                Text(TandemL10n.format(
                    "Subtitles {{offset}}",
                    ["offset": viewModel.subtitleState.offsetLabel]
                ))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                    .padding(.horizontal, 8)
            }

            HStack(spacing: 10) {
                Button {
                    notePlayerInteraction()
                    viewModel.togglePlay()
                } label: {
                    Image(systemName: viewModel.player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
                .disabled(!viewModel.isHost)
                .opacity(viewModel.isHost ? 0.95 : 0.45)

                Button {
                    notePlayerInteraction()
                    viewModel.showSubtitlePanel = true
                } label: {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Subtitles")

                progressBar
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)

                Text(timeLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)

                Button {
                    notePlayerInteraction()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isFullscreen.toggle()
                    }
                } label: {
                    Image(systemName: isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(isFullscreen ? "Exit fullscreen" : "Fullscreen")
            }
            .foregroundStyle(.white)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let progress = scrubProgress ?? playbackProgress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(3, width * progress), height: 3)
                if viewModel.isHost {
                    Circle()
                        .fill(Color.white)
                        .frame(width: scrubProgress == nil ? 8 : 12, height: scrubProgress == nil ? 8 : 12)
                        .offset(x: max(0, width * progress - (scrubProgress == nil ? 4 : 6)))
                        .animation(.easeOut(duration: 0.12), value: scrubProgress == nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(progressDragGesture(width: width), including: viewModel.isHost ? .gesture : .none)
            .accessibilityLabel("Playback progress")
            .accessibilityValue("\(Int((progress * 100).rounded()))%")
            .opacity(viewModel.isHost ? 1 : 0.9)
        }
    }

    private func progressDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard viewModel.isHost else { return }
                chromeHideTask?.cancel()
                showPlayerChrome = true
                scrubProgress = CGFloat(min(1, max(0, value.location.x / width)))
            }
            .onEnded { value in
                guard viewModel.isHost else { return }
                let progress = Double(min(1, max(0, value.location.x / width)))
                scrubProgress = nil
                viewModel.seekToProgress(progress)
                scheduleChromeHide()
            }
    }

    private var playbackProgress: CGFloat {
        let duration = max(viewModel.player.durationMs, 1)
        return CGFloat(min(1, max(0, Double(viewModel.player.positionMs) / Double(duration))))
    }

    private var timeLabel: String {
        let duration = max(viewModel.player.durationMs, 1)
        let position: Int64
        if let scrubProgress {
            position = Int64(Double(duration) * Double(scrubProgress))
        } else {
            position = viewModel.player.positionMs
        }
        let current = TandemColors.formatPlaybackTime(position)
        let total = TandemColors.formatPlaybackTime(viewModel.player.durationMs)
        return "\(current)/\(total)"
    }

    private var watchingCountText: Text {
        let count = viewModel.room?.memberIds.count ?? 0
        return Text(verbatim: TandemL10n.format(
            "{{count}} watching",
            ["count": String(count)]
        ))
    }

    private var membersBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                watchingCountText
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TandemColors.secondaryLabel)
                Spacer()
                Text(
                    viewModel.isHost
                        ? LocalizedStringKey("You are the host — you control playback")
                        : LocalizedStringKey("Following the host")
                )
                    .font(.system(size: 12))
                    .foregroundStyle(TandemColors.secondaryLabel)
                    .lineLimit(1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.room?.memberIds ?? [], id: \.self) { id in
                        MemberPlaybackAvatar(
                            userId: id,
                            displayName: viewModel.memberDisplayName(for: id),
                            avatarURL: viewModel.memberAvatarURL(for: id),
                            isHost: id == viewModel.room?.hostUserId,
                            progress: { viewModel.memberPlaybackProgress(for: id) },
                            size: 40
                        )
                    }
                    Button {
                        viewModel.showInvite = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(TandemColors.groupedBackground)
                            Circle()
                                .strokeBorder(
                                    TandemColors.opaqueSeparator,
                                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                                )
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(TandemColors.secondaryLabel)
                        }
                        .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Invite")
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(TandemColors.secondaryGrouped)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TandemColors.separator)
                .frame(height: 1)
        }
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        chatRow(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Text("Invite-only room · Long-press a message to block or report")
                    .font(.system(size: 11))
                    .foregroundStyle(TandemColors.tertiaryLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TandemColors.groupedBackground)
        .contentShape(Rectangle())
    }

    private func dismissKeyboardAndEmojiPanel() {
        isComposerFocused = false
        keyboardInset.reset()
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        if showEmojiPanel {
            withAnimation(.easeInOut(duration: 0.2)) {
                showEmojiPanel = false
            }
        }
    }

    private func toggleEmojiPanel() {
        if showEmojiPanel {
            // Keyboard icon: leave sticker panel and bring the system keyboard back.
            withAnimation(.easeInOut(duration: 0.2)) {
                showEmojiPanel = false
            }
            composerFocusRequest += 1
        } else {
            // Face icon: show sticker panel and drop the system keyboard.
            isComposerFocused = false
            keyboardInset.reset()
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                showEmojiPanel = true
            }
        }
    }

    private func localizedSystemMessage(_ text: String) -> String {
        let transferPrefix = "Host transferred to "
        if text.hasPrefix(transferPrefix) {
            let userId = String(text.dropFirst(transferPrefix.count))
            return TandemL10n.format(
                "Host is now {{name}}",
                ["name": viewModel.memberDisplayName(for: userId)]
            )
        }

        let switchPrefix = "Host switched the movie to “"
        if text.hasPrefix(switchPrefix), text.hasSuffix("”") {
            let title = text
                .dropFirst(switchPrefix.count)
                .dropLast()
            return TandemL10n.format(
                "Host switched the movie to “{{title}}”",
                ["title": String(title)]
            )
        }

        return text
    }

    private func chatAvatar(_ message: ChatMessage) -> some View {
        TandemAvatarView(
            userId: message.senderNickname.isEmpty ? (message.senderId ?? "?") : message.senderNickname,
            size: 32,
            avatarURL: message.senderId.flatMap { viewModel.memberAvatarURL(for: $0) }
        )
    }

    @ViewBuilder
    private func chatRow(_ message: ChatMessage) -> some View {
        if message.kind == .system {
            Text(verbatim: localizedSystemMessage(message.text))
                .font(.system(size: 12))
                .foregroundStyle(TandemColors.tertiaryLabel)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            let isMe = message.senderId == session.currentUser?.id
            HStack(alignment: .top, spacing: 8) {
                if !isMe {
                    chatAvatar(message)
                }
                VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                    if !isMe {
                        Text(message.senderNickname)
                            .font(.system(size: 12))
                            .foregroundStyle(TandemColors.secondaryLabel)
                    }
                    if message.kind == .sticker, let sticker = message.sticker {
                        StickerImageView(
                            ref: sticker,
                            catalog: session.stickerCatalog,
                            config: session.config,
                            side: 120
                        )
                    } else {
                        TwemojiText(
                            message.text,
                            font: .system(size: 15),
                            foreground: isMe ? Color.white : Color.primary,
                            emojiSize: 18
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isMe ? TandemColors.systemBlue : TandemColors.secondaryGrouped)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: isMe ? 16 : 6,
                            bottomTrailingRadius: isMe ? 6 : 16,
                            topTrailingRadius: 16,
                            style: .continuous
                        ))
                        .shadow(color: isMe ? .clear : Color.primary.opacity(0.06), radius: 1, y: 1)
                    }
                }
                if isMe {
                    chatAvatar(message)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            .padding(isMe ? .leading : .trailing, 40)
            .contextMenu {
                if viewModel.canModerate(message) {
                    Button("Block User", role: .destructive) {
                        viewModel.blockSender(of: message)
                    }
                    Button("Report") {
                        viewModel.report(message)
                        openURL(viewModel.chatReportURL)
                    }
                }
            }
        }
    }

    private var chatInput: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    toggleEmojiPanel()
                } label: {
                    Image(systemName: showEmojiPanel ? "keyboard" : "face.smiling")
                        .font(.system(size: 22))
                        .foregroundStyle(TandemColors.systemBlue)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                TwemojiComposerField(
                    text: $viewModel.draft,
                    placeholder: TandemL10n.string("Say something…"),
                    isEmojiPanelOpen: showEmojiPanel,
                    focusRequest: composerFocusRequest,
                    onBeganEditing: {
                        isComposerFocused = true
                        if showEmojiPanel {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showEmojiPanel = false
                            }
                        }
                    },
                    onEndedEditing: {
                        isComposerFocused = false
                    }
                )
                .frame(minHeight: 40)
                .background(TandemColors.groupedBackground)
                .clipShape(Capsule())

                Button {
                    Task { await viewModel.sendChat() }
                } label: {
                    Text("Send")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(TandemColors.systemBlue)
                        .clipShape(Capsule())
                }
                .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(TandemColors.secondaryGrouped)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TandemColors.separator)
                .frame(height: 1)
        }
    }
}

private struct SwitchMovieSheet: View {
    @ObservedObject var viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingLibraryForSwitch && viewModel.libraryMovies.isEmpty {
                    ProgressView("Loading library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredLibraryMovies.isEmpty {
                    if viewModel.switchQuery.isEmpty {
                        ContentUnavailableView(
                            "No movies",
                            systemImage: "film",
                            description: Text("Make sure your object storage bucket contains mp4/m4v/mkv files")
                        )
                    } else {
                        ContentUnavailableView(
                            "No matching movies",
                            systemImage: "film",
                            description: Text("Try different keywords")
                        )
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.filteredLibraryMovies) { movie in
                                SwitchMovieRow(
                                    movie: movie,
                                    isPlaying: movie.id == viewModel.movie?.id
                                ) {
                                    viewModel.requestSwitch(movie)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .searchable(text: $viewModel.switchQuery, prompt: "Search titles")
            .navigationTitle("Switch Movie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarCloseButton { dismiss() }
                }
            }
            .overlay {
                if viewModel.isSwitchingMovie {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        ProgressView("Switching movie…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .task {
                await viewModel.loadLibraryForSwitch()
            }
        }
    }
}

private struct SwitchMovieRow: View {
    let movie: Movie
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                    .frame(width: 44, height: 66)
                    .overlay {
                        PosterImage(url: movie.posterURL)
                            .frame(width: 44, height: 66)
                            .clipped()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(movie.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(TandemColors.secondaryLabel)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isPlaying {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(TandemColors.systemBlue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(TandemColors.secondaryGrouped)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(movie.title)
        .accessibilityValue(isPlaying ? TandemL10n.string("Playing") : (movie.year ?? ""))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = movie.year, !year.isEmpty {
            parts.append(year)
        }
        if isPlaying {
            parts.append(TandemL10n.string("Playing"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct InviteSheetView: View {
    let url: URL
    let message: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 0) {
                        ShareLink(item: url, message: Text(message)) {
                            inviteRow(title: "System Share", trailing: .chevron)
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 16)

                        Button {
                            UIPasteboard.general.string = url.absoluteString
                            copied = true
                        } label: {
                            inviteRow(
                                title: "Copy Invite Link",
                                trailing: .text(
                                    copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"),
                                    emphasized: copied
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .background(TandemColors.secondaryGrouped)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("Link preview")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TandemColors.secondaryLabel)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)

                    Text(url.absoluteString)
                        .font(.system(size: 13))
                        .foregroundStyle(TandemColors.secondaryLabel)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(TandemColors.secondaryGrouped)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("After friends open the link and sign in, they join this watch room and sync playback.")
                        .font(.system(size: 13))
                        .foregroundStyle(TandemColors.secondaryLabel)
                        .lineSpacing(2)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(TandemColors.groupedBackground.ignoresSafeArea())
            .navigationTitle("Invite Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarCloseButton(accessibilityLabel: "Close") { dismiss() }
                }
            }
        }
    }

    private enum Trailing {
        case chevron
        case text(LocalizedStringKey, emphasized: Bool)
    }

    private func inviteRow(title: LocalizedStringKey, trailing: Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Color.primary)
            Spacer()
            switch trailing {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TandemColors.tertiaryLabel)
            case .text(let value, let emphasized):
                Text(value)
                    .font(.system(size: 15, weight: emphasized ? .semibold : .regular))
                    .foregroundStyle(emphasized ? Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255) : TandemColors.systemBlue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
