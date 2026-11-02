package com.chaisz.paircast.core

import com.chaisz.paircast.core.gateway.AuthGateway
import com.chaisz.paircast.core.gateway.ChatGateway
import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.gateway.ConfigLinkCodec
import com.chaisz.paircast.core.gateway.ConnectionState
import com.chaisz.paircast.core.gateway.MetadataGateway
import com.chaisz.paircast.core.gateway.MovieCatalogGateway
import com.chaisz.paircast.core.gateway.PlaybackSyncGateway
import com.chaisz.paircast.core.gateway.RoomGateway
import com.chaisz.paircast.core.gateway.SessionEvent
import com.chaisz.paircast.core.gateway.SharedSubtitleStorageGateway
import com.chaisz.paircast.core.gateway.SubtitleGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.LoginResult
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.model.VideoFormat
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.rules.ConfigQRCodec
import com.chaisz.paircast.core.session.PlayerPort
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow

internal fun movieFixture(id: String, title: String = "Title") =
    Movie(id = id, objectKey = "$id.mp4", title = title, format = VideoFormat.MP4)

internal class FakeConfigGateway(var config: AppCloudConfig? = null) : ConfigGateway {
    override suspend fun load() = config
    override suspend fun save(config: AppCloudConfig) { this.config = config }
    override suspend fun clearAll() { config = null }
}

/** Plaintext "link" codec so core tests stay crypto-free. */
internal class PlainLinkCodec : ConfigLinkCodec {
    override fun shareUrl(config: AppCloudConfig) = "paircast://config?args=" + ConfigQRCodec.encode(config)
    override fun decode(input: String): AppCloudConfig = ConfigQRCodec.decode(input.removePrefix("paircast://config?args="))
}

internal class FakeAuthGateway(user: User? = User("host", "Host")) : AuthGateway {
    override val currentUser = MutableStateFlow(user)
    override val connection: StateFlow<ConnectionState> = MutableStateFlow(ConnectionState.CONNECTED)
    override val events: Flow<SessionEvent> = emptyFlow()
    var loginCalls = 0
    var password = "secret"

    override suspend fun login(account: String, password: String): LoginResult {
        loginCalls++
        if (password != this.password) throw AppError.InvalidCredentials
        val u = User(account, account)
        currentUser.value = u
        return LoginResult(u, mustChangePassword = false)
    }
    override suspend fun restoreSession() = currentUser.value
    override suspend fun changePassword(oldPassword: String, newPassword: String) { password = newPassword }
    override suspend fun logout() { currentUser.value = null }
    override suspend fun updateProfile(nickname: String, avatarJpeg: ByteArray?) = User("u", nickname)
    override suspend fun fetchProfile() = currentUser.value!!
    override suspend fun fetchUsers(userIds: List<String>) = userIds.map { User(it, "nick-$it") }
    override suspend fun deleteAccount() { currentUser.value = null }
}

internal class FakeRoomGateway : RoomGateway {
    val rooms = mutableMapOf<String, WatchRoom>()
    val left = mutableListOf<String>()
    val updates = MutableSharedFlow<WatchRoom>(extraBufferCapacity = 8)

    override suspend fun createRoom(movieId: String, hostUserId: String) =
        WatchRoom(id = "r${rooms.size + 1}", movieId = movieId, hostUserId = hostUserId, groupId = "g_1").also { rooms[it.id] = it }

    override suspend fun joinRoom(roomId: String, userId: String, movieId: String?, hostUserId: String?): WatchRoom {
        val room = rooms[roomId] ?: WatchRoom(id = roomId, movieId = movieId ?: "m", hostUserId = hostUserId ?: userId)
        val joined = if (userId in room.memberIds) room else room.copy(memberIds = room.memberIds + userId, joinOrder = room.joinOrder + userId)
        rooms[roomId] = joined
        return joined
    }

    override suspend fun leaveRoom(room: WatchRoom, userId: String): WatchRoom? {
        left += userId
        return rooms[room.id]
    }

    override suspend fun updateRoom(room: WatchRoom) { rooms[room.id] = room }
    override fun observeRoom(roomId: String): Flow<WatchRoom> = updates
}

internal class FakeSyncGateway : PlaybackSyncGateway {
    val sent = mutableListOf<PlaybackSyncSignal>()
    val incoming = MutableSharedFlow<PlaybackSyncSignal>(extraBufferCapacity = 8)
    override suspend fun send(room: WatchRoom, signal: PlaybackSyncSignal) { sent += signal }
    override fun signals(room: WatchRoom): Flow<PlaybackSyncSignal> = incoming
}

internal class FakeChatGateway : ChatGateway {
    val systemTexts = mutableListOf<String>()
    val incoming = MutableSharedFlow<ChatMessage>(extraBufferCapacity = 8)
    var failSend = false
    override suspend fun send(room: WatchRoom, text: String, sender: User) =
        if (failSend) throw AppError.Network else ChatMessage(id = "c", roomId = room.id, senderId = sender.id, senderNickname = sender.nickname, text = text)
    override suspend fun sendSticker(room: WatchRoom, sticker: StickerRef, sender: User) =
        ChatMessage(id = "s", roomId = room.id, senderId = sender.id, senderNickname = sender.nickname, text = "", kind = ChatMessageKind.STICKER, sticker = sticker)
    override fun messages(room: WatchRoom): Flow<ChatMessage> = incoming
    override suspend fun postSystemMessage(room: WatchRoom, text: String): ChatMessage {
        systemTexts += text
        return ChatMessage(id = "sys", roomId = room.id, senderNickname = "System", text = text, kind = ChatMessageKind.SYSTEM)
    }
}

internal class FakeCatalog(private val movies: List<Movie>) : MovieCatalogGateway, MetadataGateway {
    override suspend fun listMovies(config: AppCloudConfig) = movies
    override suspend fun playUrl(movie: Movie, config: AppCloudConfig) = "https://cdn/${movie.objectKey}"
    override suspend fun enrich(movie: Movie, config: AppCloudConfig) = movie.copy(overview = "enriched")
}

internal class FakeSubtitles : SubtitleGateway, SharedSubtitleStorageGateway {
    override suspend fun listOSSSidecars(movie: Movie, config: AppCloudConfig) = emptyList<SubtitleTrack>()
    override suspend fun searchOnline(query: String, year: String?, apiKey: String?) = emptyList<SubtitleTrack>()
    override suspend fun download(track: SubtitleTrack, config: AppCloudConfig?) = "/tmp/${track.id}.srt"
    override suspend fun upload(filePath: String, roomId: String, movieId: String, config: AppCloudConfig) = "films/a.srt"
    override suspend fun download(objectKey: String, config: AppCloudConfig) = "/tmp/shared.srt"
}

internal class FakePlayer : PlayerPort {
    override var isPaused = true
    override var hasStartedPlayback = false
    override var currentPositionMs = 0L
    override var durationMs = 100_000L
    override var lastError: String? = null
    val seeks = mutableListOf<Long>()
    var prepared: String? = null

    override fun prepare(url: String, format: VideoFormat, completion: (String?) -> Unit) {
        prepared = url
        completion(null)
    }
    override fun play() { isPaused = false; hasStartedPlayback = true }
    override fun pause() { isPaused = true }
    override fun seek(positionMs: Long) { seeks += positionMs; currentPositionMs = positionMs }
    override fun stop() {}
    var inBackground = false
    override fun enterBackground() { inBackground = true }
    override fun enterForeground() { inBackground = false }
    override fun embeddedSubtitleTracks() = emptyList<SubtitleTrack>()
    override fun selectEmbeddedSubtitle(index: Int) {}
    override fun loadExternalSubtitle(filePath: String) = true
    override fun disableSubtitles() {}
    override fun applySubtitleOffsetMs(offsetMs: Int) {}
}
