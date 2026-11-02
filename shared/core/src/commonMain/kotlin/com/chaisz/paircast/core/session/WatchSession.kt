package com.chaisz.paircast.core.session

import com.chaisz.paircast.core.gateway.AuthGateway
import com.chaisz.paircast.core.gateway.ChatGateway
import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.gateway.MetadataGateway
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
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleState
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.UiText
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.model.VideoFormat
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
) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val _state = MutableStateFlow(WatchUiState(selfId = deps.authGateway.currentUser.value?.id))
    val state: StateFlow<WatchUiState> = _state.asStateFlow()
    private val _events = MutableSharedFlow<WatchEvent>(extraBufferCapacity = 32)
    val events: SharedFlow<WatchEvent> = _events.asSharedFlow()

    private val listMovies = ListMoviesUseCase(deps.configGateway, deps.catalogGateway, deps.metadataGateway)
    private val emitHost = EmitHostPlaybackUseCase(deps.syncGateway)
    private val changeMovie = ChangeMovieUseCase(deps.roomGateway, deps.syncGateway, deps.chatGateway)
    private val leaveRoom = LeaveRoomUseCase(deps.roomGateway, deps.chatGateway, deps.syncGateway)
    private val listTracks = ListSubtitleTracksUseCase(deps.configGateway, deps.subtitleGateway)
    private val searchSubtitles = SearchOnlineSubtitlesUseCase(deps.configGateway, deps.subtitleGateway)

    private var seq: Long = 1
    private var listenJobs: List<Job> = emptyList()
    private var heartbeatJob: Job? = null
    private var memberProfileJob: Job? = null
    /** Last object key the host shared this session; used to clear members only when needed. */
    private var lastHostSharedSubtitleKey: String? = null

    private val me: User? get() = deps.authGateway.currentUser.value
    private val current: WatchUiState get() = _state.value

    // region Lifecycle

    fun start() {
        scope.launch {
            try {
                val user = me ?: return@launch
                _state.update { it.copy(selfId = user.id) }
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
                listen()
                startHeartbeatIfNeeded()
                refreshMemberProfiles()
                refreshSubtitlesInternal(autoSelectChinese = true)
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

    fun leave() {
        scope.launch {
            val room = current.room
            val user = me
            if (room != null && user != null) {
                seq += 1
                runCatching {
                    leaveRoom(room, user.id, player.currentPositionMs, seq)
                }
            }
            stop()
            _events.emit(WatchEvent.Left)
        }
    }

    // endregion

    // region Members

    fun refreshMemberProfiles() {
        val ids = current.room?.memberIds.orEmpty()
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
        val movies = runCatching { listMovies(enrichMetadata = false) }.getOrDefault(emptyList())
        var movie = movies.firstOrNull { it.id == id }
            ?: Movie(id = id, objectKey = id, title = id, format = VideoFormat.fromFilename(id) ?: VideoFormat.MP4)
        // Stage cover uses storage/TMDB art — enrich this title before prepare.
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
                deps.roomGateway.observeRoom(room.id).collect { updated ->
                    val membersChanged = updated.memberIds != current.room?.memberIds
                    _state.update {
                        it.copy(
                            room = updated.copy(groupId = updated.groupId ?: it.room?.groupId),
                            error = if (updated.status == RoomStatus.ENDED) AppError.RoomEnded.toUiText() else it.error,
                        )
                    }
                    if (membersChanged) refreshMemberProfiles()
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
        seq += 1
        val position = player.currentPositionMs
        val currentSeq = seq
        scope.launch {
            runCatching { emitHost(room, user.id, PlaybackAction.HEARTBEAT, position, currentSeq) }
            _state.update { it.copy(playback = it.playback.copy(positionMs = position, lastSeq = currentSeq)) }
        }
    }

    internal fun applyRemote(signal: PlaybackSyncSignal) {
        val room = current.room ?: return
        val result = PlaybackSyncRules.shouldAccept(signal, room, current.playback, player.currentPositionMs)
        if (result !is PlaybackSyncRules.ApplyResult.Applied) return
        val state = result.state
        _state.update { it.copy(playback = state) }
        // A member promoted to host must keep emitting above the sequence it has already seen.
        seq = maxOf(seq, state.lastSeq)

        if (signal.action == PlaybackAction.HOST_TRANSFER) {
            val newHost = signal.hostUserId
            if (newHost != null) {
                _state.update {
                    it.copy(room = it.room?.copy(hostUserId = newHost, hostTransferSeq = signal.seq))
                }
                toast("Host is now {{name}}", mapOf("name" to current.memberDisplayName(newHost)))
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
        if (result.seek) player.seek(state.positionMs)
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

    // region Host controls

    fun togglePlay() {
        val room = current.room ?: return
        val user = me ?: return
        if (!current.isHost) return
        val action = if (player.isPaused) PlaybackAction.PLAY else PlaybackAction.PAUSE
        val position = player.currentPositionMs
        seq += 1
        val currentSeq = seq
        scope.launch {
            runCatching { emitHost(room, user.id, action, position, currentSeq) }
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
        seq += 1
        val currentSeq = seq
        val wasPaused = player.isPaused
        player.seek(clamped)
        _state.update { it.copy(playback = it.playback.copy(positionMs = clamped, lastSeq = currentSeq)) }
        scope.launch {
            runCatching { emitHost(room, user.id, PlaybackAction.SEEK, clamped, currentSeq) }
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
            val movies = runCatching { listMovies(enrichMetadata = false) }.getOrDefault(emptyList())
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
        seq += 1
        val currentSeq = seq
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
        scope.launch { runCatching { deps.chatGateway.send(room, trimmed, user) } }
    }

    fun sendSticker(sticker: StickerRef) {
        val room = current.room ?: return
        val user = me ?: return
        scope.launch { runCatching { deps.chatGateway.sendSticker(room, sticker, user) } }
    }

    fun blockSender(message: ChatMessage) {
        val ownerId = me?.id ?: return
        val senderId = message.senderId ?: return
        deps.chatSafety.block(senderId, ownerId)
        _state.update { it.copy(messages = deps.chatSafety.visibleMessages(it.messages, ownerId)) }
        toast("Blocked {{name}}", mapOf("name" to message.senderNickname.ifEmpty { senderId }))
    }

    fun report(message: ChatMessage) {
        val ownerId = me?.id ?: return
        val senderId = message.senderId ?: return
        deps.chatSafety.recordReport(senderId, ownerId, message.text)
        toast("Report recorded — opening feedback")
    }

    private fun ingestChat(message: ChatMessage) {
        val ownerId = me?.id
        _state.update { s ->
            if (s.messages.any { it.id == message.id }) return@update s
            val next = s.messages + message
            s.copy(messages = if (ownerId != null) deps.chatSafety.visibleMessages(next, ownerId) else next)
        }
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
        val ossTracks = listed.filter { it.source == SubtitleSource.OSS }
        val selected = current.subtitleState
        // Keep host-shared / online selections that aren't in the fresh storage sidecar list.
        val preserved = current.subtitleTracks.filter { track ->
            when {
                track.source == SubtitleSource.OFF || track.source == SubtitleSource.EMBEDDED -> false
                ossTracks.any { it.id == track.id } -> false
                track.id.startsWith("shared:") -> true
                else -> track.source == SubtitleSource.ONLINE && track.id == selected.trackId
            }
        }
        _state.update { it.copy(subtitleTracks = off + embedded + ossTracks + preserved) }

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
                    broadcastHostSubtitleShare(objectKey = null, label = null, movieId = movieId)
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
                SubtitleSource.OSS, SubtitleSource.ONLINE -> {
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

            // Host: upload downloaded file to storage and instruct members to load it. Member
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

    /** Host uploads a downloaded subtitle and broadcasts `subtitle_change`. */
    private suspend fun shareDownloadedSubtitleWithRoom(localPath: String, track: SubtitleTrack, movieId: String) {
        val room = current.room ?: return
        if (me == null || !current.isHost) return
        val config = deps.configGateway.load()
        if (config == null || !config.storage.isComplete) {
            toast("Subtitles loaded (library not configured — cannot sync to members)")
            return
        }
        try {
            val movieObjectKey = current.movie?.objectKey ?: movieId
            val key = deps.sharedSubtitleStorage.upload(localPath, room.id, movieObjectKey, config)
            broadcastHostSubtitleShare(key, track.label, movieObjectKey)
            lastHostSharedSubtitleKey = key
            runCatching { deps.chatGateway.postSystemMessage(room, "Host shared subtitles: ${track.label}") }
            // Sidecar now lives beside the movie — refresh sidecars and mark it current.
            refreshSubtitlesInternal(autoSelectChinese = false)
            current.subtitleTracks.firstOrNull { it.id == "oss:$key" }?.let { sidecar ->
                _state.update {
                    it.copy(
                        subtitleState = SubtitleState(
                            movieId = movieObjectKey,
                            source = SubtitleSource.OSS,
                            trackId = sidecar.id,
                            url = sidecar.url,
                            offsetMs = it.subtitleState.offsetMs,
                        ),
                    )
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            _events.emit(WatchEvent.Toast(AppError.SubtitleShareFailed.toUiText()))
        }
    }

    private suspend fun broadcastHostSubtitleShare(objectKey: String?, label: String?, movieId: String) {
        val room = current.room ?: return
        val user = me ?: return
        if (!current.isHost) return
        seq += 1
        val currentSeq = seq
        runCatching {
            emitHost(
                room = room,
                hostUserId = user.id,
                action = PlaybackAction.SUBTITLE_CHANGE,
                positionMs = player.currentPositionMs,
                seq = currentSeq,
                movieId = movieId,
                subtitleObjectKey = objectKey,
                subtitleLabel = label,
            )
        }
        _state.update { it.copy(playback = it.playback.copy(lastSeq = currentSeq)) }
    }

    /** Member follows host-shared subtitle from object storage (local offset retained). */
    private suspend fun applyHostSharedSubtitle(signal: PlaybackSyncSignal) {
        val signalMovie = signal.movieId
        val currentMovie = current.movie?.id
        if (!signalMovie.isNullOrEmpty() && currentMovie != null && signalMovie != currentMovie) return
        val movieId = signalMovie ?: currentMovie ?: current.subtitleState.movieId
        val retainedOffset = current.subtitleState.offsetMs

        val key = signal.subtitleObjectKey
        if (key.isNullOrEmpty()) {
            player.disableSubtitles()
            _state.update {
                it.copy(subtitleState = SubtitleState(movieId, SubtitleSource.OFF, "off", offsetMs = retainedOffset))
            }
            return
        }

        val config = deps.configGateway.load()
        if (config == null || !config.storage.isComplete) {
            _events.emit(WatchEvent.Toast(AppError.SubtitleUnavailable.toUiText()))
            return
        }
        try {
            val path = deps.sharedSubtitleStorage.download(key, config)
            if (!player.loadExternalSubtitle(path)) throw AppError.SubtitleUnavailable
            val label = signal.subtitleLabel?.trim()?.ifEmpty { null } ?: "Host shared"
            val track = SubtitleTrack(
                id = "shared:$key",
                label = label,
                source = SubtitleSource.OSS,
                detail = "Host shared",
                format = Paths.pathExtension(key).uppercase(),
            )
            _state.update { s ->
                s.copy(
                    subtitleState = SubtitleState(movieId, SubtitleSource.OSS, track.id, offsetMs = retainedOffset),
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
}
