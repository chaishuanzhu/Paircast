import SwiftUI
import UIKit
import Domain

@MainActor
public final class WatchViewModel: ObservableObject {
    @Published public var room: WatchRoom?
    @Published public var movie: Movie?
    @Published public var playback = PlaybackState(movieId: "")
    @Published public var messages: [ChatMessage] = []
    @Published public var draft = ""
    @Published public var syncLabel = ""
    @Published public var showSwitchMovie = false
    @Published public var showSwitchConfirm = false
    @Published public var pendingMovie: Movie?
    @Published public var showSubtitlePanel = false
    @Published public var showSubtitleSync = false
    @Published public var showInvite = false
    @Published public var subtitleTracks: [SubtitleTrack] = []
    @Published public var subtitleState = SubtitleState(movieId: "")
    @Published public var onlineQuery = ""
    @Published public var onlineResults: [SubtitleTrack] = []
    @Published public var errorMessage: String?
    @Published public var libraryMovies: [Movie] = []

    let session: AppSession
    let initialRoomId: String?
    let initialMovieId: String?
    let initialHostUserId: String?
    private var seq: UInt64 = 1
    let player = VLCPlayerController()
    private var signalTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var roomTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    public init(session: AppSession, roomId: String?, movieId: String?, hostUserId: String? = nil) {
        self.session = session
        self.initialRoomId = roomId
        self.initialMovieId = movieId
        self.initialHostUserId = hostUserId
    }

    public var isHost: Bool {
        guard let room, let user = session.currentUser else { return false }
        return room.hostUserId == user.id
    }

    public func start() async {
        do {
            if let roomId = initialRoomId, let user = session.currentUser {
                let joined = try await session.roomGateway.joinRoom(
                    roomId: roomId,
                    userId: user.id,
                    movieId: initialMovieId,
                    hostUserId: initialHostUserId
                )
                room = joined
                // Prefer live room movie over invite snapshot (host may have switched).
                await loadMovie(id: joined.movieId)
            }
            guard let room, let movie else { return }
            playback = PlaybackState(movieId: movie.id, lastSeq: room.lastAppliedSeq)
            seq = max(seq, room.lastAppliedSeq + 1)
            subtitleState = SubtitleState(movieId: movie.id)
            syncLabel = isHost ? "你是房主，进度由你控制" : "跟随房主中"
            onlineQuery = movie.title
            await preparePlayer()
            listen()
            startHeartbeatIfNeeded()
            await refreshSubtitles()
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.playbackFailed.userMessage
        }
    }

    public func stop() {
        signalTask?.cancel()
        chatTask?.cancel()
        roomTask?.cancel()
        heartbeatTask?.cancel()
        signalTask = nil
        chatTask = nil
        roomTask = nil
        heartbeatTask = nil
        player.stop()
    }

    private func loadMovie(id: String) async {
        let harness = LibraryHarness(session: session)
        let movies = (try? await harness.listMovies(enrichMetadata: false)) ?? []
        libraryMovies = movies
        movie = movies.first(where: { $0.id == id }) ?? Movie(
            id: id,
            objectKey: id,
            title: id,
            format: VideoFormat(filename: id) ?? .mp4
        )
    }

    private func preparePlayer() async {
        guard let movie else { return }
        TandemLog.playback.info(
            "preparePlayer movie=\(movie.objectKey, privacy: .public) format=\(movie.format.rawValue, privacy: .public)"
        )
        player.stop()
        do {
            let config = try await session.configGateway.load() ?? AppCloudConfig(
                im: .init(sdkAppId: 0, secretKey: ""),
                qiniu: .init(accessKey: "", secretKey: "", bucket: "", endpoint: "")
            )
            let url = try await session.catalogGateway.playURL(for: movie, config: config)
            try await player.prepare(url: url)
            if let playerError = player.lastError {
                TandemLog.playback.error("preparePlayer playerError=\(playerError, privacy: .public)")
                errorMessage = playerError
            }
        } catch let error as AppError {
            TandemLog.playback.error("preparePlayer AppError=\(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        } catch {
            TandemLog.playback.error("preparePlayer error=\(String(describing: error), privacy: .public)")
            errorMessage = AppError.playbackFailed.userMessage
        }
    }

    private func listen() {
        guard let room else { return }
        signalTask?.cancel()
        chatTask?.cancel()
        roomTask?.cancel()

        signalTask = Task {
            for await signal in session.syncGateway.signals(roomId: room.id) {
                await MainActor.run {
                    applyRemote(signal)
                }
            }
        }
        chatTask = Task {
            for await message in session.chatGateway.messages(roomId: room.id) {
                await MainActor.run {
                    messages.append(message)
                }
            }
        }
        roomTask = Task {
            for await updated in session.roomGateway.observeRoom(roomId: room.id) {
                await MainActor.run {
                    self.room = updated
                    syncLabel = isHost ? "你是房主，进度由你控制" : "跟随房主中"
                    if updated.status == .ended {
                        errorMessage = AppError.roomEnded.userMessage
                    }
                }
            }
        }
    }

    private func startHeartbeatIfNeeded() {
        heartbeatTask?.cancel()
        guard isHost else { return }
        heartbeatTask = Task { [weak self] in
            let interval = UInt64(PlaybackSyncRules.foregroundHeartbeatSeconds * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await MainActor.run {
                    self?.emitHeartbeat()
                }
            }
        }
    }

    private func emitHeartbeat() {
        // Avoid resume-via-heartbeat while paused (rules force isPaused=false on heartbeat).
        guard isHost, let room, let user = session.currentUser, !player.isPaused else { return }
        seq += 1
        let position = player.currentPositionMs
        let currentSeq = seq
        Task {
            let harness = SyncHarness(session: session)
            _ = try? await harness.emitHostSignal(
                room: room,
                hostUserId: user.id,
                action: .heartbeat,
                positionMs: position,
                seq: currentSeq
            )
            playback.positionMs = position
            playback.lastSeq = currentSeq
        }
    }

    private func applyRemote(_ signal: PlaybackSyncSignal) {
        guard var room else { return }
        let result = PlaybackSyncRules.shouldAccept(signal: signal, room: room, current: playback)
        switch result {
        case .ignored:
            return
        case .applied(let state):
            playback = state
            if signal.action == .hostTransfer, let newHost = signal.hostUserId {
                room.hostUserId = newHost
                room.hostTransferSeq = signal.seq
                self.room = room
                syncLabel = isHost ? "你是房主，进度由你控制" : "跟随房主中"
                session.showToast("房主已变为 \(newHost)")
                startHeartbeatIfNeeded()
            }
            if signal.action == .movieChange, let movieId = signal.movieId {
                Task {
                    await loadMovie(id: movieId)
                    subtitleState = SubtitleState.resetForMovieChange(movieId: movieId)
                    await preparePlayer()
                }
            }
            player.seek(toMs: state.positionMs)
            if state.isPaused {
                player.pause()
            } else {
                player.play()
            }
        }
    }

    public func togglePlay() {
        guard isHost, let room, let user = session.currentUser else { return }
        let action: PlaybackAction = player.isPaused ? .play : .pause
        let position = player.currentPositionMs
        seq += 1
        Task {
            let harness = SyncHarness(session: session)
            _ = try? await harness.emitHostSignal(
                room: room,
                hostUserId: user.id,
                action: action,
                positionMs: position,
                seq: seq
            )
            if action == .play {
                player.play()
                playback.isPaused = false
            } else {
                player.pause()
                playback.isPaused = true
            }
            playback.positionMs = position
            playback.lastSeq = seq
        }
    }

    public func requestSwitch(_ movie: Movie) {
        guard isHost else {
            session.showToast(AppError.onlyHostCanSwitchMovie.userMessage)
            return
        }
        if movie.id == self.movie?.id {
            showSwitchMovie = false
            session.showToast("已在播放")
            return
        }
        pendingMovie = movie
        showSwitchConfirm = true
    }

    public func confirmSwitch() async {
        guard let room, let user = session.currentUser, let pendingMovie else { return }
        seq += 1
        do {
            let harness = RoomHarness(session: session)
            let (updated, _) = try await harness.changeMovie(
                room: room,
                actorUserId: user.id,
                newMovie: pendingMovie,
                seq: seq
            )
            self.room = updated
            movie = pendingMovie
            playback = PlaybackState(positionMs: 0, isPaused: true, movieId: pendingMovie.id, lastSeq: seq)
            subtitleState = SubtitleState.resetForMovieChange(movieId: pendingMovie.id)
            player.pause()
            await preparePlayer()
            showSwitchMovie = false
            showSwitchConfirm = false
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.movieChangeFailed.userMessage
        }
    }

    public func sendChat() async {
        guard let room, let user = session.currentUser else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        _ = try? await session.chatGateway.send(roomId: room.id, text: text, sender: user)
    }

    public func refreshSubtitles() async {
        guard let movie else { return }
        let harness = SubtitleHarness(session: session)
        subtitleTracks = (try? await harness.listSubtitleTracks(for: movie)) ?? []
    }

    public func selectTrack(_ track: SubtitleTrack) {
        subtitleState.source = track.source
        subtitleState.trackId = track.id
        subtitleState.url = track.url
        showSubtitlePanel = false
    }

    public func adjustSubtitle(deltaMs: Int) {
        let harness = OffsetHarness()
        subtitleState = harness.applyOffset(state: subtitleState, deltaMs: deltaMs)
    }

    public func searchOnline() async {
        let harness = SubtitleHarness(session: session)
        onlineResults = (try? await harness.searchOnlineSubtitles(query: onlineQuery, year: movie?.year)) ?? []
    }

    public func inviteURL() -> URL {
        InviteHarness().inviteURL(
            roomId: room?.id ?? "",
            movieId: room?.movieId ?? movie?.id ?? "",
            hostUserId: room?.hostUserId ?? ""
        )
    }

    public func leave() async {
        guard let room, let user = session.currentUser else {
            session.route = .library
            return
        }
        seq += 1
        let harness = LeaveHarness(session: session)
        let position = player.currentPositionMs
        _ = try? await harness.leaveRoom(
            room: room,
            leavingUserId: user.id,
            positionMs: position,
            nextTransferSeq: seq
        )
        stop()
        session.route = .library
    }
}

private struct LibraryHarness: ListMoviesUseCase {
    let session: AppSession
    var catalogGateway: MovieCatalogGateway { session.catalogGateway }
    var metadataGateway: MetadataGateway { session.metadataGateway }
    var configGateway: ConfigGateway { session.configGateway }
}

private struct SyncHarness: EmitHostPlaybackUseCase {
    let session: AppSession
    var syncGateway: PlaybackSyncGateway { session.syncGateway }
}

private struct RoomHarness: ChangeMovieUseCase {
    let session: AppSession
    var roomGateway: RoomGateway { session.roomGateway }
    var syncGateway: PlaybackSyncGateway { session.syncGateway }
    var chatGateway: ChatGateway { session.chatGateway }
}

private struct LeaveHarness: LeaveRoomUseCase {
    let session: AppSession
    var roomGateway: RoomGateway { session.roomGateway }
    var chatGateway: ChatGateway { session.chatGateway }
    var syncGateway: PlaybackSyncGateway { session.syncGateway }
}

private struct SubtitleHarness: ListSubtitleTracksUseCase, SearchOnlineSubtitlesUseCase {
    let session: AppSession
    var subtitleGateway: SubtitleGateway { session.subtitleGateway }
    var configGateway: ConfigGateway { session.configGateway }
}

private struct OffsetHarness: ApplySubtitleOffsetUseCase {}
private struct InviteHarness: InviteToRoomUseCase {}

public struct WatchView: View {
    @ObservedObject var session: AppSession
    @StateObject private var viewModel: WatchViewModel
    @State private var showMoreMenu = false

    public init(session: AppSession, roomId: String?, movieId: String?, hostUserId: String? = nil) {
        self.session = session
        _viewModel = StateObject(wrappedValue: WatchViewModel(
            session: session,
            roomId: roomId,
            movieId: movieId,
            hostUserId: hostUserId
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            playerStage
            membersBar
            chatList
            chatInput
        }
        .background(Color(red: 247 / 255, green: 247 / 255, blue: 248 / 255).ignoresSafeArea())
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onReceive(viewModel.player.$lastError.compactMap { $0 }) { message in
            viewModel.errorMessage = message
        }
        .sheet(isPresented: $viewModel.showSwitchMovie) {
            SwitchMovieSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("切换后将从开头播放，全员同步换片", isPresented: $viewModel.showSwitchConfirm, titleVisibility: .visible) {
            Button("确认换片") { Task { await viewModel.confirmSwitch() } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $viewModel.showSubtitlePanel) {
            SubtitlePanelView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showSubtitleSync) {
            SubtitleSyncView(viewModel: viewModel)
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showInvite) {
            InviteSheetView(url: viewModel.inviteURL())
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("更多", isPresented: $showMoreMenu, titleVisibility: .hidden) {
            Button("字幕") { viewModel.showSubtitlePanel = true }
            Button("字幕同步") { viewModel.showSubtitleSync = true }
            Button("取消", role: .cancel) {}
        }
    }

    private var playerStage: some View {
        ZStack(alignment: .bottom) {
            VLCPlayerView(videoView: viewModel.player.videoView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.clear,
                    Color.black.opacity(0.72),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                watchChrome
                    .padding(.top, 8)
                Spacer(minLength: 0)
                playerBottomChrome
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if !viewModel.player.isReady {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("正在缓冲…")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(height: 248)
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
                    .padding(.top, 52)
            }
        }
    }

    private var watchChrome: some View {
        HStack(spacing: 6) {
            Button {
                Task { await viewModel.leave() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            }
            .accessibilityLabel("返回")

            Text(viewModel.movie?.title ?? "影片")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if viewModel.isHost {
                    viewModel.showSwitchMovie = true
                } else {
                    session.showToast(AppError.onlyHostCanSwitchMovie.userMessage)
                }
            } label: {
                Text("换片")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.black.opacity(0.18))
                    .overlay {
                        Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1)
                    }
                    .clipShape(Capsule())
            }
            .accessibilityLabel("切换影片")

            Button {
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("更多")
        }
    }

    private var playerBottomChrome: some View {
        VStack(spacing: 8) {
            if viewModel.subtitleState.source != .off {
                Text("字幕偏移 \(String(format: "%.1f", Double(viewModel.subtitleState.offsetMs) / 1000))s")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                    .padding(.horizontal, 8)
            }

            HStack(spacing: 10) {
                Button { viewModel.togglePlay() } label: {
                    Image(systemName: viewModel.player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
                .disabled(!viewModel.isHost)
                .opacity(viewModel.isHost ? 0.95 : 0.45)

                Button { viewModel.showSubtitlePanel = true } label: {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("字幕")

                GeometryReader { geo in
                    let progress = playbackProgress
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.28))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(3, geo.size.width * progress))
                    }
                }
                .frame(height: 3)

                Text(timeLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
        }
    }

    private var playbackProgress: CGFloat {
        let duration = max(viewModel.player.durationMs, 1)
        return CGFloat(min(1, max(0, Double(viewModel.player.positionMs) / Double(duration))))
    }

    private var timeLabel: String {
        let current = TandemColors.formatPlaybackTime(viewModel.player.positionMs)
        let total = TandemColors.formatPlaybackTime(viewModel.player.durationMs)
        return "\(current)/\(total)"
    }

    private var membersBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前 \(viewModel.room?.memberIds.count ?? 0) 人")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.72))
                Spacer()
                Text(viewModel.syncLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(TandemColors.secondaryLabel)
                    .lineLimit(1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.room?.memberIds ?? [], id: \.self) { id in
                        TandemAvatarView(
                            userId: id,
                            size: 40,
                            isHost: id == viewModel.room?.hostUserId
                        )
                        .accessibilityLabel(id == viewModel.room?.hostUserId ? "\(id)，房主" : id)
                    }
                    Button {
                        viewModel.showInvite = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(TandemColors.groupedBackground)
                            Circle()
                                .strokeBorder(
                                    Color(red: 199 / 255, green: 199 / 255, blue: 204 / 255),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                                )
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255))
                        }
                        .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("邀请")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.08))
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
        .background(Color(red: 247 / 255, green: 247 / 255, blue: 248 / 255))
    }

    @ViewBuilder
    private func chatRow(_ message: ChatMessage) -> some View {
        if message.kind == .system {
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            let isMe = message.senderId == session.currentUser?.id
            HStack(alignment: .top, spacing: 8) {
                if !isMe {
                    TandemAvatarView(userId: message.senderNickname.isEmpty ? (message.senderId ?? "?") : message.senderNickname, size: 32)
                }
                VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                    if !isMe {
                        Text(message.senderNickname)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.45))
                    }
                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundStyle(isMe ? Color.white : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isMe ? TandemColors.systemBlue : Color.white)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: isMe ? 16 : 6,
                            bottomTrailingRadius: isMe ? 6 : 16,
                            topTrailingRadius: 16,
                            style: .continuous
                        ))
                        .shadow(color: isMe ? .clear : .black.opacity(0.04), radius: 1, y: 1)
                }
                if isMe {
                    TandemAvatarView(userId: message.senderNickname.isEmpty ? (message.senderId ?? "?") : message.senderNickname, size: 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            .padding(isMe ? .leading : .trailing, 40)
        }
    }

    private var chatInput: some View {
        HStack(spacing: 8) {
            TextField("发个消息聊聊呗~", text: $viewModel.draft)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(TandemColors.groupedBackground)
                .clipShape(Capsule())
            Button {
                Task { await viewModel.sendChat() }
            } label: {
                Text("发送")
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
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.white)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct SwitchMovieSheet: View {
    @ObservedObject var viewModel: WatchViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.libraryMovies) { movie in
                Button {
                    viewModel.requestSwitch(movie)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(movie.title)
                            Text(movie.year ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if movie.id == viewModel.movie?.id {
                            Text("播放中").foregroundStyle(TandemColors.systemBlue)
                        }
                    }
                }
            }
            .navigationTitle("切换影片")
            .task {
                if viewModel.libraryMovies.isEmpty {
                    await viewModel.start()
                }
            }
        }
    }
}

private struct SubtitlePanelView: View {
    @ObservedObject var viewModel: WatchViewModel
    @State private var showSearch = false

    var body: some View {
        NavigationStack {
            List {
                Section("当前") {
                    ForEach(viewModel.subtitleTracks) { track in
                        Button {
                            viewModel.selectTrack(track)
                        } label: {
                            HStack {
                                Text(track.label)
                                Spacer()
                                if viewModel.subtitleState.trackId == track.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(TandemColors.systemBlue)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("在线搜索") { showSearch = true }
                    Button("字幕同步") {
                        viewModel.showSubtitlePanel = false
                        viewModel.showSubtitleSync = true
                    }
                }
            }
            .navigationTitle("字幕")
            .sheet(isPresented: $showSearch) {
                OnlineSubtitleSearchView(viewModel: viewModel)
            }
        }
    }
}

private struct SubtitleSyncView: View {
    @ObservedObject var viewModel: WatchViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("字幕同步")
                .font(.headline)
            Text(String(format: "%+.1fs", Double(viewModel.subtitleState.offsetMs) / 1000))
                .font(.largeTitle.monospacedDigit())
            HStack(spacing: 20) {
                Button("-0.5s") { viewModel.adjustSubtitle(deltaMs: -500) }
                Button("-0.1s") { viewModel.adjustSubtitle(deltaMs: -100) }
                Button("重置") {
                    viewModel.subtitleState.resetOffset()
                }
                Button("+0.1s") { viewModel.adjustSubtitle(deltaMs: 100) }
                Button("+0.5s") { viewModel.adjustSubtitle(deltaMs: 500) }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

private struct OnlineSubtitleSearchView: View {
    @ObservedObject var viewModel: WatchViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("片名", text: $viewModel.onlineQuery)
                    Button("搜索") { Task { await viewModel.searchOnline() } }
                }
                Section("结果") {
                    if viewModel.onlineResults.isEmpty {
                        Text("无结果").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.onlineResults) { track in
                            Button(track.label) {
                                viewModel.selectTrack(track)
                            }
                        }
                    }
                }
            }
            .navigationTitle("在线搜字幕")
        }
    }
}

private struct InviteSheetView: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(url.absoluteString)
                    .textSelection(.enabled)
                    .padding()
                ShareLink(item: url) {
                    Label("系统分享", systemImage: "square.and.arrow.up")
                }
                Button("复制链接") {
                    UIPasteboard.general.string = url.absoluteString
                    copied = true
                }
                if copied {
                    Text("已复制").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("邀请好友")
        }
    }
}
