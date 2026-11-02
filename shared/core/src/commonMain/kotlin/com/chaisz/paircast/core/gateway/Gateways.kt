package com.chaisz.paircast.core.gateway

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.LoginResult
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
    /** Best-effort wipe of nickname/avatar on the server, then logout and local cleanup. */
    @Throws(Exception::class)
    suspend fun deleteAccount()
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

/** Encrypted share link codec (`paircast://config?args=`). Lives in data (AES-GCM). */
interface ConfigLinkCodec {
    @Throws(Exception::class)
    fun shareUrl(config: AppCloudConfig): String
    /** Accepts a full share URL, raw `args`, or plaintext JSON. */
    @Throws(Exception::class)
    fun decode(input: String): AppCloudConfig
}

interface MovieCatalogGateway {
    @Throws(Exception::class)
    suspend fun listMovies(config: AppCloudConfig): List<Movie>
    /** AWS SigV4 query-presigned HTTPS URL for online playback (default 6h). */
    @Throws(Exception::class)
    suspend fun playUrl(movie: Movie, config: AppCloudConfig): String
}

interface MetadataGateway {
    @Throws(Exception::class)
    suspend fun enrich(movie: Movie, config: AppCloudConfig): Movie
}

/** Reads/writes Kodi-style NFO + poster/fanart sidecars beside the movie in object storage. */
interface MovieMetadataStorageGateway {
    @Throws(Exception::class)
    suspend fun load(movie: Movie, config: AppCloudConfig): Movie?
    @Throws(Exception::class)
    suspend fun save(movie: Movie, config: AppCloudConfig): Movie
}

interface RoomGateway {
    @Throws(Exception::class)
    suspend fun createRoom(movieId: String, hostUserId: String): WatchRoom
    /** [movieId]/[hostUserId]: optional invite bootstrap when the room record is not found yet. */
    @Throws(Exception::class)
    suspend fun joinRoom(roomId: String, userId: String, movieId: String?, hostUserId: String?): WatchRoom
    @Throws(Exception::class)
    suspend fun leaveRoom(room: WatchRoom, userId: String): WatchRoom?
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

/** Loads sticker packs from the user's object storage `stickers/` folder. */
interface StickerCatalogGateway {
    @Throws(Exception::class)
    suspend fun loadCatalog(config: AppCloudConfig): List<StickerPackSummary>
    @Throws(Exception::class)
    suspend fun loadPack(packId: String, config: AppCloudConfig): StickerPack
    @Throws(Exception::class)
    suspend fun imageData(packId: String, fileName: String, config: AppCloudConfig): ByteArray
    @Throws(Exception::class)
    suspend fun imageDataForRef(ref: StickerRef, config: AppCloudConfig): ByteArray
    /** SigV4 presigned GET URL for a sticker asset (stable cache key = `ref.bindKey`). */
    @Throws(Exception::class)
    suspend fun imageUrl(ref: StickerRef, config: AppCloudConfig): String
}

interface SubtitleGateway {
    @Throws(Exception::class)
    suspend fun listOSSSidecars(movie: Movie, config: AppCloudConfig): List<SubtitleTrack>
    @Throws(Exception::class)
    suspend fun searchOnline(query: String, year: String?, apiKey: String?): List<SubtitleTrack>
    /** Downloads a track to a local file (UTF-8 normalized); returns its absolute path. */
    @Throws(Exception::class)
    suspend fun download(track: SubtitleTrack, config: AppCloudConfig?): String
}

/** Host uploads a downloaded subtitle beside the movie object; members pull via SigV4 GET. */
interface SharedSubtitleStorageGateway {
    /** Uploads local subtitle bytes next to the movie (`{movieBase}.{ext}`); returns object key. */
    @Throws(Exception::class)
    suspend fun upload(filePath: String, roomId: String, movieId: String, config: AppCloudConfig): String
    /** Downloads a shared / sidecar subtitle to a local file (UTF-8 normalized); returns its path. */
    @Throws(Exception::class)
    suspend fun download(objectKey: String, config: AppCloudConfig): String
}
