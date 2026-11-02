package com.chaisz.paircast.core.rules

import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackState
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.support.PaircastJson
import com.chaisz.paircast.core.support.Paths
import kotlin.math.abs

/** Named placeholders in localization templates, e.g. `"Host is now {{name}}"`. */
object StringTemplate {
    fun apply(template: String, args: Map<String, String>): String {
        if (args.isEmpty()) return template
        var result = template
        for ((key, value) in args) result = result.replace("{{$key}}", value)
        return result
    }
}

object PlaybackSyncRules {
    const val SYNC_THRESHOLD_MS: Long = 1_200
    const val FOREGROUND_HEARTBEAT_MS: Long = 5_000
    const val BACKGROUND_HEARTBEAT_MS: Long = 15_000
    const val HOST_DISCONNECT_TIMEOUT_MS: Long = 45_000

    enum class IgnoreReason { STALE_SEQ, NON_HOST, ROOM_ENDED }

    sealed class ApplyResult {
        /** [seek]: whether the player should seek to `state.positionMs`. */
        data class Applied(val state: PlaybackState, val seek: Boolean) : ApplyResult()
        data class Ignored(val reason: IgnoreReason) : ApplyResult()
    }

    /**
     * [localPositionMs]: live player clock for heartbeat drift checks. When omitted, falls back to
     * `current.positionMs` (tests / bookkeeping only).
     */
    fun shouldAccept(
        signal: PlaybackSyncSignal,
        room: WatchRoom,
        current: PlaybackState,
        localPositionMs: Long? = null,
    ): ApplyResult {
        if (room.status != RoomStatus.ACTIVE) return ApplyResult.Ignored(IgnoreReason.ROOM_ENDED)

        if (signal.action == PlaybackAction.HOST_TRANSFER) {
            val newHost = signal.hostUserId
            if (newHost.isNullOrEmpty()) return ApplyResult.Ignored(IgnoreReason.NON_HOST)
            if (signal.seq <= room.hostTransferSeq) return ApplyResult.Ignored(IgnoreReason.STALE_SEQ)
            return ApplyResult.Applied(
                current.copy(
                    positionMs = signal.positionMs,
                    isPaused = true,
                    movieId = signal.movieId ?: current.movieId,
                    lastSeq = maxOf(current.lastSeq, signal.seq),
                ),
                seek = true,
            )
        }

        if (signal.seq <= current.lastSeq) return ApplyResult.Ignored(IgnoreReason.STALE_SEQ)
        if ((signal.senderId ?: "") != room.hostUserId) return ApplyResult.Ignored(IgnoreReason.NON_HOST)

        val state = current.copy(lastSeq = signal.seq)
        return when (signal.action) {
            PlaybackAction.PLAY -> ApplyResult.Applied(state.copy(positionMs = signal.positionMs, isPaused = false), true)
            PlaybackAction.PAUSE -> ApplyResult.Applied(state.copy(positionMs = signal.positionMs, isPaused = true), true)
            PlaybackAction.SEEK -> ApplyResult.Applied(state.copy(positionMs = signal.positionMs), true)
            PlaybackAction.HEARTBEAT -> {
                // Compare against the *live* player clock. Using frozen `current.positionMs` makes
                // drift exceed the threshold every ~1.2s of playback and forces a seek on every
                // heartbeat → stutter + repeated stream fetches.
                val baseline = localPositionMs ?: current.positionMs
                val delta = abs(signal.positionMs - baseline)
                ApplyResult.Applied(
                    state.copy(positionMs = signal.positionMs, isPaused = false),
                    seek = delta > SYNC_THRESHOLD_MS,
                )
            }
            PlaybackAction.MOVIE_CHANGE -> ApplyResult.Applied(
                state.copy(movieId = signal.movieId ?: state.movieId, positionMs = 0, isPaused = true),
                seek = true,
            )
            // Subtitle share does not move the playhead or pause state.
            PlaybackAction.SUBTITLE_CHANGE -> ApplyResult.Applied(state, seek = false)
            PlaybackAction.HOST_TRANSFER -> ApplyResult.Applied(state, seek = false)
        }
    }

    fun needsSmoothCorrection(localMs: Long, hostMs: Long): Boolean = abs(localMs - hostMs) > SYNC_THRESHOLD_MS
}

object HostTransferRules {
    sealed class Outcome {
        data class MemberLeft(val room: WatchRoom) : Outcome()
        data class Transfer(val newHostUserId: String, val room: WatchRoom) : Outcome()
        data class EndRoom(val room: WatchRoom) : Outcome()
        data object Unchanged : Outcome()
    }

    /** Selects next host by join order after current host leaves. */
    fun resolveLeave(room: WatchRoom, leavingUserId: String, transferSeq: Long): Outcome {
        if (room.status != RoomStatus.ACTIVE) return Outcome.Unchanged

        val remaining = room.copy(
            memberIds = room.memberIds.filter { it != leavingUserId },
            joinOrder = room.joinOrder.filter { it != leavingUserId },
        )
        if (remaining.memberIds.isEmpty()) return Outcome.EndRoom(remaining.copy(status = RoomStatus.ENDED))
        if (leavingUserId != room.hostUserId) return Outcome.MemberLeft(remaining)

        val nextHost = remaining.joinOrder.firstOrNull() ?: remaining.memberIds.first()
        return Outcome.Transfer(
            newHostUserId = nextHost,
            room = remaining.copy(hostUserId = nextHost, hostTransferSeq = transferSeq),
        )
    }
}

object MovieCatalogRules {
    val allowedExtensions = setOf("mp4", "m4v", "mkv")

    private val dotted = Regex("^(.+?)\\.(\\d{4})(?:\\.|$)")
    private val paren = Regex("^(.+?)\\s*[(（](\\d{4})[)）]\\s*$")

    fun isVideoObjectKey(key: String): Boolean = Paths.pathExtension(key).lowercase() in allowedExtensions

    fun filterVideoKeys(keys: List<String>): List<String> = keys.filter(::isVideoObjectKey)

    data class FilenameMetadata(val title: String, val year: String?)

    fun parseFilenameMetadata(objectKey: String): FilenameMetadata {
        val base = Paths.deletingPathExtension(Paths.lastPathComponent(objectKey))

        // `Title.2010.1080p` style
        dotted.find(base)?.let { m ->
            return FilenameMetadata(m.groupValues[1].replace(".", " ").trim(), m.groupValues[2])
        }
        // `Title (2023)` / `Title（2023）` style (common for Chinese filenames)
        paren.find(base)?.let { m ->
            return FilenameMetadata(m.groupValues[1].trim(), m.groupValues[2])
        }
        return FilenameMetadata(base.replace(".", " ").trim(), null)
    }
}

/** Sticker chat messages carry JSON [StickerRef] (`msg_type` sticker) — legacy `[stk]` prefix still decodes. */
object ChatStickerCodec {
    const val PREFIX = "[stk]"
    const val FALLBACK_TEXT = "[Sticker]"

    fun encodeJson(ref: StickerRef): String = PaircastJson.default.encodeToString(StickerRef.serializer(), ref)

    fun encode(ref: StickerRef): String = PREFIX + encodeJson(ref)

    fun decode(text: String): StickerRef? {
        val json = if (text.startsWith(PREFIX)) text.removePrefix(PREFIX) else text
        return runCatching { PaircastJson.default.decodeFromString(StickerRef.serializer(), json) }.getOrNull()
    }

    fun isStickerPayload(text: String): Boolean = text.startsWith(PREFIX)
}

object ProfileRules {
    const val NICKNAME_MAX_LENGTH = 16
    const val AVATAR_MAX_BYTES = 1_048_576

    fun validatedNickname(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) throw AppError.Validation("Nickname cannot be empty")
        if (trimmed.codePointLength() > NICKNAME_MAX_LENGTH) {
            throw AppError.Validation(
                "Nickname can be at most {{count}} characters",
                mapOf("count" to "$NICKNAME_MAX_LENGTH"),
            )
        }
        return trimmed
    }

    fun validatedAvatarData(data: ByteArray): ByteArray {
        if (data.isEmpty()) throw AppError.Validation("Please choose a profile photo")
        if (data.size > AVATAR_MAX_BYTES) throw AppError.Validation("Avatar must be under 1 MB after compression")
        return data
    }

    private fun String.codePointLength(): Int {
        var count = 0
        var i = 0
        while (i < length) {
            i += if (this[i].isHighSurrogate() && i + 1 < length && this[i + 1].isLowSurrogate()) 2 else 1
            count++
        }
        return count
    }
}

object LoginRules {
    const val PASSWORD_MIN_LENGTH = 6

    fun validateAccount(account: String) {
        if (account.isBlank()) throw AppError.Validation("Please enter your account")
    }

    fun validatePassword(password: String) {
        if (password.isEmpty()) throw AppError.Validation("Please enter your password")
    }

    fun validateNewPassword(old: String, new: String, confirm: String) {
        if (new.length < PASSWORD_MIN_LENGTH) {
            throw AppError.Validation(
                "Password must be at least {{count}} characters",
                mapOf("count" to "$PASSWORD_MIN_LENGTH"),
            )
        }
        if (new != confirm) throw AppError.Validation("Passwords do not match")
        if (new == old) throw AppError.Validation("New password must differ from the current one")
    }
}
