package com.chaisz.paircast.core.model

import com.chaisz.paircast.core.support.Paths
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.roundToInt

data class User(
    /** GO-IM UID (server-assigned). */
    val id: String,
    val nickname: String,
    /** Public avatar URL (`{server}/avatar/{fileId}`), when set. */
    val avatarUrl: String? = null,
    val username: String? = null,
    val email: String? = null,
) {
    val displayName: String get() = nickname.ifBlank { id }
}

/** Result of `/login`. When [mustChangePassword] is true the UI must force a password change. */
data class LoginResult(val user: User, val mustChangePassword: Boolean)

enum class RoomStatus(val rawValue: String) {
    ACTIVE("active"),
    ENDED("ended"),
}

data class WatchRoom(
    val id: String,
    val movieId: String,
    val hostUserId: String,
    val memberIds: List<String> = listOf(hostUserId),
    val joinOrder: List<String> = listOf(hostUserId),
    val status: RoomStatus = RoomStatus.ACTIVE,
    val lastAppliedSeq: Long = 0,
    val hostTransferSeq: Long = 0,
    /** Monotonic object-storage revision used to reject stale reads after a write. */
    val revision: Long = 0,
    /** GO-IM group (`g_…`) carrying chat + playback signals for this room. */
    val groupId: String? = null,
)

enum class ChatMessageKind { USER, SYSTEM, STICKER }

data class ChatMessage(
    val id: String,
    val roomId: String,
    val senderId: String? = null,
    val senderNickname: String,
    val text: String,
    val kind: ChatMessageKind = ChatMessageKind.USER,
    val sticker: StickerRef? = null,
    val createdAtMs: Long = 0,
)

enum class VideoFormat(val rawValue: String) {
    MP4("mp4"),
    M4V("m4v"),
    MKV("mkv"),
    ;

    companion object {
        fun fromFilename(filename: String): VideoFormat? =
            when (Paths.pathExtension(filename).lowercase()) {
                "mp4" -> MP4
                "m4v" -> M4V
                "mkv" -> MKV
                else -> null
            }
    }
}

data class Movie(
    val id: String,
    val objectKey: String,
    val title: String,
    val year: String? = null,
    val overview: String? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val format: VideoFormat,
    val playUrl: String? = null,
)

@Serializable
enum class PlaybackAction {
    @SerialName("play") PLAY,
    @SerialName("pause") PAUSE,
    @SerialName("seek") SEEK,
    @SerialName("heartbeat") HEARTBEAT,
    @SerialName("movie_change") MOVIE_CHANGE,
    @SerialName("host_transfer") HOST_TRANSFER,

    /**
     * Host uploaded a subtitle to object storage; members should load `subtitleObjectKey`.
     * Empty / missing key means host turned shared subtitles off.
     */
    @SerialName("subtitle_change") SUBTITLE_CHANGE,
}

@Serializable
data class PlaybackSyncSignal(
    val action: PlaybackAction,
    val positionMs: Long,
    val movieId: String? = null,
    val hostUserId: String? = null,
    val senderId: String? = null,
    val clientTs: Long = 0,
    val playbackRate: Double = 1.0,
    val seq: Long,
    val subtitleObjectKey: String? = null,
    val subtitleLabel: String? = null,
)

data class PlaybackState(
    val positionMs: Long = 0,
    val isPaused: Boolean = true,
    val movieId: String,
    val lastSeq: Long = 0,
)

enum class SubtitleSource { EMBEDDED, OSS, ONLINE, OFF }

data class SubtitleTrack(
    val id: String,
    val label: String,
    val language: String? = null,
    val source: SubtitleSource,
    val url: String? = null,
    /** Player embedded track index when `source == EMBEDDED`. */
    val embeddedIndex: Int? = null,
    /** Secondary line in search results, e.g. "OpenSubtitles · Downloads 12.4k · SRT". */
    val detail: String? = null,
    /** Compact language badge, e.g. "ZH". */
    val languageBadge: String? = null,
    val format: String? = null,
) {
    val isChinesePreferred: Boolean
        get() {
            val lang = (language ?: "").lowercase()
            val labelLower = label.lowercase()
            val badge = (languageBadge ?: "").lowercase()
            if ("zh" in lang || "chi" in lang || "cn" in lang) return true
            if ("zh" in badge || "简" in badge || "繁" in badge || "中" in badge) return true
            return "简体" in labelLower || "中文" in labelLower || "chinese" in labelLower
        }

    companion object {
        val OFF = SubtitleTrack(id = "off", label = "Off", source = SubtitleSource.OFF)
    }
}

data class SubtitleState(
    val movieId: String,
    val source: SubtitleSource = SubtitleSource.OFF,
    val trackId: String? = null,
    val url: String? = null,
    val embeddedIndex: Int? = null,
    val offsetMs: Int = 0,
) {
    fun withOffsetDelta(deltaMs: Int): SubtitleState = copy(offsetMs = clamped(offsetMs + deltaMs))
    fun withResetOffset(): SubtitleState = copy(offsetMs = 0)

    val offsetLabel: String
        get() {
            val tenths = (offsetMs / 100.0).roundToInt()
            if (tenths == 0) return "+0.0s"
            val sign = if (tenths > 0) "+" else "-"
            val a = abs(tenths)
            return "$sign${a / 10}.${a % 10}s"
        }

    companion object {
        const val MAX_OFFSET_MS = 30_000
        const val MIN_OFFSET_MS = -30_000

        fun clamped(value: Int): Int = value.coerceIn(MIN_OFFSET_MS, MAX_OFFSET_MS)

        fun create(movieId: String, offsetMs: Int = 0): SubtitleState =
            SubtitleState(movieId = movieId, offsetMs = clamped(offsetMs))

        fun resetForMovieChange(movieId: String): SubtitleState = SubtitleState(movieId = movieId)
    }
}
