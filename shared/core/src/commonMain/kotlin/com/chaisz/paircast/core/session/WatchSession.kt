package com.chaisz.paircast.core.session

import com.chaisz.paircast.core.gateway.AuthGateway
import com.chaisz.paircast.core.gateway.ChatGateway
import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.gateway.MetadataGateway
import com.chaisz.paircast.core.gateway.ModerationGateway
import com.chaisz.paircast.core.gateway.MovieCatalogGateway
import com.chaisz.paircast.core.gateway.PlaybackSyncGateway
import com.chaisz.paircast.core.gateway.RoomGateway
import com.chaisz.paircast.core.gateway.SharedSubtitleStorageGateway
import com.chaisz.paircast.core.gateway.SubtitleGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackState
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.RoomPlayback
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleState
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.UiText
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.rules.PlaybackSyncRules
import com.chaisz.paircast.core.store.ChatSafetyStore
import com.chaisz.paircast.core.store.SubtitleOffsetStore
import com.chaisz.paircast.core.support.Paths
import com.chaisz.paircast.core.usecase.ChangeMovieUseCase
import com.chaisz.paircast.core.usecase.EmitHostPlaybackUseCase
import com.chaisz.paircast.core.usecase.InviteLinks
import com.chaisz.paircast.core.usecase.LeaveRoomUseCase
import com.chaisz.paircast.core.usecase.ListMoviesUseCase
import com.chaisz.paircast.core.usecase.ListSubtitleTracksUseCase
import com.chaisz.paircast.core.usecase.SearchOnlineSubtitlesUseCase
import com.chaisz.paircast.core.usecase.BlockUserUseCase
import com.chaisz.paircast.core.usecase.ReportMessageUseCase
import com.chaisz.paircast.core.usecase.SyncBlockListUseCase
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.time.Clock

/** Gateways and local stores a [WatchSession] needs (assembled by the platform graph). */
class WatchDependencies(
    val authGateway: AuthGateway,
    val configGateway: ConfigGateway,
    val roomGateway: RoomGateway,
    val chatGateway: ChatGateway,
    val syncGateway: PlaybackSyncGateway,
    val catalogGateway: MovieCatalogGateway,
    val metadataGateway: MetadataGateway,
    val subtitleGateway: SubtitleGateway,
    val sharedSubtitleStorage: SharedSubtitleStorageGateway,
    val subtitleOffsets: SubtitleOffsetStore,
    val chatSafety: ChatSafetyStore,
    val moderation: ModerationGateway,
)

data class WatchUiState(
    val selfId: String? = null,
    val room: WatchRoom? = null,
    val movie: Movie? = null,
    val playback: PlaybackState = PlaybackState(movieId = ""),
    val messages: List<ChatMessage> = emptyList(),
    val subtitleTracks: List<SubtitleTrack> = emptyList(),
    val subtitleState: SubtitleState = SubtitleState(movieId = ""),
    val onlineResults: List<SubtitleTrack> = emptyList(),
    val isSearchingOnline: Boolean = false,
    val didSearchOnline: Boolean = false,
    val onlineSearchError: UiText? = null,
    val isApplyingSubtitle: Boolean = false,
    val error: UiText? = null,
    val libraryMovies: List<Movie> = emptyList(),
    val isSwitchingMovie: Boolean = false,
    val isLoadingLibraryForSwitch: Boolean = false,
    /** Profiles for room members (nickname + avatar URL). */
    val memberProfiles: Map<String, User> = emptyMap(),
    /** Default online-subtitle query for the current movie ("Title Year"). */
    val suggestedOnlineQuery: String = "",
    /** Member tapped refresh and is waiting for the host's snapshot. */
    val isRequestingSync: Boolean = false,
) {
    val isHost: Boolean get() = room != null && selfId != null && room.hostUserId == selfId

    val selectedSubtitleTrack: SubtitleTrack?
        get() {
            val trackId = subtitleState.trackId ?: return null
            if (trackId == "off") return null
            return subtitleTracks.firstOrNull { it.id == trackId } ?: onlineResults.firstOrNull { it.id == trackId }
        }

    fun memberDisplayName(memberId: String): String =
        memberProfiles[memberId]?.nickname?.takeIf { it.isNotEmpty() } ?: memberId

    fun memberAvatarUrl(memberId: String): String? = memberProfiles[memberId]?.avatarUrl

    fun canModerate(message: ChatMessage): Boolean {
        if (message.kind == ChatMessageKind.SYSTEM) return false
        val sender = message.senderId ?: return false
        return selfId != null && sender != selfId
    }
}

sealed class WatchEvent {
    data class Toast(val text: UiText) : WatchEvent()
    /** Leave finished — UI should pop back to the library. */
    data object Left : WatchEvent()
}

/**
 * Shared watch-party orchestration: join, signal/chat/room listeners, host heartbeat,
 * remote apply, movie switch, subtitle share, leave + host transfer.
 *
 * Every public method is fire-and-forget on the main dispatcher; observe [state] / [events].
 */
class WatchSession(
    private val deps: WatchDependencies,
    private val player: PlayerPort,
    private val initialRoomId: String?,
    private val initialMovieId: String?,
    private val initialHostUserId: String?,
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val nowMs: () -> Long = { Clock.System.now().toEpochMilliseconds() },
) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val _state = MutableStateFlow(WatchUiState(selfId = deps.authGateway.currentUser.value?.id))
    val state: StateFlow<WatchUiState> = _state.asStateFlow()
    private val _events = MutableSharedFlow<WatchEvent>(extraBufferCapacity = 32)
    val events: SharedFlow<WatchEvent> = _events.asSharedFlow()

    private val listMovies = ListMoviesUseCase(deps.configGateway, deps.catalogGateway, deps.metadataGateway)
    private val emitHost = EmitHostPlaybackUseCase(deps.syncGateway)
    private var syncRequestJob: Job? = null
    private var lastSyncAnswerMs = Long.MIN_VALUE / 2
    private val changeMovie = ChangeMovieUseCase(deps.roomGateway, deps.syncGateway, deps.chatGateway)
    private val leaveRoom = LeaveRoomUseCase(deps.roomGateway, deps.chatGateway, deps.syncGateway)
    private val listTracks = ListSubtitleTracksUseCase(deps.configGateway, deps.subtitleGateway)
    private val searchSubtitles = SearchOnlineSubtitlesUseCase(deps.subtitleGateway)
    private val syncBlocks = SyncBlockListUseCase(deps.moderation, deps.chatSafety)
    private val blockUser = BlockUserUseCase(deps.moderation, deps.chatSafety)
    private val reportMessage = ReportMessageUseCase(deps.moderation)

    /**
     * Signal sequence. Clock-seeded so a host that re-opens the room (new session, app relaunch)
     * still emits above what members already applied; [nextSeq] keeps it strictly increasing.
     */
    private var seq: Long = 0
    private var listenJobs: List<Job> = emptyList()
    private var heartbeatJob: Job? = null
    private var memberProfileJob: Job? = null
    /** Ids already looked up, so chat from a sender outside the roster triggers one fetch, not one per line. */
    private val requestedProfileIds = mutableSetOf<String>()
    /** Last object key the host shared this session; used to clear members only when needed. */
    private var lastHostSharedSubtitleKey: String? = null
    /** Set while the app is in the background; see [onBackground]. */
    private var backgroundedAtMs: Long? = null
    private var backgroundPositionMs = 0L
    /** Last time the host saved its playback snapshot on the server; heartbeats are throttled. */
    private var lastPlaybackReportMs = Long.MIN_VALUE / 2

    private val me: User? get() = deps.authGateway.currentUser.value
    private val current: WatchUiState get() = _state.value

    // region Lifecycle

    fun start() {
        scope.launch {
            try {
                val user = me ?: return@launch
                _state.update { it.copy(selfId = user.id) }
                syncBlockList()
                initialRoomId?.let { roomId ->
                    val joined = deps.roomGateway.joinRoom(roomId, user.id, initialMovieId, initialHostUserId)
                    _state.update { it.copy(room = joined) }
                    // Prefer live room movie over invite snapshot (host may have switched).
                    loadMovie(joined.movieId)
                }
                val room = current.room ?: return@launch
                val movie = current.movie ?: return@launch
                seq = maxOf(seq, room.lastAppliedSeq + 1)
                _state.update {
                    it.copy(
                        playback = PlaybackState(movieId = movie.id, lastSeq = room.lastAppliedSeq),
                        subtitleState = SubtitleState.create(movie.id, deps.subtitleOffsets.load(movie.id)),
                        suggestedOnlineQuery = onlineQueryFor(movie),
                    )
                }
                preparePlayer()
                // Late joiner (or host reopening the room): start from the host's saved state; the
                // host's live snapshot follows over IM.
                current.room?.let { applyServerPlayback(it, play = !current.isHost) }
                listen()
                startHeartbeatIfNeeded()
                refreshMemberProfiles()
                if (current.isHost || current.room?.subtitleRef.isNullOrEmpty()) {
                    refreshSubtitlesInternal(autoSelectChinese = true)
                } else {
                    refreshSubtitlesInternal(autoSelectChinese = false)
                    applyRoomSharedSubtitle()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(error = AppError.from(e, AppError.PlaybackFailed).toUiText()) }
            }
        }
    }

    /** Stops listeners + player. Safe to call more than once. */
    fun stop() {
        listenJobs.forEach { it.cancel() }
        listenJobs = emptyList()
        heartbeatJob?.cancel()
        heartbeatJob = null
        memberProfileJob?.cancel()
        memberProfileJob = null
        player.stop()
    }

    /** Releases the session (call when the screen is gone). */
    fun close() {
        stop()
        scope.cancel()
    }

    /**
     * App left the foreground. iOS suspends the stream and Android tears down the surface, so
     * playback stops here: a playing host pauses the whole room, a member pauses locally and
     * ignores remote play/seek until [onForeground].
     */
    fun onBackground() {
        if (backgroundedAtMs != null) return
        backgroundedAtMs = nowMs()
        backgroundPositionMs = player.currentPositionMs
        val wasPlaying = !player.isPaused
        player.pause()
        player.enterBackground()
        val room = current.room
        val user = me
        if (!wasPlaying || room == null || user == null || !current.isHost) return
        val position = backgroundPositionMs
        val currentSeq = nextSeq()
        _state.update {
            it.copy(playback = it.playback.copy(isPaused = true, positionMs = position, lastSeq = currentSeq))
        }
        scope.launch { runCatching { emitHost(room, user.id, PlaybackAction.PAUSE, position, currentSeq) } }
        reportPlayback(position, paused = true, seq = currentSeq)
    }

    /**
     * App is back. A long absence (or a player error) usually means a dead HTTP stream, so the
     * movie is re-prepared with a fresh URL at the saved position. The host stays paused and
     * resumes by hand; members realign to the host's server snapshot, then follow its heartbeats.
     */
    fun onForeground() {
        val since = backgroundedAtMs ?: return
        backgroundedAtMs = null
        player.enterForeground()
        if (current.movie == null) return
        val away = nowMs() - since
        val reload = away >= RELOAD_AFTER_BACKGROUND_MS || player.lastError != null
        val position = backgroundPositionMs
        scope.launch {
            if (reload) {
                preparePlayer()
                if (position > 0) player.seek(position)
                restoreSubtitleAfterReload()
            }
            // A paused host sends no heartbeats; the server snapshot realigns members right away.
            if (!current.isHost) realignFromServer()
        }
    }

    fun leave() {
        scope.launch {
            val room = current.room
            val user = me
            if (room != null && user != null) {
                val transferSeq = nextSeq()
                runCatching {
                    leaveRoom(room, user.id, player.currentPositionMs, transferSeq)
                }
            }
            stop()
            _events.emit(WatchEvent.Left)
        }
    }

    // endregion

    // region Members

    fun refreshMemberProfiles() {
        // Chat senders may have left the roster; their lines still need a name and avatar.
        val ids = (current.room?.memberIds.orEmpty() + current.messages.mapNotNull { it.senderId }).distinct()
        requestedProfileIds += ids
        if (ids.isEmpty()) {
            _state.update { it.copy(memberProfiles = emptyMap()) }
            return
        }
        memberProfileJob?.cancel()
        memberProfileJob = scope.launch {
            val users = runCatching { deps.authGateway.fetchUsers(ids) }.getOrDefault(emptyList())
            val map = users.associateBy { it.id }.toMutableMap()
            me?.let { map[it.id] = it }
            _state.update { it.copy(memberProfiles = map) }
        }
    }

    /** Playback fraction 0…1 for a member's progress ring (self = local player; others = last sync). */
    fun memberPlaybackProgress(memberId: String): Double {
        val duration = maxOf(player.durationMs, 1)
        val position = if (memberId == me?.id) {
            player.currentPositionMs
        } else {
            current.playback.positionMs.takeIf { it > 0 } ?: player.currentPositionMs
        }
        return (position.toDouble() / duration.toDouble()).coerceIn(0.0, 1.0)
    }

    // endregion

    // region Movie + player

    private suspend fun loadMovie(id: String) {
        val sourceId = Movie.placeholder(id).sourceId
        val movies = runCatching { listMovies(enrichMetadata = false, sourceId = sourceId) }.getOrDefault(emptyList())
        var movie = movies.firstOrNull { it.id == id } ?: Movie.placeholder(id)
        // Stage cover uses server-scraped art — enrich this title before prepare.
        var library = movies
        deps.configGateway.load()?.let { config ->
            movie = deps.metadataGateway.enrich(movie, config)
            library = library.map { if (it.id == movie.id) movie else it }
        }
        _state.update { it.copy(movie = movie, libraryMovies = library) }
    }

    private suspend fun preparePlayer() {
        val movie = current.movie ?: return
        player.stop()
        try {
            val config = deps.configGateway.load() ?: AppCloudConfig.empty()
            val url = deps.catalogGateway.playUrl(movie, config)
            val error = suspendCancellableCoroutine { cont ->
                player.prepare(url, movie.format) { message -> if (cont.isActive) cont.resume(message) }
            }
            val playerError = error ?: player.lastError
            if (playerError != null) _state.update { it.copy(error = UiText(playerError)) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(error = AppError.from(e, AppError.PlaybackFailed).toUiText()) }
        }
    }

    // endregion

    // region Listeners + heartbeat

    private fun listen() {
        val room = current.room ?: return
        listenJobs.forEach { it.cancel() }
        listenJobs = listOf(
            scope.launch { deps.syncGateway.signals(room).collect { applyRemote(it) } },
            scope.launch { deps.chatGateway.messages(room).collect { ingestChat(it) } },
            scope.launch {
                // Own avatar / nickname edits made from the Me sheet while in the room.
                deps.authGateway.currentUser.collect { user ->
                    if (user != null) _state.update { it.copy(memberProfiles = it.memberProfiles + (user.id to user)) }
                }
            },
            scope.launch {
                deps.roomGateway.observeRoom(room.id).collect { updated ->
                    val previousMembers = current.room?.memberIds.orEmpty()
                    val membersChanged = updated.memberIds != previousMembers
                    _state.update {
                        it.copy(
                            room = updated.copy(groupId = updated.groupId ?: it.room?.groupId),
                            error = if (updated.status == RoomStatus.ENDED) AppError.RoomEnded.toUiText() else it.error,
                        )
                    }
                    if (membersChanged) refreshMemberProfiles()
                    if (updated.memberIds.any { it !in previousMembers }) emitSnapshot()
                }
            },
        )
    }

    private fun startHeartbeatIfNeeded() {
        heartbeatJob?.cancel()
        heartbeatJob = null
        if (!current.isHost) return
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(PlaybackSyncRules.FOREGROUND_HEARTBEAT_MS)
                emitHeartbeat()
            }
        }
    }

    private fun emitHeartbeat() {
        // Avoid resume-via-heartbeat while paused (rules force isPaused=false on heartbeat).
        val room = current.room ?: return
        val user = me ?: return
        if (!current.isHost || player.isPaused) return
        val position = player.currentPositionMs
        val currentSeq = nextSeq()
        scope.launch {
            runCatching { emitHost(room, user.id, PlaybackAction.HEARTBEAT, position, currentSeq) }
            _state.update { it.copy(playback = it.playback.copy(positionMs = position, lastSeq = currentSeq)) }
        }
        reportPlayback(position, paused = false, seq = currentSeq, heartbeat = true)
    }

    /**
     * Host's current state as PLAY / PAUSE: newcomers only hear heartbeats while playing, and
     * members can ask for it with [requestSync].
     */
    private fun emitSnapshot() {
        val room = current.room ?: return
        val user = me ?: return
        if (!current.isHost) return
        val action = if (player.isPaused) PlaybackAction.PAUSE else PlaybackAction.PLAY
        val position = player.currentPositionMs
        val currentSeq = nextSeq()
        scope.launch {
            runCatching { emitHost(room, user.id, action, position, currentSeq) }
            _state.update { it.copy(playback = it.playback.copy(lastSeq = currentSeq)) }
        }
        reportPlayback(position, paused = action == PlaybackAction.PAUSE, seq = currentSeq)
    }

    /**
     * Host: saves the playback state on the server so members who join, reconnect or come back
     * from the background can align without waiting for the host. Best effort; heartbeats at most
     * every [PLAYBACK_REPORT_INTERVAL_MS].
     */
    private fun reportPlayback(positionMs: Long, paused: Boolean, seq: Long, heartbeat: Boolean = false) {
        val room = current.room ?: return
        val movieId = current.movie?.id ?: return
        if (!current.isHost) return
        val now = nowMs()
        if (heartbeat && now - lastPlaybackReportMs < PLAYBACK_REPORT_INTERVAL_MS) return
        lastPlaybackReportMs = now
        val snapshot = RoomPlayback(movieId = movieId, positionMs = positionMs, isPaused = paused, seq = seq)
        scope.launch { runCatching { deps.roomGateway.reportPlayback(room, snapshot) } }
    }

    /**
     * Applies the host's server snapshot when it is for the current movie and not older than what
     * this client already applied. [play] = false keeps the player paused (host reopening a room).
     */
    private fun applyServerPlayback(room: WatchRoom, play: Boolean): Boolean {
        val snapshot = room.playback ?: return false
        if (snapshot.movieId != current.movie?.id || snapshot.seq < current.playback.lastSeq) return false
        val position = snapshot.positionAt(room.serverTimeMs)
        val paused = snapshot.isPaused || !play
        _state.update { it.copy(playback = it.playback.copy(positionMs = position, isPaused = paused, lastSeq = snapshot.seq)) }
        seq = maxOf(seq, snapshot.seq)
        if (backgroundedAtMs != null) return true
        player.seek(position)
        if (paused) {
            if (!player.isPaused) player.pause()
        } else if (player.isPaused) {
            player.play()
        }
        return true
    }

    /** Member: reads the room and applies the host's snapshot; false when there is none to apply. */
    private suspend fun realignFromServer(): Boolean {
        val room = current.room ?: return false
        val fresh = runCatching { deps.roomGateway.fetchRoom(room.id) }.getOrNull() ?: return false
        return applyServerPlayback(fresh, play = true)
    }

    private suspend fun emitHostReporting(room: WatchRoom, hostUserId: String, action: PlaybackAction, positionMs: Long, seq: Long) {
        try {
            emitHost(room, hostUserId, action, positionMs, seq)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            toast("Playback sync failed — check your connection")
        }
    }

    private fun nextSeq(): Long {
        seq = maxOf(nowMs(), seq + 1)
        return seq
    }

    internal fun applyRemote(signal: PlaybackSyncSignal) {
        val room = current.room ?: return
        if (signal.action == PlaybackAction.SYNC_REQUEST) {
            answerSyncRequest()
            return
        }
        val result = PlaybackSyncRules.shouldAccept(signal, room, current.playback, player.currentPositionMs)
        if (result !is PlaybackSyncRules.ApplyResult.Applied) return
        val state = result.state
        // The host's PLAY / PAUSE snapshot answers a pending refresh; always realign on it.
        val answersRequest = current.isRequestingSync &&
            (signal.action == PlaybackAction.PLAY || signal.action == PlaybackAction.PAUSE)
        _state.update { it.copy(playback = state) }
        if (answersRequest) finishSyncRequest(synced = true)
        // A member promoted to host must keep emitting above the sequence it has already seen.
        seq = maxOf(seq, state.lastSeq)

        if (signal.action == PlaybackAction.HOST_TRANSFER) {
            val newHost = signal.hostUserId
            if (newHost != null) {
                _state.update {
                    it.copy(room = it.room?.copy(hostUserId = newHost, hostTransferSeq = signal.seq))
                }
                toast("Host is now {{name}}", mapOf("name" to current.memberDisplayName(newHost)))
                if (current.isHost) finishSyncRequest(synced = false)
                startHeartbeatIfNeeded()
            }
        }
        if (signal.action == PlaybackAction.MOVIE_CHANGE) {
            val movieId = signal.movieId
            // Host already applied locally in confirmSwitch; members follow here.
            if (movieId != null && current.movie?.id != movieId) {
                if (!current.isHost) toast("Host switched the movie…")
                scope.launch {
                    loadMovie(movieId)
                    _state.update {
                        it.copy(
                            subtitleState = SubtitleState.create(movieId, deps.subtitleOffsets.load(movieId)),
                            suggestedOnlineQuery = it.movie?.let(::onlineQueryFor) ?: it.suggestedOnlineQuery,
                        )
                    }
                    preparePlayer()
                    refreshSubtitlesInternal(autoSelectChinese = true)
                }
            }
        }
        if (signal.action == PlaybackAction.SUBTITLE_CHANGE && signal.senderId != me?.id) {
            // Host already loaded locally before broadcasting; skip self-echo.
            scope.launch { applyHostSharedSubtitle(signal) }
        }
        // No playback while backgrounded; the host's next heartbeat realigns after return.
        if (backgroundedAtMs != null) return
        if (result.seek || answersRequest) player.seek(state.positionMs)
        // Avoid pause↔play thrash on heartbeat when already in the right state.
        if (state.isPaused) {
            if (!player.isPaused) player.pause()
        } else if (player.isPaused) {
            // Host must not auto-start from a stray heartbeat/echo while still on the poster.
            val ignore = signal.action == PlaybackAction.HEARTBEAT && current.isHost && !player.hasStartedPlayback
            if (!ignore) player.play()
        }
    }

    // endregion

    // region Member refresh

    /** Member "refresh": ask the host for its current position and play / pause state. */
    fun requestSync() {
        val room = current.room ?: return
        val user = me ?: return
        if (current.isHost || current.isRequestingSync) return
        _state.update { it.copy(isRequestingSync = true) }
        syncRequestJob = scope.launch {
            val request = PlaybackSyncSignal(
                action = PlaybackAction.SYNC_REQUEST,
                positionMs = player.currentPositionMs,
                movieId = room.movieId,
                senderId = user.id,
                clientTs = nowMs(),
                seq = 0,
            )
            try {
                deps.syncGateway.send(room, request)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                _state.update { it.copy(isRequestingSync = false) }
                toast("Playback sync failed — check your connection")
                return@launch
            }
            delay(PlaybackSyncRules.SYNC_REQUEST_TIMEOUT_MS)
            if (!current.isRequestingSync) return@launch
            // Host offline or backgrounded: fall back to its last snapshot on the server.
            if (realignFromServer()) {
                finishSyncRequest(synced = true)
            } else if (current.isRequestingSync) {
                _state.update { it.copy(isRequestingSync = false) }
                toast("The host didn't respond. Try again in a moment")
            }
        }
    }

    private fun finishSyncRequest(synced: Boolean) {
        if (!current.isRequestingSync) return
        syncRequestJob?.cancel()
        syncRequestJob = null
        _state.update { it.copy(isRequestingSync = false) }
        if (synced) toast("Synced with the host")
    }

    private fun answerSyncRequest() {
        if (!current.isHost) return
        val now = nowMs()
        if (now - lastSyncAnswerMs < PlaybackSyncRules.SYNC_ANSWER_MIN_INTERVAL_MS) return
        lastSyncAnswerMs = now
        emitSnapshot()
    }

    // endregion

    // region Host controls

    fun togglePlay() {
        val room = current.room ?: return
        val user = me ?: return
        if (!current.isHost) return
        val action = if (player.isPaused) PlaybackAction.PLAY else PlaybackAction.PAUSE
        val position = player.currentPositionMs
        val currentSeq = nextSeq()
        reportPlayback(position, paused = action == PlaybackAction.PAUSE, seq = currentSeq)
        scope.launch {
            emitHostReporting(room, user.id, action, position, currentSeq)
            if (action == PlaybackAction.PLAY) player.play() else player.pause()
            _state.update {
                it.copy(
                    playback = it.playback.copy(
                        isPaused = action == PlaybackAction.PAUSE,
                        positionMs = position,
                        lastSeq = currentSeq,
                    ),
                )
            }
        }
    }

    /** Host scrub / seek — updates the local player immediately and broadcasts `seek`. */
    fun seekTo(positionMs: Long) {
        val room = current.room ?: return
        val user = me ?: return
        if (!current.isHost) return
        val clamped = positionMs.coerceIn(0, maxOf(player.durationMs, 1))
        val currentSeq = nextSeq()
        val wasPaused = player.isPaused
        player.seek(clamped)
        _state.update { it.copy(playback = it.playback.copy(positionMs = clamped, lastSeq = currentSeq)) }
        reportPlayback(clamped, paused = wasPaused, seq = currentSeq)
        scope.launch {
            emitHostReporting(room, user.id, PlaybackAction.SEEK, clamped, currentSeq)
            if (!wasPaused) player.play()
        }
    }

    fun seekToProgress(progress: Double) {
        val duration = maxOf(player.durationMs, 1)
        seekTo((duration * progress.coerceIn(0.0, 1.0)).toLong())
    }

    fun loadLibraryForSwitch() {
        scope.launch {
            _state.update { it.copy(isLoadingLibraryForSwitch = true) }
            val sourceId = current.movie?.sourceId
            val movies = runCatching { listMovies(enrichMetadata = false, sourceId = sourceId) }.getOrDefault(emptyList())
            if (movies.isNotEmpty()) _state.update { it.copy(libraryMovies = movies) }
            _state.update { it.copy(isLoadingLibraryForSwitch = false) }
            // Enrich posters in background for the switch list thumbs.
            val snapshot = current.libraryMovies
            val config = deps.configGateway.load() ?: return@launch
            val enriched = runCatching { listMovies.enrich(snapshot, config) }.getOrNull() ?: return@launch
            // Keep list if user already refreshed to a different set.
            _state.update {
                if (it.libraryMovies.map(Movie::id) == snapshot.map(Movie::id)) it.copy(libraryMovies = enriched) else it
            }
        }
    }

    fun confirmSwitch(target: Movie) {
        val room = current.room ?: return
        val user = me ?: return
        if (current.isSwitchingMovie) return
        _state.update { it.copy(isSwitchingMovie = true) }
        val currentSeq = nextSeq()
        scope.launch {
            try {
                val result = changeMovie(room, user.id, target, currentSeq)
                var next = target
                deps.configGateway.load()?.let { next = deps.metadataGateway.enrich(next, it) }
                _state.update {
                    it.copy(
                        room = result.room,
                        movie = next,
                        suggestedOnlineQuery = onlineQueryFor(next),
                        playback = PlaybackState(positionMs = 0, isPaused = true, movieId = next.id, lastSeq = currentSeq),
                        subtitleState = SubtitleState.create(next.id, deps.subtitleOffsets.load(next.id)),
                    )
                }
                player.pause()
                preparePlayer()
                refreshSubtitlesInternal(autoSelectChinese = true)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val error = AppError.from(e, AppError.MovieChangeFailed)
                _state.update { it.copy(error = error.toUiText()) }
                _events.emit(WatchEvent.Toast(error.toUiText()))
            } finally {
                _state.update { it.copy(isSwitchingMovie = false) }
            }
        }
    }

    // endregion

    // region Chat

    fun sendChat(text: String) {
        val room = current.room ?: return
        val user = me ?: return
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        scope.launch { runCatching { deps.chatGateway.send(room, trimmed, user) }.onFailure(::reportChatFailure) }
    }

    fun sendSticker(sticker: StickerRef) {
        val room = current.room ?: return
        val user = me ?: return
        scope.launch { runCatching { deps.chatGateway.sendSticker(room, sticker, user) }.onFailure(::reportChatFailure) }
    }

    fun blockSender(message: ChatMessage) {
        val ownerId = me?.id ?: return
        val senderId = message.senderId ?: return
        _state.update { s -> s.copy(messages = s.messages.filter { it.senderId != senderId }) }
        toast("Blocked {{name}}", mapOf("name" to message.senderNickname.ifEmpty { senderId }))
        scope.launch { runCatching { blockUser(senderId, ownerId) } }
    }

    fun report(message: ChatMessage) {
        if (message.senderId == null) return
        scope.launch {
            try {
                reportMessage(message)
                toast("Report submitted. An admin will review it")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val error = AppError.from(e)
                _events.tryEmit(WatchEvent.Toast(error.toUiText()))
            }
        }
    }

    private fun syncBlockList() {
        val ownerId = me?.id ?: return
        scope.launch {
            runCatching { syncBlocks(ownerId) }
            refilterBlocked(ownerId)
        }
    }

    private fun refilterBlocked(ownerId: String) {
        _state.update { it.copy(messages = deps.chatSafety.visibleMessages(it.messages, ownerId)) }
    }

    private fun reportChatFailure(e: Throwable) {
        if (e is CancellationException) throw e
        toast("Message failed to send")
    }

    private fun ingestChat(message: ChatMessage) {
        val ownerId = me?.id
        _state.update { s ->
            if (s.messages.any { it.id == message.id }) return@update s
            val next = s.messages + message
            s.copy(messages = if (ownerId != null) deps.chatSafety.visibleMessages(next, ownerId) else next)
        }
        val senderId = message.senderId
        if (senderId != null && senderId !in requestedProfileIds) refreshMemberProfiles()
    }

    // endregion

    // region Subtitles

    fun refreshSubtitles(autoSelectChinese: Boolean = false) {
        scope.launch { refreshSubtitlesInternal(autoSelectChinese) }
    }

    private suspend fun refreshSubtitlesInternal(autoSelectChinese: Boolean) {
        val movie = current.movie ?: return
        val listed = runCatching { listTracks(movie) }.getOrDefault(listOf(SubtitleTrack.OFF))
        // Give the player a moment to parse embedded tracks after prepare.
        if (player.embeddedSubtitleTracks().isEmpty()) delay(400)
        val embedded = player.embeddedSubtitleTracks()
        val off = listed.filter { it.source == SubtitleSource.OFF }
        val libraryTracks = listed.filter { it.source == SubtitleSource.LIBRARY }
        val selected = current.subtitleState
        // Keep host-shared / online selections that aren't in the fresh sidecar list.
        val preserved = current.subtitleTracks.filter { track ->
            when {
                track.source == SubtitleSource.OFF || track.source == SubtitleSource.EMBEDDED -> false
                libraryTracks.any { it.id == track.id } -> false
                track.id.startsWith("shared:") -> true
                else -> track.source == SubtitleSource.ONLINE && track.id == selected.trackId
            }
        }
        _state.update { it.copy(subtitleTracks = off + embedded + libraryTracks + preserved) }

        val state = current.subtitleState
        val unselected = state.source == SubtitleSource.OFF || state.trackId == null || state.trackId == "off"
        val preferred = current.subtitleTracks.firstOrNull { it.source != SubtitleSource.OFF && it.isChinesePreferred }
        if (autoSelectChinese && unselected && preferred != null) {
            selectTrackInternal(preferred)
        } else if (state.source != SubtitleSource.OFF) {
            player.applySubtitleOffsetMs(state.offsetMs)
        }
    }

    fun selectTrack(track: SubtitleTrack) {
        scope.launch { selectTrackInternal(track) }
    }

    private suspend fun selectTrackInternal(track: SubtitleTrack) {
        if (current.isApplyingSubtitle) return
        _state.update { it.copy(isApplyingSubtitle = true) }
        try {
            val movieId = current.movie?.id ?: current.subtitleState.movieId
            val retainedOffset = current.subtitleState.offsetMs

            if (track.source == SubtitleSource.OFF) {
                player.disableSubtitles()
                _state.update {
                    it.copy(subtitleState = SubtitleState(movieId, SubtitleSource.OFF, "off", offsetMs = retainedOffset))
                }
                // Only clear members if this host previously shared a file-based subtitle.
                if (current.isHost && lastHostSharedSubtitleKey != null) {
                    lastHostSharedSubtitleKey = null
                    broadcastHostSubtitleShare(ref = null, label = null, movieId = movieId)
                }
                return
            }

            var sharedLocalPath: String? = null
            when (track.source) {
                SubtitleSource.EMBEDDED -> {
                    val index = track.embeddedIndex ?: throw AppError.SubtitleUnavailable
                    player.selectEmbeddedSubtitle(index)
                    // Re-apply after index change; some VLC builds reset delay on track switch.
                    player.applySubtitleOffsetMs(retainedOffset)
                }
                SubtitleSource.LIBRARY, SubtitleSource.ONLINE -> {
                    val path = deps.subtitleGateway.download(track, deps.configGateway.load())
                    if (!player.loadExternalSubtitle(path)) throw AppError.SubtitleUnavailable
                    sharedLocalPath = path
                }
                SubtitleSource.OFF -> Unit
            }

            _state.update { s ->
                val tracks = if (track.source == SubtitleSource.ONLINE && s.subtitleTracks.none { it.id == track.id }) {
                    // Keep selected online track visible under Current.
                    s.subtitleTracks.toMutableList().apply { add(minOf(1, size), track) }
                } else {
                    s.subtitleTracks
                }
                s.copy(
                    subtitleState = SubtitleState(
                        movieId = movieId,
                        source = track.source,
                        trackId = track.id,
                        url = track.url,
                        embeddedIndex = track.embeddedIndex,
                        offsetMs = retainedOffset,
                    ),
                    subtitleTracks = tracks,
                )
            }
            player.applySubtitleOffsetMs(retainedOffset)

            // Host: share the subtitle through the server and instruct members to load it. Member
            // downloads remain local-only; embedded tracks have no portable file (host-only).
            val path = sharedLocalPath
            if (current.isHost && path != null) shareDownloadedSubtitleWithRoom(path, track, movieId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _events.emit(WatchEvent.Toast(AppError.from(e, AppError.SubtitleUnavailable).toUiText()))
        } finally {
            _state.update { it.copy(isApplyingSubtitle = false) }
        }
    }

    /**
     * Host shares the subtitle with the room. Library sidecars are already readable by every
     * member, so only their ref is broadcast; online / local downloads are uploaded to the server.
     */
    private suspend fun shareDownloadedSubtitleWithRoom(localPath: String, track: SubtitleTrack, movieId: String) {
        val room = current.room ?: return
        if (me == null || !current.isHost) return
        val config = deps.configGateway.load() ?: return
        try {
            val ref = if (track.source == SubtitleSource.LIBRARY && track.url != null) {
                track.url
            } else {
                deps.sharedSubtitleStorage.upload(localPath, room.id, track.label, config)
            }
            broadcastHostSubtitleShare(ref, track.label, movieId)
            lastHostSharedSubtitleKey = ref
            runCatching { deps.chatGateway.postSystemMessage(room, "Host shared subtitles: ${track.label}") }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            _events.emit(WatchEvent.Toast(AppError.SubtitleShareFailed.toUiText()))
        }
    }

    private suspend fun broadcastHostSubtitleShare(ref: String?, label: String?, movieId: String) {
        val room = current.room ?: return
        val user = me ?: return
        if (!current.isHost) return
        val currentSeq = nextSeq()
        runCatching {
            emitHost(
                room = room,
                hostUserId = user.id,
                action = PlaybackAction.SUBTITLE_CHANGE,
                positionMs = player.currentPositionMs,
                seq = currentSeq,
                movieId = movieId,
                subtitleObjectKey = ref,
                subtitleLabel = label,
            )
        }
        _state.update { it.copy(playback = it.playback.copy(lastSeq = currentSeq)) }
    }

    /** Member follows a host-shared subtitle (local offset retained). */
    private suspend fun applyHostSharedSubtitle(signal: PlaybackSyncSignal) {
        val signalMovie = signal.movieId
        val currentMovie = current.movie?.id
        if (!signalMovie.isNullOrEmpty() && currentMovie != null && signalMovie != currentMovie) return
        val movieId = signalMovie ?: currentMovie ?: current.subtitleState.movieId
        loadHostSharedSubtitle(signal.subtitleObjectKey, signal.subtitleLabel, movieId)
    }

    /** Late joiner: the room remembers the host's last shared subtitle. */
    private suspend fun applyRoomSharedSubtitle() {
        val room = current.room ?: return
        val movie = current.movie ?: return
        if (current.isHost || room.subtitleRef.isNullOrEmpty() || room.movieId != movie.id) return
        loadHostSharedSubtitle(room.subtitleRef, room.subtitleLabel, movie.id)
    }

    private suspend fun loadHostSharedSubtitle(ref: String?, rawLabel: String?, movieId: String) {
        val retainedOffset = current.subtitleState.offsetMs
        if (ref.isNullOrEmpty()) {
            player.disableSubtitles()
            _state.update {
                it.copy(subtitleState = SubtitleState(movieId, SubtitleSource.OFF, "off", offsetMs = retainedOffset))
            }
            return
        }

        val config = deps.configGateway.load() ?: return
        try {
            val path = deps.sharedSubtitleStorage.download(ref, config)
            if (!player.loadExternalSubtitle(path)) throw AppError.SubtitleUnavailable
            val label = rawLabel?.trim()?.ifEmpty { null } ?: "Host shared"
            val track = SubtitleTrack(
                id = "shared:$ref",
                label = label,
                source = SubtitleSource.LIBRARY,
                url = ref,
                detail = "Host shared",
                format = Paths.pathExtension(ref).uppercase(),
            )
            _state.update { s ->
                s.copy(
                    subtitleState = SubtitleState(movieId, SubtitleSource.LIBRARY, track.id, offsetMs = retainedOffset),
                    subtitleTracks = if (s.subtitleTracks.any { it.id == track.id }) {
                        s.subtitleTracks
                    } else {
                        s.subtitleTracks.toMutableList().apply { add(minOf(1, size), track) }
                    },
                )
            }
            player.applySubtitleOffsetMs(retainedOffset)
            toast("Loaded host-shared subtitles")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _events.emit(WatchEvent.Toast(AppError.from(e, AppError.SubtitleUnavailable).toUiText()))
        }
    }

    /** Re-prepare drops the player's subtitle selection; load the current one again without re-sharing it. */
    private suspend fun restoreSubtitleAfterReload() {
        val state = current.subtitleState
        val trackId = state.trackId
        if (state.source == SubtitleSource.OFF || trackId == null) return
        try {
            when {
                state.source == SubtitleSource.EMBEDDED -> {
                    val index = state.embeddedIndex ?: return
                    if (player.embeddedSubtitleTracks().isEmpty()) delay(400)
                    player.selectEmbeddedSubtitle(index)
                }
                trackId.startsWith("shared:") -> {
                    val config = deps.configGateway.load() ?: return
                    player.loadExternalSubtitle(deps.sharedSubtitleStorage.download(trackId.removePrefix("shared:"), config))
                }
                else -> {
                    val track = current.subtitleTracks.firstOrNull { it.id == trackId } ?: return
                    player.loadExternalSubtitle(deps.subtitleGateway.download(track, deps.configGateway.load()))
                }
            }
            player.applySubtitleOffsetMs(state.offsetMs)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            _events.emit(WatchEvent.Toast(AppError.SubtitleUnavailable.toUiText()))
        }
    }

    fun adjustSubtitle(deltaMs: Int) {
        _state.update { it.copy(subtitleState = it.subtitleState.withOffsetDelta(deltaMs)) }
        persistAndApplyOffset()
    }

    fun resetSubtitleOffset() {
        _state.update { it.copy(subtitleState = it.subtitleState.withResetOffset()) }
        persistAndApplyOffset()
    }

    private fun persistAndApplyOffset() {
        val state = current.subtitleState
        val movieId = current.movie?.id ?: state.movieId
        if (movieId.isNotEmpty()) deps.subtitleOffsets.save(movieId, state.offsetMs)
        if (state.source != SubtitleSource.OFF) player.applySubtitleOffsetMs(state.offsetMs)
    }

    fun searchOnline(query: String) {
        scope.launch {
            _state.update { it.copy(isSearchingOnline = true, onlineSearchError = null) }
            try {
                val results = searchSubtitles(query, current.movie?.year)
                _state.update { it.copy(onlineResults = results, didSearchOnline = true) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        onlineResults = emptyList(),
                        didSearchOnline = true,
                        onlineSearchError = AppError.from(e, AppError.SubtitleUnavailable).toUiText(),
                    )
                }
            } finally {
                _state.update { it.copy(isSearchingOnline = false) }
            }
        }
    }

    // endregion

    fun inviteUrl(): String {
        val s = current
        return InviteLinks.inviteUrl(
            roomId = s.room?.id.orEmpty(),
            movieId = s.room?.movieId ?: s.movie?.id.orEmpty(),
            hostUserId = s.room?.hostUserId.orEmpty(),
            inviterName = me?.displayName.orEmpty(),
            movieTitle = s.movie?.title.orEmpty(),
        )
    }

    private fun toast(key: String, args: Map<String, String> = emptyMap()) {
        _events.tryEmit(WatchEvent.Toast(UiText(key, args)))
    }

    private fun onlineQueryFor(movie: Movie): String =
        listOfNotNull(movie.title, movie.year).filter { it.isNotEmpty() }.joinToString(" ")

    internal companion object {
        /** Away at least this long → the HTTP stream is assumed dead and re-prepared. */
        const val RELOAD_AFTER_BACKGROUND_MS = 15_000L

        /** Minimum gap between heartbeat-driven playback snapshots saved on the server. */
        const val PLAYBACK_REPORT_INTERVAL_MS = 15_000L
    }
}
