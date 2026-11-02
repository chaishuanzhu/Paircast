package com.chaisz.paircast.core.store

import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.SubtitleState
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlin.time.Clock

/**
 * Plain (non-secret) key/value persistence: `UserDefaults` on iOS, `SharedPreferences` on Android.
 * Secrets (config, token) go through `SecureStore` in the data module instead.
 */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String)
    fun remove(key: String)
}

class InMemoryKeyValueStore : KeyValueStore {
    private val map = mutableMapOf<String, String>()
    override fun getString(key: String): String? = map[key]
    override fun putString(key: String, value: String) { map[key] = value }
    override fun remove(key: String) { map.remove(key) }
}

/**
 * Secret persistence implemented per platform: iOS Keychain (Swift), Android
 * EncryptedSharedPreferences. Values are opaque strings (JSON blobs).
 */
interface SecureStore {
    fun read(key: String): String?
    fun write(key: String, value: String)
    fun delete(key: String)
}

class InMemorySecureStore : SecureStore {
    private val map = mutableMapOf<String, String>()
    override fun read(key: String): String? = map[key]
    override fun write(key: String, value: String) { map[key] = value }
    override fun delete(key: String) { map.remove(key) }
}

/** Local persistence for per-movie subtitle offset (device-only). */
class SubtitleOffsetStore(private val store: KeyValueStore) {
    fun load(movieId: String): Int = store.getString(PREFIX + movieId)?.toIntOrNull() ?: 0

    fun save(movieId: String, offsetMs: Int) {
        store.putString(PREFIX + movieId, SubtitleState.clamped(offsetMs).toString())
    }

    fun clear(movieId: String) = store.remove(PREFIX + movieId)

    private companion object {
        const val PREFIX = "tandem.subtitle.offset."
    }
}

/** Local block list and report log for invite-only room chat (App Store Guideline 1.2). */
class ChatSafetyStore(private val store: KeyValueStore) {
    fun blockedUserIds(ownerId: String): Set<String> = readList(blockKey(ownerId)).toSet()

    fun isBlocked(userId: String, ownerId: String): Boolean = userId in blockedUserIds(ownerId)

    fun block(userId: String, ownerId: String) {
        val trimmed = userId.trim()
        if (trimmed.isEmpty() || trimmed == ownerId) return
        writeList(blockKey(ownerId), (blockedUserIds(ownerId) + trimmed).sorted())
    }

    fun recordReport(targetUserId: String, ownerId: String, snippet: String) {
        val now = Clock.System.now().toLocalDateTime(TimeZone.UTC)
        val line = "${now}Z|$ownerId|$targetUserId|${snippet.take(80)}"
        writeList(REPORTS_KEY, (readList(REPORTS_KEY) + line).takeLast(50))
    }

    fun clear(ownerId: String) = store.remove(blockKey(ownerId))

    fun visibleMessages(messages: List<ChatMessage>, ownerId: String): List<ChatMessage> {
        val blocked = blockedUserIds(ownerId)
        return messages.filter { m ->
            m.kind == ChatMessageKind.SYSTEM || m.senderId == null || m.senderId !in blocked
        }
    }

    private fun blockKey(ownerId: String) = BLOCK_PREFIX + ownerId

    private fun readList(key: String): List<String> =
        store.getString(key)?.split(SEPARATOR)?.filter { it.isNotEmpty() } ?: emptyList()

    private fun writeList(key: String, values: List<String>) {
        store.putString(key, values.joinToString(SEPARATOR))
    }

    companion object {
        private const val BLOCK_PREFIX = "paircast.chat.blocked."
        private const val REPORTS_KEY = "paircast.chat.reports"
        private const val SEPARATOR = "\u001E"

        const val REPORT_URL =
            "https://github.com/chaishuanzhu/Paircast/issues/new?title=Chat%20content%20report&body=" +
                "Please%20describe%20the%20violation%20(rooms%20are%20invite-only%3B%20we%20only%20handle%20rooms%20you%20joined)."
    }
}
