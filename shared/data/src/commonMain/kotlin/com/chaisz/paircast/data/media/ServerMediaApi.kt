package com.chaisz.paircast.data.media

import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.MediaSource
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.RoomPlayback
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.VideoFormat
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.data.goim.GoImApi
import com.chaisz.paircast.data.goim.GoImAuthGateway
import com.chaisz.paircast.data.goim.GoImHttpException
import com.chaisz.paircast.data.secure.GoImSession
import io.ktor.client.HttpClient
import io.ktor.client.plugins.timeout
import io.ktor.client.request.forms.formData
import io.ktor.client.request.forms.submitFormWithBinaryData
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
internal data class MediaSourceDto(val id: String, val name: String = "", val type: String = "") {
    fun toDomain() = MediaSource(id = id, name = name.ifEmpty { id }, type = type)
}

@Serializable
internal data class MediaSourcesDto(
    val sources: List<MediaSourceDto> = emptyList(),
    @SerialName("online_subtitles") val onlineSubtitles: Boolean = false,
    val stickers: Boolean = false,
)

@Serializable
internal data class MediaItemDto(
    val id: String,
    @SerialName("source_id") val sourceId: String? = null,
    val title: String = "",
    val year: String? = null,
    val overview: String? = null,
    @SerialName("poster_url") val posterUrl: String? = null,
    @SerialName("backdrop_url") val backdropUrl: String? = null,
    val format: String? = null,
) {
    fun toDomain() = Movie(
        id = id,
        sourceId = sourceId,
        title = title.ifEmpty { id.substringAfterLast('/') },
        year = year?.ifEmpty { null },
        overview = overview?.ifEmpty { null },
        posterUrl = posterUrl?.ifEmpty { null },
        backdropUrl = backdropUrl?.ifEmpty { null },
        format = VideoFormat.entries.firstOrNull { it.rawValue == format } ?: VideoFormat.fromFilename(id) ?: VideoFormat.MP4,
    )
}

@Serializable
internal data class MediaPageDto(
    val items: List<MediaItemDto> = emptyList(),
    @SerialName("next_cursor") val nextCursor: String? = null,
)

@Serializable
internal data class PlayInfoDto(val url: String, @SerialName("expires_at") val expiresAt: Long = 0, val format: String? = null)

@Serializable
internal data class SubtitleRefDto(
    val ref: String,
    val label: String = "",
    val language: String? = null,
    val badge: String? = null,
    val format: String? = null,
    val origin: String? = null,
    val detail: String? = null,
)

@Serializable
internal data class SubtitleListDto(val subtitles: List<SubtitleRefDto> = emptyList())

@Serializable
internal data class RefDto(val ref: String)

@Serializable
internal data class RoomDto(
    val id: String,
    @SerialName("group_id") val groupId: String? = null,
    @SerialName("movie_id") val movieId: String,
    @SerialName("host_uid") val hostUid: String,
    val members: List<String> = emptyList(),
    @SerialName("join_order") val joinOrder: List<String> = emptyList(),
    val status: String = RoomStatus.ACTIVE.rawValue,
    @SerialName("last_applied_seq") val lastAppliedSeq: Long = 0,
    @SerialName("host_transfer_seq") val hostTransferSeq: Long = 0,
    @SerialName("subtitle_ref") val subtitleRef: String? = null,
    @SerialName("subtitle_label") val subtitleLabel: String? = null,
    val playback: PlaybackDto? = null,
    val revision: Long = 0,
    @SerialName("server_time") val serverTime: Long = 0,
) {
    fun toDomain() = WatchRoom(
        id = id,
        movieId = movieId,
        hostUserId = hostUid,
        memberIds = members,
        joinOrder = joinOrder.ifEmpty { members },
        status = RoomStatus.entries.firstOrNull { it.rawValue == status } ?: RoomStatus.ENDED,
        lastAppliedSeq = lastAppliedSeq,
        hostTransferSeq = hostTransferSeq,
        revision = revision,
        groupId = groupId?.ifEmpty { null },
        subtitleRef = subtitleRef?.ifEmpty { null },
        subtitleLabel = subtitleLabel?.ifEmpty { null },
        playback = playback?.toDomain(),
        serverTimeMs = serverTime,
    )
}

@Serializable
internal data class PlaybackDto(
    @SerialName("movie_id") val movieId: String,
    @SerialName("position_ms") val positionMs: Long = 0,
    val paused: Boolean = true,
    val rate: Double = 1.0,
    val seq: Long = 0,
    @SerialName("updated_at") val updatedAt: Long = 0,
) {
    fun toDomain() = RoomPlayback(movieId, positionMs, paused, rate, seq, updatedAt)
}

/** `data` of the `paircast.room_updated` signal pushed by the Paircast server. */
@Serializable
internal data class RoomUpdatedDto(@SerialName("group_id") val groupId: String? = null, val room: RoomDto? = null)

/**
 * Paircast media library (`/media/…`) and watch rooms (`/room/…`), authenticated with the Paircast
 * session token; the server holds every storage / TMDB / OpenSubtitles credential.
 */
class ServerMediaApi(
    private val client: HttpClient,
    private val api: GoImApi,
    private val auth: GoImAuthGateway,
) {
    internal suspend fun sources(): MediaSourcesDto = call { s -> api.decode(api.appGet(s, "media/sources"), MediaSourcesDto.serializer()) }

    /** All pages of a source (the server pages at 500). */
    internal suspend fun items(sourceId: String?, refresh: Boolean = false): List<MediaItemDto> = call { s ->
        val out = mutableListOf<MediaItemDto>()
        var cursor: String? = null
        repeat(MAX_PAGES) {
            val params = buildList {
                if (!sourceId.isNullOrEmpty()) add("source" to sourceId)
                if (!cursor.isNullOrEmpty()) add("cursor" to cursor!!)
                if (refresh) add("refresh" to "1")
            }
            val page = api.decode(api.appGet(s, "media/items", *params.toTypedArray()), MediaPageDto.serializer())
            out += page.items
            cursor = page.nextCursor?.ifEmpty { null } ?: return@call out
        }
        out
    }

    internal suspend fun item(id: String): MediaItemDto = call(AppError.PlaybackFailed) { s -> api.decode(api.appGet(s, "media/item", "id" to id), MediaItemDto.serializer()) }

    internal suspend fun play(id: String): PlayInfoDto = call(AppError.PlaybackFailed) { s -> api.decode(api.appGet(s, "media/play", "id" to id), PlayInfoDto.serializer()) }

    internal suspend fun subtitles(itemId: String, roomId: String? = null): List<SubtitleRefDto> = call { s ->
        val params = buildList {
            add("id" to itemId)
            if (!roomId.isNullOrEmpty()) add("room_id" to roomId)
        }
        api.decode(api.appGet(s, "media/subtitles", *params.toTypedArray()), SubtitleListDto.serializer()).subtitles
    }

    /** Raw subtitle bytes + extension (`srt` / `ass` / `vtt`). */
    internal suspend fun subtitle(ref: String): Pair<ByteArray, String> = call { s ->
        val response = api.appGet(s, "media/subtitle", "ref" to ref)
        response.bodyAsBytes() to (response.headers["X-Subtitle-Format"]?.ifEmpty { null } ?: "srt")
    }

    internal suspend fun searchSubtitles(query: String, year: String?): List<SubtitleRefDto> = call { s ->
        val params = buildList {
            add("q" to query)
            if (!year.isNullOrEmpty()) add("year" to year)
        }
        api.decode(api.appGet(s, "media/subtitles/search", *params.toTypedArray()), SubtitleListDto.serializer()).subtitles
    }

    /** Downloads an online result (`os:<id>`) into server storage; returns a readable ref. */
    internal suspend fun fetchSubtitle(onlineRef: String): String =
        call { s -> api.decode(api.appPost(s, "media/subtitles/fetch", "ref" to onlineRef), RefDto.serializer()).ref }

    internal suspend fun shareSubtitle(roomId: String, label: String?, fileName: String, bytes: ByteArray): String = call { s ->
        val response = api.send {
            client.submitFormWithBinaryData(
                url = GoImApi.url(s.serverUrl, "media/subtitles/share"),
                formData = formData {
                    append("uid", s.uid)
                    append("token", s.appToken)
                    append("room_id", roomId)
                    if (!label.isNullOrBlank()) append("label", label)
                    append(
                        "file",
                        bytes,
                        Headers.build {
                            append(HttpHeaders.ContentType, "text/plain")
                            append(HttpHeaders.ContentDisposition, "filename=\"${fileName.replace("\"", "")}\"")
                        },
                    )
                },
            ) { timeout { requestTimeoutMillis = 30_000 } }
        }
        api.decode(response, RefDto.serializer()).ref
    }

    internal suspend fun stickerCatalog(): String = call { s -> api.appGet(s, "media/stickers").bodyAsText() }

    internal suspend fun stickerPack(packId: String): String = call { s -> api.appGet(s, "media/stickers/pack", "id" to packId).bodyAsText() }

    internal suspend fun createRoom(movieId: String): RoomDto =
        call(AppError.RoomNotFound) { s -> api.decode(api.appPost(s, "room/create", "movie_id" to movieId), RoomDto.serializer()) }

    internal suspend fun joinRoom(roomId: String): RoomDto =
        call(AppError.RoomNotFound) { s -> api.decode(api.appPost(s, "room/join", "room_id" to roomId), RoomDto.serializer()) }

    internal suspend fun leaveRoom(roomId: String, transferSeq: Long): RoomDto = call(AppError.RoomNotFound) { s ->
        api.decode(api.appPost(s, "room/leave", "room_id" to roomId, "transfer_seq" to transferSeq.toString()), RoomDto.serializer())
    }

    internal suspend fun updateRoom(
        roomId: String,
        movieId: String?,
        hostUid: String?,
        hostTransferSeq: Long?,
        lastAppliedSeq: Long?,
        ended: Boolean,
    ): RoomDto = call(AppError.RoomNotFound) { s ->
        api.decode(
            api.appPost(
                s,
                "room/update",
                "room_id" to roomId,
                "movie_id" to movieId,
                "host_uid" to hostUid,
                "host_transfer_seq" to hostTransferSeq?.toString(),
                "last_applied_seq" to lastAppliedSeq?.toString(),
                "status" to if (ended) RoomStatus.ENDED.rawValue else null,
            ),
            RoomDto.serializer(),
        )
    }

    internal suspend fun reportPlayback(roomId: String, playback: RoomPlayback) {
        call(AppError.RoomNotFound) { s ->
            api.appPost(
                s,
                "room/playback",
                "room_id" to roomId,
                "movie_id" to playback.movieId,
                "position_ms" to playback.positionMs.coerceAtLeast(0).toString(),
                "paused" to playback.isPaused.toString(),
                "rate" to playback.rate.toString(),
                "seq" to playback.seq.toString(),
            )
        }
    }

    internal suspend fun room(roomId: String): RoomDto = call(AppError.RoomNotFound) { s -> api.decode(api.appGet(s, "room", "room_id" to roomId), RoomDto.serializer()) }

    private suspend fun <T> call(notFound: AppError = AppError.SubtitleUnavailable, block: suspend (GoImSession) -> T): T {
        val session = auth.session ?: throw AppError.SessionExpired
        return try {
            block(session)
        } catch (e: GoImHttpException) {
            throw mapError(e, notFound)
        }
    }

    companion object {
        private const val MAX_PAGES = 40

        internal fun mapError(e: GoImHttpException, notFound: AppError): AppError = when (e.status) {
            401 -> AppError.SessionExpired
            503 -> AppError.MediaLibraryUnavailable
            501 -> AppError.OnlineSubtitlesUnavailable
            404 -> notFound
            410 -> AppError.RoomEnded
            403 -> if ("host" in e.body) AppError.OnlyHostCanSwitchMovie else AppError.RoomNotFound
            502 -> AppError.Network
            else -> AppError.Unknown("Server error {{code}}", mapOf("code" to e.status.toString()))
        }
    }
}
