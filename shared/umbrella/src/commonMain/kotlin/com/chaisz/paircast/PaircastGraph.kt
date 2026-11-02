package com.chaisz.paircast

import com.chaisz.paircast.core.gateway.AuthGateway
import com.chaisz.paircast.core.gateway.ChatGateway
import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.gateway.ConfigLinkCodec
import com.chaisz.paircast.core.gateway.MetadataGateway
import com.chaisz.paircast.core.gateway.MovieCatalogGateway
import com.chaisz.paircast.core.gateway.PlaybackSyncGateway
import com.chaisz.paircast.core.gateway.RoomGateway
import com.chaisz.paircast.core.gateway.SharedSubtitleStorageGateway
import com.chaisz.paircast.core.gateway.StickerCatalogGateway
import com.chaisz.paircast.core.gateway.SubtitleGateway
import com.chaisz.paircast.core.session.PlayerPort
import com.chaisz.paircast.core.session.WatchDependencies
import com.chaisz.paircast.core.session.WatchSession
import com.chaisz.paircast.core.store.ChatSafetyStore
import com.chaisz.paircast.core.store.KeyValueStore
import com.chaisz.paircast.core.store.SecureStore
import com.chaisz.paircast.core.store.SubtitleOffsetStore
import com.chaisz.paircast.core.usecase.ChangePasswordUseCase
import com.chaisz.paircast.core.usecase.ExportConfigUseCase
import com.chaisz.paircast.core.usecase.ImportConfigUseCase
import com.chaisz.paircast.core.usecase.ListMoviesUseCase
import com.chaisz.paircast.core.usecase.LoginUseCase
import com.chaisz.paircast.core.usecase.SaveCloudConfigUseCase
import com.chaisz.paircast.core.usecase.UpdateProfileUseCase
import com.chaisz.paircast.data.catalog.OssMovieCatalogGateway
import com.chaisz.paircast.data.config.ConfigShareLink
import com.chaisz.paircast.data.files.FileStore
import com.chaisz.paircast.data.goim.GoImApi
import com.chaisz.paircast.data.goim.GoImAuthGateway
import com.chaisz.paircast.data.goim.GoImChatGateway
import com.chaisz.paircast.data.goim.GoImConnection
import com.chaisz.paircast.data.goim.GoImPlaybackSyncGateway
import com.chaisz.paircast.data.goim.GoImRoomGateway
import com.chaisz.paircast.data.metadata.CascadingMetadataGateway
import com.chaisz.paircast.data.metadata.MetadataCache
import com.chaisz.paircast.data.metadata.OssMovieMetadataStorage
import com.chaisz.paircast.data.net.createHttpClient
import com.chaisz.paircast.data.net.platformName
import com.chaisz.paircast.data.rooms.OssRoomStore
import com.chaisz.paircast.data.s3.S3Client
import com.chaisz.paircast.data.secure.SecureConfigStore
import com.chaisz.paircast.data.secure.SessionStore
import com.chaisz.paircast.data.stickers.StickerCatalogStore
import com.chaisz.paircast.data.subtitles.OpenSubtitlesGateway
import com.chaisz.paircast.data.subtitles.OssSharedSubtitleStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlin.uuid.Uuid

/**
 * App-wide dependency graph shared by iOS (SwiftUI) and Android (Compose). Platforms supply
 * secret storage, plain preferences and writable directories; everything else lives here.
 */
class PaircastGraph(
    secureStore: SecureStore,
    keyValueStore: KeyValueStore,
    cacheDirectory: String,
    supportDirectory: String,
    preferredLanguage: String,
    appVersion: String,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val http = createHttpClient()
    private val s3 = S3Client(http)
    private val cache = FileStore(cacheDirectory)
    private val support = FileStore(supportDirectory)
    private val sessions = SessionStore(secureStore)
    private val api = GoImApi(http)
    private val connection = GoImConnection(
        client = http,
        api = api,
        scope = scope,
        deviceId = sessions.deviceId { Uuid.random().toString() },
        platform = platformName,
    )
    private val metadataCache = MetadataCache()
    private val goImAuth: GoImAuthGateway

    val configGateway: ConfigGateway = SecureConfigStore(secureStore)
    val configLinkCodec: ConfigLinkCodec = ConfigShareLink
    val authGateway: AuthGateway
    val roomGateway: RoomGateway
    val chatGateway: ChatGateway
    val syncGateway: PlaybackSyncGateway
    val catalogGateway: MovieCatalogGateway = OssMovieCatalogGateway(s3)
    val metadataGateway: MetadataGateway = CascadingMetadataGateway(
        http = http,
        storage = OssMovieMetadataStorage(http, s3),
        cache = metadataCache,
        tmdbLanguage = { CascadingMetadataGateway.tmdbLanguageFor(preferredLanguage) },
    )
    val subtitleGateway: SubtitleGateway = OpenSubtitlesGateway(http, s3, cache, userAgent = "Paircast $platformName v$appVersion")
    val sharedSubtitleStorage: SharedSubtitleStorageGateway = OssSharedSubtitleStorage(s3, cache)
    val stickerCatalog: StickerCatalogGateway = StickerCatalogStore(s3, support)
    val subtitleOffsets = SubtitleOffsetStore(keyValueStore)
    val chatSafety = ChatSafetyStore(keyValueStore)

    init {
        goImAuth = GoImAuthGateway(configGateway, sessions, api, connection)
        authGateway = goImAuth
        roomGateway = GoImRoomGateway(OssRoomStore(configGateway, s3, scope), api, goImAuth)
        chatGateway = GoImChatGateway(connection, goImAuth)
        syncGateway = GoImPlaybackSyncGateway(connection)
    }

    val login get() = LoginUseCase(configGateway, authGateway)
    val changePassword get() = ChangePasswordUseCase(authGateway)
    val updateProfile get() = UpdateProfileUseCase(authGateway)
    val saveConfig get() = SaveCloudConfigUseCase(configGateway)
    val importConfig get() = ImportConfigUseCase(configGateway, configLinkCodec)
    val exportConfig get() = ExportConfigUseCase(configGateway, configLinkCodec)
    val listMovies get() = ListMoviesUseCase(configGateway, catalogGateway, metadataGateway)

    val watchDependencies: WatchDependencies
        get() = WatchDependencies(
            authGateway = authGateway,
            configGateway = configGateway,
            roomGateway = roomGateway,
            chatGateway = chatGateway,
            syncGateway = syncGateway,
            catalogGateway = catalogGateway,
            metadataGateway = metadataGateway,
            subtitleGateway = subtitleGateway,
            sharedSubtitleStorage = sharedSubtitleStorage,
            subtitleOffsets = subtitleOffsets,
            chatSafety = chatSafety,
        )

    /** Starts a watch screen session; call [WatchSession.start] / [WatchSession.close] from the UI. */
    fun watchSession(player: PlayerPort, roomId: String?, movieId: String?, hostUserId: String?): WatchSession =
        WatchSession(watchDependencies, player, roomId, movieId, hostUserId)

    /** Call when the app returns to the foreground: re-verifies the GO-IM link right away. */
    fun onAppForeground() = connection.probe()

    /** Drops cached scrape results (e.g. after the storage config changes). */
    suspend fun clearMetadataCache() = metadataCache.clear()

    /** Removes downloaded subtitles and cached sticker images. */
    fun clearLocalCaches() {
        runCatching { cache.deleteAll() }
        runCatching { support.deleteAll() }
    }

    fun close() {
        scope.cancel()
        http.close()
    }
}
