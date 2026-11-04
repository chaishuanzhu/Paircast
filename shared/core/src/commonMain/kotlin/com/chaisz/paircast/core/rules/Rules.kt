package com.chaisz.paircast.core.rules

import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ManagedUser
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackState
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.support.PaircastJson
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
    /** Member "refresh": how long to wait for the host's snapshot before giving up. */
    const val SYNC_REQUEST_TIMEOUT_MS: Long = 4_000
    /** Host answers at most one sync request per this window (requests are room-wide broadcasts). */
    const val SYNC_ANSWER_MIN_INTERVAL_MS: Long = 1_000

    enum class IgnoreReason { STALE_SEQ, NON_HOST, ROOM_ENDED, REQUEST }

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
        if (signal.action == PlaybackAction.SYNC_REQUEST) return ApplyResult.Ignored(IgnoreReason.REQUEST)

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
        val drift = abs(signal.positionMs - (localPositionMs ?: current.positionMs))
        return when (signal.action) {
            // Snapshots (newcomer / sync request) reach everyone: only seek when the state flips or
            // this member has actually drifted, so in-sync members don't stutter.
            PlaybackAction.PLAY -> ApplyResult.Applied(
                state.copy(positionMs = signal.positionMs, isPaused = false),
                seek = current.isPaused || drift > SYNC_THRESHOLD_MS,
            )
            PlaybackAction.PAUSE -> ApplyResult.Applied(
                state.copy(positionMs = signal.positionMs, isPaused = true),
                seek = !current.isPaused || drift > SYNC_THRESHOLD_MS,
            )
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
            PlaybackAction.SYNC_REQUEST -> ApplyResult.Ignored(IgnoreReason.REQUEST)
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

    @Throws(Exception::class)
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

    @Throws(Exception::class)
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
    const val PASSWORD_MAX_LENGTH = 72

    @Throws(Exception::class)
    fun validateAccount(account: String) {
        if (account.isBlank()) throw AppError.Validation("Please enter your account")
    }

    @Throws(Exception::class)
    fun validatePassword(password: String) {
        if (password.isEmpty()) throw AppError.Validation("Please enter your password")
    }

    @Throws(Exception::class)
    fun validateNewPassword(old: String, new: String, confirm: String) {
        validateChosenPassword(new, confirm)
        if (new == old) throw AppError.Validation("New password must differ from the current one")
    }

    @Throws(Exception::class)
    fun validateChosenPassword(password: String, confirm: String) {
        if (password.length < PASSWORD_MIN_LENGTH) {
            throw AppError.Validation(
                "Password must be at least {{count}} characters",
                mapOf("count" to "$PASSWORD_MIN_LENGTH"),
            )
        }
        if (password.length > PASSWORD_MAX_LENGTH) {
            throw AppError.Validation(
                "Password can be at most {{count}} characters",
                mapOf("count" to "$PASSWORD_MAX_LENGTH"),
            )
        }
        if (password != confirm) throw AppError.Validation("Passwords do not match")
    }
}

/** Terms of Service + Privacy Policy consent, required before signing in or signing up. */
object LegalRules {
    private const val SITE = "https://paircast.chaisz.com"

    fun termsUrl(chinese: Boolean): String = page("terms", chinese)
    fun privacyUrl(chinese: Boolean): String = page("privacy", chinese)

    @Throws(Exception::class)
    fun requireAgreement(agreed: Boolean) {
        if (!agreed) throw AppError.Validation("Please read and agree to the Terms of Service and Privacy Policy first")
    }

    private fun page(name: String, chinese: Boolean) = "$SITE/${if (chinese) "zh-Hans" else "en-US"}/$name/"
}

/** Admin "Add User" form: accounts are keyed by email; there is no self sign-up. */
object AccountRules {
    private val emailPattern = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")

    /** Trimmed, lower-cased email; throws when it doesn't look like an address. */
    @Throws(Exception::class)
    fun normalizedEmail(raw: String): String {
        val email = raw.trim().lowercase()
        if (email.isEmpty()) throw AppError.Validation("Please enter an email")
        if (email.length > 254 || !emailPattern.matches(email)) throw AppError.Validation("Please enter a valid email address")
        return email
    }

    /** Optional nickname: blank → null (the server derives one from the email). */
    @Throws(Exception::class)
    fun normalizedNickname(raw: String): String? =
        raw.trim().takeIf { it.isNotEmpty() }?.let(ProfileRules::validatedNickname)

    /** Admins may disable / delete regular users only — never themselves or another admin. */
    fun canManage(user: ManagedUser, currentUserId: String?): Boolean =
        !user.isAdmin && user.id != currentUserId
}
