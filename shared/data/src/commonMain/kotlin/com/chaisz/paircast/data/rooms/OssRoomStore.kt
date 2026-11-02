package com.chaisz.paircast.data.rooms

import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.support.PaircastJson
import com.chaisz.paircast.data.s3.S3Client
import com.chaisz.paircast.data.support.PaircastLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onSubscription
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

/**
 * Watch rooms persisted as JSON in the user's bucket (`_paircast/rooms/{id}.json`) and polled
 * every 2 s while observed. Membership / host / revision live here; realtime traffic is GO-IM.
 */
class OssRoomStore(
    private val configGateway: ConfigGateway,
    private val s3: S3Client,
    private val scope: CoroutineScope,
    private val pollIntervalMs: Long = 2_000,
) {
    private val lock = Mutex()
    private val cache = mutableMapOf<String, WatchRoom>()
    private val streams = mutableMapOf<String, MutableSharedFlow<WatchRoom>>()
    private val observerCounts = mutableMapOf<String, Int>()
    private val polls = mutableMapOf<String, Job>()

    suspend fun fetch(roomId: String): WatchRoom? {
        val config = requireConfig()
        val r = s3.get(objectKey(roomId), config.storage)
        if (r.status == 404) return null
        if (!r.isSuccess) {
            PaircastLog.error("rooms", "GET HTTP ${r.status}")
            throw AppError.Network
        }
        return PaircastJson.default.decodeFromString(WatchRoomDto.serializer(), r.body.decodeToString()).toDomain()
    }

    /** Writes with a bumped revision and broadcasts locally; returns the stored room. */
    suspend fun write(room: WatchRoom): WatchRoom {
        val updated = room.copy(revision = nextRevision(room))
        if (updated.status == RoomStatus.ENDED) {
            cacheAndBroadcast(updated)
            val config = requireConfig()
            val status = runCatching { s3.delete(objectKey(updated.id), config.storage) }.getOrDefault(-1)
            if (status != 404 && status !in 200..299) {
                PaircastLog.error("rooms", "DELETE failed id=${updated.id}; writing ended tombstone")
                put(updated)
            }
            stopPolling(updated.id)
            return updated
        }
        put(updated)
        cacheAndBroadcast(updated)
        return updated
    }

    suspend fun cached(roomId: String): WatchRoom? = lock.withLock { cache[roomId.lowercase()] }

    fun observe(roomId: String): Flow<WatchRoom> = flow {
        val id = roomId.lowercase()
        val stream = acquire(id)
        try {
            emitAll(stream.onSubscription { cached(id)?.let { emit(it) } })
        } finally {
            withContext(NonCancellable) { release(id) }
        }
    }

    private suspend fun acquire(id: String): MutableSharedFlow<WatchRoom> = lock.withLock {
        val stream = streams.getOrPut(id) {
            MutableSharedFlow(extraBufferCapacity = 16, onBufferOverflow = BufferOverflow.DROP_OLDEST)
        }
        observerCounts[id] = (observerCounts[id] ?: 0) + 1
        if (polls[id]?.isActive != true) polls[id] = scope.launch { pollLoop(id) }
        stream
    }

    private suspend fun release(id: String) = lock.withLock {
        val remaining = (observerCounts[id] ?: 1) - 1
        if (remaining <= 0) {
            observerCounts.remove(id)
            polls.remove(id)?.cancel()
        } else {
            observerCounts[id] = remaining
        }
    }

    private suspend fun pollLoop(id: String) {
        while (scope.isActive) {
            try {
                fetch(id)?.let { cacheAndBroadcast(it) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Transient network — keep polling while observed.
            }
            delay(pollIntervalMs)
        }
    }

    private suspend fun stopPolling(id: String) = lock.withLock { polls.remove(id.lowercase())?.cancel() }

    private suspend fun put(room: WatchRoom) {
        val config = requireConfig()
        val body = PaircastJson.default.encodeToString(WatchRoomDto.serializer(), WatchRoomDto(room)).encodeToByteArray()
        s3.put(objectKey(room.id), body, "application/json", config.storage)
    }

    private suspend fun cacheAndBroadcast(incoming: WatchRoom) {
        val (accepted, stream) = lock.withLock {
            val id = incoming.id.lowercase()
            val room = reconciled(incoming, cache[id]) ?: return
            cache[id] = room
            room to streams[id]
        }
        stream?.tryEmit(accepted)
    }

    private suspend fun nextRevision(room: WatchRoom): Long {
        val cachedRevision = lock.withLock { cache[room.id.lowercase()]?.revision ?: 0 }
        return maxOf(room.revision, cachedRevision) + 1
    }

    private suspend fun requireConfig(): AppCloudConfig {
        val config = configGateway.load()
        if (config == null || !config.storage.isComplete) throw AppError.NotConfigured
        return config
    }

    companion object {
        const val OBJECT_KEY_PREFIX = "_paircast/rooms/"

        fun objectKey(roomId: String) = OBJECT_KEY_PREFIX + roomId.lowercase() + ".json"

        /**
         * Accepts newer revisions; a revision-less (pre-revision build) snapshot is accepted only
         * when its roster is a superset of ours, keeping our revision so stale writes can't regress.
         */
        fun reconciled(incoming: WatchRoom, cached: WatchRoom?): WatchRoom? {
            if (cached == null || incoming.revision >= cached.revision) return incoming
            if (incoming.revision != 0L || !incoming.memberIds.toSet().containsAll(cached.memberIds)) return null
            return incoming.copy(revision = cached.revision)
        }
    }
}

@Serializable
internal data class WatchRoomDto(
    val id: String,
    val movieId: String,
    val hostUserId: String,
    val memberIds: List<String>,
    val joinOrder: List<String>,
    val status: String,
    val lastAppliedSeq: Long = 0,
    val hostTransferSeq: Long = 0,
    val revision: Long? = null,
    val groupId: String? = null,
) {
    constructor(room: WatchRoom) : this(
        id = room.id,
        movieId = room.movieId,
        hostUserId = room.hostUserId,
        memberIds = room.memberIds,
        joinOrder = room.joinOrder,
        status = room.status.rawValue,
        lastAppliedSeq = room.lastAppliedSeq,
        hostTransferSeq = room.hostTransferSeq,
        revision = room.revision,
        groupId = room.groupId,
    )

    fun toDomain() = WatchRoom(
        id = id,
        movieId = movieId,
        hostUserId = hostUserId,
        memberIds = memberIds,
        joinOrder = joinOrder,
        status = RoomStatus.entries.firstOrNull { it.rawValue == status } ?: RoomStatus.ENDED,
        lastAppliedSeq = lastAppliedSeq,
        hostTransferSeq = hostTransferSeq,
        revision = revision ?: 0,
        groupId = groupId,
    )
}
