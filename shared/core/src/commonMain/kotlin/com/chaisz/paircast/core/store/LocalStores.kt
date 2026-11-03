package com.chaisz.paircast.core.store

import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.SubtitleState

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

/**
 * Device copy of the server block list (App Store Guideline 1.2), so blocked senders stay hidden offline.
 * Blocks that have not reached the server yet are kept as pending uploads.
 */
class ChatSafetyStore(private val store: KeyValueStore) {
    fun blockedUserIds(ownerId: String): Set<String> = readList(blockKey(ownerId)).toSet()

    fun isBlocked(userId: String, ownerId: String): Boolean = userId in blockedUserIds(ownerId)

    /** Adds [userId] locally and queues it for upload; false when invalid or already blocked. */
    fun block(userId: String, ownerId: String): Boolean {
        val trimmed = userId.trim()
        if (trimmed.isEmpty() || trimmed == ownerId || isBlocked(trimmed, ownerId)) return false
        writeList(blockKey(ownerId), (blockedUserIds(ownerId) + trimmed).sorted())
        writeList(pendingKey(ownerId), (readList(pendingKey(ownerId)) + trimmed).distinct())
        return true
    }

    fun markUploaded(userId: String, ownerId: String) {
        writeList(pendingKey(ownerId), readList(pendingKey(ownerId)) - userId)
    }

    /** Blocks the server doesn't know about; before the first sync that is every local block. */
    fun pendingUploads(ownerId: String): Set<String> {
        val pending = readList(pendingKey(ownerId)).toSet()
        return if (store.getString(syncedKey(ownerId)) == null) pending + blockedUserIds(ownerId) else pending
    }

    fun applyServerList(ownerId: String, remote: Set<String>, stillPending: Set<String>) {
        writeList(blockKey(ownerId), (remote + stillPending - ownerId).sorted())
        writeList(pendingKey(ownerId), stillPending.toList())
        store.putString(syncedKey(ownerId), "1")
    }

    fun clear(ownerId: String) {
        store.remove(blockKey(ownerId))
        store.remove(pendingKey(ownerId))
        store.remove(syncedKey(ownerId))
    }

    fun visibleMessages(messages: List<ChatMessage>, ownerId: String): List<ChatMessage> {
        val blocked = blockedUserIds(ownerId)
        return messages.filter { m ->
            m.kind == ChatMessageKind.SYSTEM || m.senderId == null || m.senderId !in blocked
        }
    }

    private fun blockKey(ownerId: String) = BLOCK_PREFIX + ownerId
    private fun pendingKey(ownerId: String) = PENDING_PREFIX + ownerId
    private fun syncedKey(ownerId: String) = SYNCED_PREFIX + ownerId

    private fun readList(key: String): List<String> =
        store.getString(key)?.split(SEPARATOR)?.filter { it.isNotEmpty() } ?: emptyList()

    private fun writeList(key: String, values: List<String>) {
        store.putString(key, values.joinToString(SEPARATOR))
    }

    private companion object {
        const val BLOCK_PREFIX = "paircast.chat.blocked."
        const val PENDING_PREFIX = "paircast.chat.blockPending."
        const val SYNCED_PREFIX = "paircast.chat.blockSynced."
        const val SEPARATOR = "\u001E"
    }
}
