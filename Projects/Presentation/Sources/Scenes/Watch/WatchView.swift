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
    @Published public var isSearchingOnline = false
    @Published public var didSearchOnline = false
    @Published public var onlineSearchError: String?
    @Published public var isApplyingSubtitle = false
    @Published public var errorMessage: String?
    @Published public var libraryMovies: [Movie] = []
    @Published public var switchQuery = ""
    @Published public var isSwitchingMovie = false
    @Published public var isLoadingLibraryForSwitch = false
    /// Profiles for room members (nickname + resolved avatarURL).
    @Published public var memberProfiles: [String: User] = [:]

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
    private var memberProfileTask: Task<Void, Never>?
    /// Last object key the host successfully shared this session; used to clear members only when needed.
    private var lastHostSharedSubtitleKey: String?
    private let chatSafety = ChatSafetyStore()

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

    public var filteredLibraryMovies: [Movie] {
        let query = switchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return libraryMovies }
        return libraryMovies.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.year?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    public var selectedSubtitleTrack: SubtitleTrack? {
        guard let trackId = subtitleState.trackId, trackId != "off" else { return nil }
        return subtitleTracks.first(where: { $0.id == trackId })
            ?? onlineResults.first(where: { $0.id == trackId })
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
            subtitleState = SubtitleState(
                movieId: movie.id,
                offsetMs: SubtitleOffsetStore.load(movieId: movie.id)
            )
            syncLabel = isHost ? "你是房主，进度由你控制" : "跟随房主中"
            onlineQuery = [movie.title, movie.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            await preparePlayer()
            listen()
            startHeartbeatIfNeeded()
            await refreshMemberProfiles()
            await refreshSubtitles(autoSelectChinese: true)
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
        memberProfileTask?.cancel()
        signalTask = nil
        chatTask = nil
        roomTask = nil
        heartbeatTask = nil
        memberProfileTask = nil
        player.stop()
    }

    /// Playback fraction 0...1 for a member's progress ring.
    /// Self uses the local player; others use last applied sync position (follow model).
    public func memberPlaybackProgress(for memberId: String) -> Double {
        let duration = max(player.durationMs, 1)
        let position: Int64
        if memberId == session.currentUser?.id {
            position = player.positionMs
        } else {
            position = playback.positionMs > 0 ? playback.positionMs : player.positionMs
        }
        return min(1, max(0, Double(position) / Double(duration)))
    }

    public func memberDisplayName(for memberId: String) -> String {
        if let nick = memberProfiles[memberId]?.nickname, !nick.isEmpty {
            return nick
        }
        if memberId == session.currentUser?.id, let nick = session.currentUser?.nickname, !nick.isEmpty {
            return nick
        }
        return memberId
    }

    public func memberAvatarURL(for memberId: String) -> URL? {
        if memberId == session.currentUser?.id {
            return session.currentUser?.avatarURL ?? memberProfiles[memberId]?.avatarURL
        }
        return memberProfiles[memberId]?.avatarURL
    }

    public func refreshMemberProfiles() async {
        guard let ids = room?.memberIds, !ids.isEmpty else {
            memberProfiles = [:]
            return
        }
        memberProfileTask?.cancel()
        let snapshot = ids
        let authGateway = session.authGateway
        let currentUser = session.currentUser
        memberProfileTask = Task { @concurrent in
            let users = (try? await authGateway.fetchUsers(userIds: snapshot)) ?? []
            guard !Task.isCancelled else { return }
            var map: [String: User] = [:]
            for user in users {
                map[user.id] = user
            }
            if let me = currentUser {
                map[me.id] = me
            }
            let profileMap = map
            await MainActor.run {
                self.memberProfiles = profileMap
            }
        }
        await memberProfileTask?.value
    }

    private func loadMovie(id: String) async {
        let harness = LibraryHarness(
            catalogGateway: session.catalogGateway,
            metadataGateway: session.metadataGateway,
            configGateway: session.configGateway
        )
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
                storage: .init(accessKey: "", secretKey: "", bucket: "", endpoint: "")
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

        let roomId = room.id
        let syncGateway = session.syncGateway
        let chatGateway = session.chatGateway
        let roomGateway = session.roomGateway
        signalTask = Task { @concurrent in
            for await signal in syncGateway.signals(roomId: roomId) {
                await MainActor.run {
                    applyRemote(signal)
                }
            }
        }
        chatTask = Task { @concurrent in
            for await message in chatGateway.messages(roomId: roomId) {
                await MainActor.run {
                    ingestChat(message)
                }
            }
        }
        roomTask = Task { @concurrent in
            for await updated in roomGateway.observeRoom(roomId: roomId) {
                let membersChanged = await MainActor.run {
                    let changed = updated.memberIds != self.room?.memberIds
                    self.room = updated
                    syncLabel = isHost ? "你是房主，进度由你控制" : "跟随房主中"
                    if updated.status == .ended {
                        errorMessage = AppError.roomEnded.userMessage
                    }
                    return changed
                }
                if membersChanged {
                    await refreshMemberProfiles()
                }
            }
        }
    }

    private func startHeartbeatIfNeeded() {
        heartbeatTask?.cancel()
        guard isHost else { return }
        let heartbeat: @MainActor @Sendable () -> Void = { [weak self] in
            self?.emitHeartbeat()
        }
        heartbeatTask = Task { @concurrent in
            let interval = UInt64(PlaybackSyncRules.foregroundHeartbeatSeconds * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await heartbeat()
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
            let harness = SyncHarness(syncGateway: session.syncGateway)
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
        let result = PlaybackSyncRules.shouldAccept(
            signal: signal,
            room: room,
            current: playback,
            localPositionMs: player.currentPositionMs
        )
        switch result {
        case .ignored:
            return
        case .applied(let state, let shouldSeek):
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
                // Host already applied locally in confirmSwitch; members follow here.
                if movie?.id != movieId {
                    if !isHost {
                        session.showToast("房主切换了影片…")
                    }
                    Task {
                        await loadMovie(id: movieId)
                        let offset = SubtitleOffsetStore.load(movieId: movieId)
                        subtitleState = SubtitleState(movieId: movieId, offsetMs: offset)
                        await preparePlayer()
                        await refreshSubtitles(autoSelectChinese: true)
                    }
                }
            }
            if signal.action == .subtitleChange {
                // Host already loaded locally before broadcasting; skip self-echo.
                if signal.senderId != session.currentUser?.id {
                    Task { await applyHostSharedSubtitle(signal) }
                }
            }
            if shouldSeek {
                player.seek(toMs: state.positionMs)
            }
            // Avoid pause↔play thrash on heartbeat when already in the right state.
            if state.isPaused {
                if !player.isPaused { player.pause() }
            } else if player.isPaused {
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
            let harness = SyncHarness(syncGateway: session.syncGateway)
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

    /// Host scrub / seek — updates local player immediately and broadcasts `.seek`.
    public func seekTo(ms: Int64) {
        guard isHost, let room, let user = session.currentUser else { return }
        let duration = max(player.durationMs, 1)
        let clamped = min(max(0, ms), duration)
        seq += 1
        let currentSeq = seq
        let wasPaused = player.isPaused
        player.seek(toMs: clamped)
        playback.positionMs = clamped
        playback.lastSeq = currentSeq
        Task {
            let harness = SyncHarness(syncGateway: session.syncGateway)
            _ = try? await harness.emitHostSignal(
                room: room,
                hostUserId: user.id,
                action: .seek,
                positionMs: clamped,
                seq: currentSeq
            )
            if !wasPaused {
                player.play()
            }
        }
    }

    public func seekToProgress(_ progress: Double) {
        let duration = max(player.durationMs, 1)
        let ms = Int64(Double(duration) * min(1, max(0, progress)))
        seekTo(ms: ms)
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
        showSwitchMovie = false
        // Dismiss sheet first so the confirm alert isn't buried under it.
        let revealConfirmation: @MainActor @Sendable () -> Void = { [weak self] in
            self?.showSwitchConfirm = true
        }
        Task { @concurrent in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            await revealConfirmation()
        }
    }

    public func cancelSwitchConfirm() {
        showSwitchConfirm = false
        pendingMovie = nil
    }

    public func loadLibraryForSwitch() async {
        isLoadingLibraryForSwitch = true
        defer { isLoadingLibraryForSwitch = false }
        switchQuery = ""
        let harness = LibraryHarness(
            catalogGateway: session.catalogGateway,
            metadataGateway: session.metadataGateway,
            configGateway: session.configGateway
        )
        let movies = (try? await harness.listMovies(enrichMetadata: false)) ?? []
        if !movies.isEmpty {
            libraryMovies = movies
        }
        // Enrich posters in background for the switch list thumbs.
        let configGateway = session.configGateway
        let metadataGateway = session.metadataGateway
        let snapshot = libraryMovies
        Task { @concurrent in
            guard let config = try? await configGateway.load() else { return }
            var enriched = snapshot
            let concurrency = 4
            for lowerBound in stride(from: 0, to: snapshot.count, by: concurrency) {
                let upperBound = min(lowerBound + concurrency, snapshot.count)
                await withTaskGroup(of: (Int, Movie).self) { group in
                    for index in lowerBound..<upperBound {
                        let movie = snapshot[index]
                        group.addTask {
                            (index, await metadataGateway.enrich(movie, config: config))
                        }
                    }
                    for await (index, movie) in group {
                        enriched[index] = movie
                    }
                }
            }
            let result = enriched
            await MainActor.run {
                // Keep list if user already refreshed to a different set.
                if self.libraryMovies.map(\.id) == snapshot.map(\.id) {
                    self.libraryMovies = result
                }
            }
        }
    }

    public func confirmSwitch() async {
        // Snapshot before the alert dismisses — do not clear pendingMovie on alert close,
        // or this guard fails and the switch silently no-ops.
        guard let room, let user = session.currentUser else { return }
        guard let target = pendingMovie else { return }
        guard !isSwitchingMovie else { return }
        isSwitchingMovie = true
        showSwitchConfirm = false
        defer { isSwitchingMovie = false }
        seq += 1
        do {
            let harness = RoomHarness(
                roomGateway: session.roomGateway,
                syncGateway: session.syncGateway,
                chatGateway: session.chatGateway
            )
            let (updated, _) = try await harness.changeMovie(
                room: room,
                actorUserId: user.id,
                newMovie: target,
                seq: seq
            )
            self.room = updated
            movie = target
            onlineQuery = [target.title, target.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            playback = PlaybackState(positionMs: 0, isPaused: true, movieId: target.id, lastSeq: seq)
            let offset = SubtitleOffsetStore.load(movieId: target.id)
            subtitleState = SubtitleState(movieId: target.id, offsetMs: offset)
            player.pause()
            await preparePlayer()
            pendingMovie = nil
            showSwitchMovie = false
            await refreshSubtitles(autoSelectChinese: true)
        } catch let error as AppError {
            errorMessage = error.userMessage
            session.showToast(error.userMessage)
        } catch {
            errorMessage = AppError.movieChangeFailed.userMessage
            session.showToast(AppError.movieChangeFailed.userMessage)
        }
    }

    public func sendChat() async {
        guard let room, let user = session.currentUser else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        _ = try? await session.chatGateway.send(roomId: room.id, text: text, sender: user)
    }

    public func canModerate(_ message: ChatMessage) -> Bool {
        guard message.kind != .system else { return false }
        guard let senderId = message.senderId, let me = session.currentUser?.id else { return false }
        return senderId != me
    }

    public func blockSender(of message: ChatMessage) {
        guard let ownerId = session.currentUser?.id, let senderId = message.senderId else { return }
        chatSafety.block(senderId, ownerId: ownerId)
        messages = chatSafety.visibleMessages(messages, ownerId: ownerId)
        session.showToast("已屏蔽 \(message.senderNickname.isEmpty ? senderId : message.senderNickname)")
    }

    public func report(_ message: ChatMessage) {
        guard let ownerId = session.currentUser?.id, let senderId = message.senderId else { return }
        chatSafety.recordReport(targetUserId: senderId, ownerId: ownerId, snippet: message.text)
        session.showToast("已记录举报，将打开反馈页")
    }

    public var chatReportURL: URL { ChatSafetyStore.reportURL }

    private func ingestChat(_ message: ChatMessage) {
        if let ownerId = session.currentUser?.id {
            messages = chatSafety.visibleMessages(messages + [message], ownerId: ownerId)
        } else {
            messages.append(message)
        }
    }

    public func refreshSubtitles(autoSelectChinese: Bool = false) async {
        guard let movie else { return }
        let harness = SubtitleHarness(
            subtitleGateway: session.subtitleGateway,
            configGateway: session.configGateway
        )
        let listed = (try? await harness.listSubtitleTracks(for: movie)) ?? [
            SubtitleTrack(id: "off", label: "关闭字幕", source: .off),
        ]
        // Give VLC a moment to parse embedded tracks after prepare.
        if player.embeddedSubtitleTracks().isEmpty {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let embedded = player.embeddedSubtitleTracks()
        let off = listed.filter { $0.source == .off }
        let ossTracks = listed.filter { $0.source == .oss }
        // Keep host-shared / online selections that aren't in the fresh OSS sidecar list.
        let preserved = subtitleTracks.filter { track in
            guard track.source != .off, track.source != .embedded else { return false }
            if ossTracks.contains(where: { $0.id == track.id }) { return false }
            if track.id.hasPrefix("shared:") { return true }
            if track.source == .online, track.id == subtitleState.trackId { return true }
            return false
        }
        subtitleTracks = off + embedded + ossTracks + preserved

        if autoSelectChinese,
           subtitleState.source == .off || subtitleState.trackId == nil || subtitleState.trackId == "off",
           let preferred = subtitleTracks.first(where: { $0.source != .off && $0.isChinesePreferred }) {
            await selectTrack(preferred)
        } else if subtitleState.source != .off {
            player.applySubtitleOffsetMs(subtitleState.offsetMs)
        }
    }

    public func selectTrack(_ track: SubtitleTrack) async {
        guard !isApplyingSubtitle else { return }
        isApplyingSubtitle = true
        defer { isApplyingSubtitle = false }

        let movieId = movie?.id ?? subtitleState.movieId
        let retainedOffset = subtitleState.offsetMs

        if track.source == .off {
            player.disableSubtitles()
            subtitleState = SubtitleState(
                movieId: movieId,
                source: .off,
                trackId: "off",
                offsetMs: retainedOffset
            )
            showSubtitlePanel = false
            // Only clear members if this host previously shared a file-based subtitle.
            if isHost, lastHostSharedSubtitleKey != nil {
                lastHostSharedSubtitleKey = nil
                await broadcastHostSubtitleShare(objectKey: nil, label: nil, movieId: movieId)
            }
            return
        }

        do {
            var sharedLocalURL: URL?
            switch track.source {
            case .embedded:
                guard let index = track.embeddedIndex else {
                    throw AppError.subtitleUnavailable
                }
                player.selectEmbeddedSubtitle(index: index)
                // Re-apply after index change; some VLC builds reset delay on track switch.
                player.applySubtitleOffsetMs(retainedOffset)
            case .oss, .online:
                let config = try? await session.configGateway.load()
                let localURL = try await session.subtitleGateway.download(
                    track,
                    config: config
                )
                guard player.loadExternalSubtitle(fileURL: localURL) else {
                    throw AppError.subtitleUnavailable
                }
                sharedLocalURL = localURL
            case .off:
                break
            }

            subtitleState = SubtitleState(
                movieId: movieId,
                source: track.source,
                trackId: track.id,
                url: track.url,
                embeddedIndex: track.embeddedIndex,
                offsetMs: retainedOffset
            )
            player.applySubtitleOffsetMs(retainedOffset)

            if track.source == .online, !subtitleTracks.contains(where: { $0.id == track.id }) {
                // Keep selected online track visible under「当前」.
                subtitleTracks.insert(track, at: min(1, subtitleTracks.count))
            }
            showSubtitlePanel = false

            // Host: upload downloaded file to object storage and instruct members to load it.
            // Member downloads remain local-only (no upload / no signal).
            // Embedded tracks have no portable file — host-only, not shared.
            if isHost, let localURL = sharedLocalURL {
                await shareDownloadedSubtitleWithRoom(
                    localURL: localURL,
                    track: track,
                    movieId: movieId
                )
            }
        } catch let error as AppError {
            session.showToast(error.userMessage)
        } catch {
            session.showToast(AppError.subtitleUnavailable.userMessage)
        }
    }

    /// Host uploads a downloaded subtitle and broadcasts `subtitle_change`.
    private func shareDownloadedSubtitleWithRoom(
        localURL: URL,
        track: SubtitleTrack,
        movieId: String
    ) async {
        guard let room, session.currentUser != nil, isHost else { return }
        guard let config = try? await session.configGateway.load(), config.storage.isComplete else {
            session.showToast("字幕已加载（片库未配置，无法同步给成员）")
            return
        }
        do {
            let movieObjectKey = movie?.objectKey ?? movieId
            let key = try await session.sharedSubtitleStorage.upload(
                fileURL: localURL,
                roomId: room.id,
                movieId: movieObjectKey,
                config: config
            )
            await broadcastHostSubtitleShare(
                objectKey: key,
                label: track.label,
                movieId: movieObjectKey
            )
            lastHostSharedSubtitleKey = key
            _ = try? await session.chatGateway.postSystemMessage(
                roomId: room.id,
                text: "房主共享了字幕：\(track.label)"
            )
            // Sidecar now lives beside the movie — refresh「片库外挂」and mark it current.
            await refreshSubtitles()
            if let sidecar = subtitleTracks.first(where: { $0.id == "oss:\(key)" }) {
                subtitleState = SubtitleState(
                    movieId: movieObjectKey,
                    source: .oss,
                    trackId: sidecar.id,
                    url: sidecar.url,
                    offsetMs: subtitleState.offsetMs
                )
            }
        } catch {
            session.showToast(AppError.subtitleShareFailed.userMessage)
        }
    }

    private func broadcastHostSubtitleShare(
        objectKey: String?,
        label: String?,
        movieId: String
    ) async {
        guard let room, let user = session.currentUser, isHost else { return }
        seq += 1
        let harness = SyncHarness(syncGateway: session.syncGateway)
        _ = try? await harness.emitHostSignal(
            room: room,
            hostUserId: user.id,
            action: .subtitleChange,
            positionMs: player.currentPositionMs,
            seq: seq,
            movieId: movieId,
            subtitleObjectKey: objectKey,
            subtitleLabel: label
        )
        playback.lastSeq = seq
    }

    /// Member follows host-shared subtitle from object storage (local offset retained).
    private func applyHostSharedSubtitle(_ signal: PlaybackSyncSignal) async {
        if let signalMovie = signal.movieId, let current = movie?.id, !signalMovie.isEmpty, signalMovie != current {
            return
        }
        let movieId = signal.movieId ?? movie?.id ?? subtitleState.movieId
        let retainedOffset = subtitleState.offsetMs

        guard let key = signal.subtitleObjectKey, !key.isEmpty else {
            player.disableSubtitles()
            subtitleState = SubtitleState(
                movieId: movieId,
                source: .off,
                trackId: "off",
                offsetMs: retainedOffset
            )
            return
        }

        guard let config = try? await session.configGateway.load(), config.storage.isComplete else {
            session.showToast(AppError.subtitleUnavailable.userMessage)
            return
        }

        do {
            let localURL = try await session.sharedSubtitleStorage.download(
                objectKey: key,
                config: config
            )
            guard player.loadExternalSubtitle(fileURL: localURL) else {
                throw AppError.subtitleUnavailable
            }
            let label = (signal.subtitleLabel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "房主共享"
            let track = SubtitleTrack(
                id: "shared:\(key)",
                label: label,
                language: nil,
                source: .oss,
                detail: "房主共享",
                languageBadge: nil,
                format: (key as NSString).pathExtension.uppercased()
            )
            subtitleState = SubtitleState(
                movieId: movieId,
                source: .oss,
                trackId: track.id,
                offsetMs: retainedOffset
            )
            player.applySubtitleOffsetMs(retainedOffset)
            if !subtitleTracks.contains(where: { $0.id == track.id }) {
                subtitleTracks.insert(track, at: min(1, subtitleTracks.count))
            }
            session.showToast("已加载房主共享的字幕")
        } catch let error as AppError {
            session.showToast(error.userMessage)
        } catch {
            session.showToast(AppError.subtitleUnavailable.userMessage)
        }
    }

    public func adjustSubtitle(deltaMs: Int) {
        let harness = OffsetHarness()
        subtitleState = harness.applyOffset(state: subtitleState, deltaMs: deltaMs)
        persistAndApplyOffset()
    }

    public func resetSubtitleOffset() {
        var next = subtitleState
        next.resetOffset()
        subtitleState = next
        persistAndApplyOffset()
    }

    private func persistAndApplyOffset() {
        if let movieId = movie?.id ?? Optional(subtitleState.movieId), !movieId.isEmpty {
            SubtitleOffsetStore.save(movieId: movieId, offsetMs: subtitleState.offsetMs)
        }
        if subtitleState.source != .off {
            player.applySubtitleOffsetMs(subtitleState.offsetMs)
        }
    }

    public func searchOnline() async {
        isSearchingOnline = true
        onlineSearchError = nil
        defer { isSearchingOnline = false }
        let harness = SubtitleHarness(
            subtitleGateway: session.subtitleGateway,
            configGateway: session.configGateway
        )
        do {
            onlineResults = try await harness.searchOnlineSubtitles(query: onlineQuery, year: movie?.year)
            didSearchOnline = true
        } catch let error as AppError {
            onlineResults = []
            didSearchOnline = true
            onlineSearchError = error.userMessage
        } catch {
            onlineResults = []
            didSearchOnline = true
            onlineSearchError = AppError.subtitleUnavailable.userMessage
        }
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
            session.popLibraryToRoot()
            return
        }
        seq += 1
        let harness = LeaveHarness(
            roomGateway: session.roomGateway,
            chatGateway: session.chatGateway,
            syncGateway: session.syncGateway
        )
        let position = player.currentPositionMs
        _ = try? await harness.leaveRoom(
            room: room,
            leavingUserId: user.id,
            positionMs: position,
            nextTransferSeq: seq
        )
        stop()
        session.popLibraryToRoot()
    }
}

private struct LibraryHarness: ListMoviesUseCase {
    let catalogGateway: MovieCatalogGateway
    let metadataGateway: MetadataGateway
    let configGateway: ConfigGateway
}

private struct SyncHarness: EmitHostPlaybackUseCase {
    let syncGateway: PlaybackSyncGateway
}

private struct RoomHarness: ChangeMovieUseCase {
    let roomGateway: RoomGateway
    let syncGateway: PlaybackSyncGateway
    let chatGateway: ChatGateway
}

private struct LeaveHarness: LeaveRoomUseCase {
    let roomGateway: RoomGateway
    let chatGateway: ChatGateway
    let syncGateway: PlaybackSyncGateway
}

private struct SubtitleHarness: ListSubtitleTracksUseCase, SearchOnlineSubtitlesUseCase {
    let subtitleGateway: SubtitleGateway
    let configGateway: ConfigGateway
}

private struct OffsetHarness: ApplySubtitleOffsetUseCase {}
private struct InviteHarness: InviteToRoomUseCase {}

public struct WatchView: View {
    @ObservedObject var session: AppSession
    @ObservedObject var theme: ThemeStore
    @StateObject private var viewModel: WatchViewModel
    @State private var showMoreMenu = false
    @State private var showPlayerChrome = true
    @State private var isFullscreen = false
    @State private var scrubProgress: CGFloat?
    @State private var chromeHideTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL

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
            VStack(spacing: 0) {
                playerStage(height: isFullscreen ? nil : stageHeight(in: proxy.size))
                if !isFullscreen {
                    membersBar
                    chatList
                    chatInput
                }
            }
        }
        .background(TandemColors.groupedBackground.ignoresSafeArea())
        .ignoresSafeArea(edges: isFullscreen ? .all : [])
        .statusBarHidden(isFullscreen)
        .onChange(of: isFullscreen) { _, fullscreen in
            applyFullscreenOrientation(fullscreen)
        }
        .task {
            await viewModel.start()
            revealPlayerChrome()
        }
        .onDisappear {
            chromeHideTask?.cancel()
            OrientationLock.lock(.portrait)
            viewModel.stop()
        }
        .onReceive(viewModel.player.$lastError.compactMap { $0 }) { message in
            viewModel.errorMessage = message
        }
        .sheet(isPresented: $viewModel.showSwitchMovie) {
            SwitchMovieSheet(viewModel: viewModel)
                .preferredColorScheme(theme.appearance.preferredColorScheme)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "切换影片？",
            isPresented: $viewModel.showSwitchConfirm
        ) {
            Button("取消", role: .cancel) {
                viewModel.cancelSwitchConfirm()
            }
            Button("切换") {
                Task { await viewModel.confirmSwitch() }
            }
        } message: {
            if let title = viewModel.pendingMovie?.title {
                Text("将切换为《\(title)》，并从开头播放，全员同步换片。")
            } else {
                Text("切换后将从开头播放，全员同步换片。")
            }
        }
        .sheet(isPresented: $viewModel.showSubtitlePanel) {
            SubtitlePanelView(viewModel: viewModel)
                .preferredColorScheme(theme.appearance.preferredColorScheme)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showSubtitleSync) {
            SubtitleSyncView(viewModel: viewModel)
                .preferredColorScheme(theme.appearance.preferredColorScheme)
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showInvite) {
            InviteSheetView(url: viewModel.inviteURL())
                .preferredColorScheme(theme.appearance.preferredColorScheme)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("更多", isPresented: $showMoreMenu, titleVisibility: .hidden) {
            Button("字幕") { viewModel.showSubtitlePanel = true }
            Button("字幕同步") { viewModel.showSubtitleSync = true }
            Button("取消", role: .cancel) {}
        }
        .overlay {
            if viewModel.isSwitchingMovie {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("正在换片…")
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
                    Text("正在缓冲…")
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
            .accessibilityLabel(isFullscreen ? "退出全屏" : "返回")

            Text(viewModel.movie?.title ?? "影片")
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
                    session.showToast(AppError.onlyHostCanSwitchMovie.userMessage)
                }
            } label: {
                Text("换片")
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
            .accessibilityLabel("切换影片")
            .accessibilityHint(viewModel.isHost ? "打开片库切换当前影片" : "仅房主可切换影片")

            Button {
                notePlayerInteraction()
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
            if viewModel.subtitleState.source != .off, viewModel.subtitleState.offsetMs != 0 {
                Text("字幕 \(viewModel.subtitleState.offsetLabel)")
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
                .accessibilityLabel("字幕")

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
                .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
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
            .accessibilityLabel("播放进度")
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

    private var membersBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前 \(viewModel.room?.memberIds.count ?? 0) 人")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TandemColors.secondaryLabel)
                Spacer()
                Text(viewModel.syncLabel)
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
                    .accessibilityLabel("邀请")
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
                Text("邀请制房间 · 长按消息可屏蔽或举报")
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
    }

    @ViewBuilder
    private func chatRow(_ message: ChatMessage) -> some View {
        if message.kind == .system {
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(TandemColors.tertiaryLabel)
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
                            .foregroundStyle(TandemColors.secondaryLabel)
                    }
                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundStyle(isMe ? Color.white : Color.primary)
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
                if isMe {
                    TandemAvatarView(userId: message.senderNickname.isEmpty ? (message.senderId ?? "?") : message.senderNickname, size: 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            .padding(isMe ? .leading : .trailing, 40)
            .contextMenu {
                if viewModel.canModerate(message) {
                    Button("屏蔽此人", role: .destructive) {
                        viewModel.blockSender(of: message)
                    }
                    Button("举报") {
                        viewModel.report(message)
                        openURL(viewModel.chatReportURL)
                    }
                }
            }
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
                    ProgressView("加载片库…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredLibraryMovies.isEmpty {
                    ContentUnavailableView(
                        viewModel.switchQuery.isEmpty ? "暂无影片" : "无匹配影片",
                        systemImage: "film",
                        description: Text(
                            viewModel.switchQuery.isEmpty
                                ? "确认对象存储 Bucket 中有 mp4/m4v/mkv"
                                : "试试其他关键词"
                        )
                    )
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
            .searchable(text: $viewModel.switchQuery, prompt: "搜索片名")
            .navigationTitle("切换影片")
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
                        ProgressView("正在换片…")
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
        .accessibilityValue(isPlaying ? "播放中" : (movie.year ?? ""))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = movie.year, !year.isEmpty {
            parts.append(year)
        }
        if isPlaying {
            parts.append("播放中")
        }
        return parts.joined(separator: " · ")
    }
}

private struct InviteSheetView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 0) {
                        ShareLink(item: url) {
                            inviteRow(title: "系统分享", trailing: .chevron)
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 16)

                        Button {
                            UIPasteboard.general.string = url.absoluteString
                            copied = true
                        } label: {
                            inviteRow(
                                title: "复制邀请链接",
                                trailing: .text(copied ? "已复制" : "复制", emphasized: copied)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .background(TandemColors.secondaryGrouped)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("链接预览")
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

                    Text("好友打开链接并登录后，将加入当前观影房间并对齐进度。")
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
            .navigationTitle("邀请好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarCloseButton(accessibilityLabel: "关闭") { dismiss() }
                }
            }
        }
    }

    private enum Trailing {
        case chevron
        case text(String, emphasized: Bool)
    }

    private func inviteRow(title: String, trailing: Trailing) -> some View {
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
