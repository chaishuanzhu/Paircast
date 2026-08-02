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
    private var seq: UInt64 = 1
    let player = VLCPlayerController()
    private var signalTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?

    public init(session: AppSession, roomId: String?, movieId: String?) {
        self.session = session
        self.initialRoomId = roomId
        self.initialMovieId = movieId
    }

    public var isHost: Bool {
        guard let room, let user = session.currentUser else { return false }
        return room.hostUserId == user.id
    }

    public func start() async {
        do {
            if let roomId = initialRoomId, let user = session.currentUser {
                if let existingMovieId = initialMovieId {
                    room = try await session.roomGateway.joinRoom(roomId: roomId, userId: user.id)
                    await loadMovie(id: existingMovieId)
                } else {
                    let joined = try await session.roomGateway.joinRoom(roomId: roomId, userId: user.id)
                    room = joined
                    await loadMovie(id: joined.movieId)
                }
            }
            guard let room, let movie else { return }
            playback = PlaybackState(movieId: movie.id, lastSeq: room.lastAppliedSeq)
            subtitleState = SubtitleState(movieId: movie.id)
            syncLabel = isHost ? "你是房主，进度由你控制" : "跟随房主中"
            onlineQuery = movie.title
            await preparePlayer()
            listen()
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
        InviteHarness().inviteURL(roomId: room?.id ?? "")
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

    public init(session: AppSession, roomId: String?, movieId: String?) {
        self.session = session
        _viewModel = StateObject(wrappedValue: WatchViewModel(session: session, roomId: roomId, movieId: movieId))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    Task { await viewModel.leave() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                Button {
                    if viewModel.isHost {
                        viewModel.showSwitchMovie = true
                    } else {
                        session.showToast(AppError.onlyHostCanSwitchMovie.userMessage)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.movie?.title ?? "影片")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("切换影片")
                }
                Spacer()
                Button {
                    viewModel.showInvite = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .accessibilityLabel("邀请")
            }
            .padding()
            .foregroundStyle(.white)
            .background(Color.black)

            VLCPlayerView(videoView: viewModel.player.videoView)
                .frame(height: 220)
                .background(Color.black)
                .overlay {
                    if !viewModel.player.isReady {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("正在缓冲…")
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                        .padding()
                    }
                }
                .overlay(alignment: .bottom) {
                    if viewModel.subtitleState.source != .off {
                        Text("字幕偏移 \(String(format: "%.1f", Double(viewModel.subtitleState.offsetMs) / 1000))s")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }

            HStack(spacing: 16) {
                Button { viewModel.togglePlay() } label: {
                    Image(systemName: viewModel.playback.isPaused ? "play.fill" : "pause.fill")
                }
                .disabled(!viewModel.isHost)
                Button("字幕") { viewModel.showSubtitlePanel = true }
                Button("同步") { viewModel.showSubtitleSync = true }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(TandemColors.danger)
                    .padding(.horizontal)
            }

            membersBar
            chatList
            chatInput
        }
        .background(TandemColors.groupedBackground.ignoresSafeArea())
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
    }

    private var membersBar: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(viewModel.room?.memberIds ?? [], id: \.self) { id in
                        VStack {
                            Image(systemName: "person.crop.circle.fill")
                            Text(id == viewModel.room?.hostUserId ? "\(id)·房主" : id)
                                .font(.caption2)
                        }
                    }
                }
            }
            Text(viewModel.syncLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.messages) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.kind == .system ? "系统" : message.senderNickname)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(message.text)
                            .font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private var chatInput: some View {
        HStack {
            TextField("说点什么…", text: $viewModel.draft)
                .textFieldStyle(.roundedBorder)
            Button("发送") {
                Task { await viewModel.sendChat() }
            }
            .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.ultraThinMaterial)
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
