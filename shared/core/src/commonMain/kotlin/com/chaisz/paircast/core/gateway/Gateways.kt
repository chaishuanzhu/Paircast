package com.chaisz.paircast.core.gateway

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AuthOptions
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.LoginResult
import com.chaisz.paircast.core.model.MediaSource
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.StickerPack
import com.chaisz.paircast.core.model.StickerPackSummary
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.model.WatchRoom
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** Session-level events that force the UI back to login. */
sealed class SessionEvent {
    data object KickedOffline : SessionEvent()
    data object TokenExpired : SessionEvent()
}

enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING }

/** GO-IM account session: password login, token persistence, profile, realtime link. */
interface AuthGateway {
    val currentUser: StateFlow<User?>
    val connection: StateFlow<ConnectionState>
    val events: Flow<SessionEvent>

    @Throws(Exception::class)
    suspend fun login(account: String, password: String): LoginResult
    /** Restores the persisted token (validated against the server) and reconnects. */
    @Throws(Exception::class)
    suspend fun restoreSession(): User?
    @Throws(Exception::class)
    suspend fun changePassword(oldPassword: String, newPassword: String)
    @Throws(Exception::class)
    suspend fun logout()
    @Throws(Exception::class)
    suspend fun updateProfile(nickname: String, avatarJpeg: ByteArray?): User
    @Throws(Exception::class)
    suspend fun fetchProfile(): User
    /** Batch profile lookup (nickname + avatar URL). Preserves request order. */
    @Throws(Exception::class)
    suspend fun fetchUsers(userIds: List<String>): List<User>
    /** Server sign-up options; [AuthOptions.Unavailable] when unconfigured or unreachable. */
    @Throws(Exception::class)
    suspend fun authOptions(): AuthOptions
    /** Mails a sign-up code to [email]; returns the seconds before another code may be requested. */
    @Throws(Exception::class)
    suspend fun sendRegisterCode(email: String): Int
    /** Creates the account and signs in (same session handling as [login]). */
    @Throws(Exception::class)
    suspend fun register(email: String, code: String, password: String, nickname: String?): LoginResult
    /** Deletes the account on the server (password re-check), then logout and local cleanup. */
    @Throws(Exception::class)
    suspend fun deleteAccount(password: String)
}

interface ConfigGateway {
    @Throws(Exception::class)
    suspend fun load(): AppCloudConfig?
    @Throws(Exception::class)
    suspend fun save(config: AppCloudConfig)
    /** Deletes cloud config and any persisted session. */
    @Throws(Exception::class)
    suspend fun clearAll()
}

/** Server media library (`/media/…`). Video sources and their keys live on the server. */
interface MovieCatalogGateway {
    /** Configured video sources (id + display name); empty when the server has no library. */
    @Throws(Exception::class)
    suspend fun listSources(config: AppCloudConfig): List<MediaSource>
    /** Movies of [sourceId] (server default when null), with cached metadata merged in. */
    @Throws(Exception::class)
    suspend fun listMovies(config: AppCloudConfig, sourceId: String? = null): List<Movie>
    /** Short-lived direct play URL issued by the server (S3 sources: presigned, default 6h). */
    @Throws(Exception::class)
    suspend fun playUrl(movie: Movie, config: AppCloudConfig): String
}

/** Server-side scraping (NFO / poster sidecars / TMDB), cached on the server. */
interface MetadataGateway {
    @Throws(Exception::class)
    suspend fun enrich(movie: Movie, config: AppCloudConfig): Movie
}

/** Watch rooms (`/room/…`); the server owns membership, host transfer and revisions. */
interface RoomGateway {
    @Throws(Exception::class)
    suspend fun createRoom(movieId: String, hostUserId: String): WatchRoom
    /** [movieId]/[hostUserId] come from the invite link and are only used for error context. */
    @Throws(Exception::class)
    suspend fun joinRoom(roomId: String, userId: String, movieId: String?, hostUserId: String?): WatchRoom
    /** Server transfers host by join order and ends the room when the last member leaves. */
    @Throws(Exception::class)
    suspend fun leaveRoom(room: WatchRoom, userId: String, transferSeq: Long): WatchRoom?
    /** Sends movie / host / status / seq changes; host-only fields are enforced by the server. */
    @Throws(Exception::class)
    suspend fun updateRoom(room: WatchRoom)
    fun observeRoom(roomId: String): Flow<WatchRoom>
}

interface ChatGateway {
    @Throws(Exception::class)
    suspend fun send(room: WatchRoom, text: String, sender: User): ChatMessage
    @Throws(Exception::class)
    suspend fun sendSticker(room: WatchRoom, sticker: StickerRef, sender: User): ChatMessage
    fun messages(room: WatchRoom): Flow<ChatMessage>
    @Throws(Exception::class)
    suspend fun postSystemMessage(room: WatchRoom, text: String): ChatMessage
}

interface PlaybackSyncGateway {
    @Throws(Exception::class)
    suspend fun send(room: WatchRoom, signal: PlaybackSyncSignal)
    fun signals(room: WatchRoom): Flow<PlaybackSyncSignal>
}

/** Sticker packs served by the media library (`/media/stickers…`). */
interface StickerCatalogGateway {
    @Throws(Exception::class)
    suspend fun loadCatalog(config: AppCloudConfig): List<StickerPackSummary>
    @Throws(Exception::class)
    suspend fun loadPack(packId: String, config: AppCloudConfig): StickerPack
    @Throws(Exception::class)
    suspend fun imageData(packId: String, fileName: String, config: AppCloudConfig): ByteArray
    @Throws(Exception::class)
    suspend fun imageDataForRef(ref: StickerRef, config: AppCloudConfig): ByteArray
    /** Server-signed GET URL for a sticker asset (stable cache key = `ref.bindKey`). */
    @Throws(Exception::class)
    suspend fun imageUrl(ref: StickerRef, config: AppCloudConfig): String
}

interface SubtitleGateway {
    /** Sidecar subtitles next to the movie in its video source. */
    @Throws(Exception::class)
    suspend fun listSidecars(movie: Movie, config: AppCloudConfig): List<SubtitleTrack>
    /** Online search through the server (OpenSubtitles key stays server-side). */
    @Throws(Exception::class)
    suspend fun searchOnline(query: String, year: String?): List<SubtitleTrack>
    /** Downloads a track to a local file (UTF-8 normalized); returns its absolute path. */
    @Throws(Exception::class)
    suspend fun download(track: SubtitleTrack, config: AppCloudConfig?): String
}

/** Host shares a subtitle through the server; members load it by ref. */
interface SharedSubtitleStorageGateway {
    /** Uploads local subtitle bytes for [roomId] (host only); returns the server subtitle ref. */
    @Throws(Exception::class)
    suspend fun upload(filePath: String, roomId: String, label: String?, config: AppCloudConfig): String
    /** Downloads a server subtitle ref to a local file (UTF-8 normalized); returns its path. */
    @Throws(Exception::class)
    suspend fun download(ref: String, config: AppCloudConfig): String
}
