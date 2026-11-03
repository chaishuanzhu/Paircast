package com.chaisz.paircast.data.media

import com.chaisz.paircast.core.gateway.RoomGateway
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.data.goim.Cmd
import com.chaisz.paircast.data.goim.GoImConnection
import com.chaisz.paircast.data.goim.PaircastSignal
import com.chaisz.paircast.data.goim.SignalCodec
import com.chaisz.paircast.data.support.PaircastLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Rooms live on GO-IM (`/room/…`): the server owns roster, host transfer and revision. Observers
 * get `paircast.room_updated` group signals in realtime plus a slow poll as a safety net; only newer
 * revisions are emitted.
 */
class ServerRoomGateway(
    private val api: ServerMediaApi,
    private val connection: GoImConnection,
    private val pollIntervalMs: Long = 15_000,
) : RoomGateway {
    private val lock = Mutex()
    private val cache = mutableMapOf<String, WatchRoom>()
    private val local = MutableSharedFlow<WatchRoom>(extraBufferCapacity = 16, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    override suspend fun createRoom(movieId: String, hostUserId: String): WatchRoom =
        accept(api.createRoom(movieId).toDomain())

    override suspend fun joinRoom(roomId: String, userId: String, movieId: String?, hostUserId: String?): WatchRoom {
        val id = roomId.trim().lowercase()
        if (id.isEmpty()) throw AppError.RoomNotFound
        val room = accept(api.joinRoom(id).toDomain())
        if (room.status != RoomStatus.ACTIVE) throw AppError.RoomEnded
        return room
    }

    override suspend fun leaveRoom(room: WatchRoom, userId: String, transferSeq: Long): WatchRoom? = try {
        accept(api.leaveRoom(room.id, transferSeq).toDomain())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        PaircastLog.error("rooms", "leave failed room=${room.id}: ${e.message}")
        null
    }

    override suspend fun updateRoom(room: WatchRoom) {
        val updated = api.updateRoom(
            roomId = room.id,
            movieId = room.movieId,
            hostUid = room.hostUserId,
            hostTransferSeq = room.hostTransferSeq,
            lastAppliedSeq = room.lastAppliedSeq,
            ended = room.status == RoomStatus.ENDED,
        )
        accept(updated.toDomain())
    }

    override fun observeRoom(roomId: String): Flow<WatchRoom> = channelFlow {
        val id = roomId.lowercase()
        var last: WatchRoom? = lock.withLock { cache[id] }
        val gate = Mutex()
        suspend fun offer(room: WatchRoom) = gate.withLock {
            if (room.id.lowercase() != id) return@withLock
            if (last?.let { room.revision <= it.revision } == true) return@withLock
            last = room
            send(room)
        }
        coroutineScope {
            launch { local.collect { offer(it) } }
            launch {
                connection.inbound
                    .filter { it.cmd == Cmd.SIGNAL }
                    .mapNotNull { parseRoomUpdated(it.content) }
                    .collect { offer(remember(it)) }
            }
            launch {
                while (true) {
                    try {
                        offer(remember(api.room(id).toDomain()))
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: AppError.RoomEnded) {
                        last?.let { offer(it.copy(status = RoomStatus.ENDED, revision = it.revision + 1)) }
                        return@launch
                    } catch (e: Exception) {
                        PaircastLog.error("rooms", "poll failed room=$id: ${e.message}")
                    }
                    delay(pollIntervalMs)
                }
            }
        }
    }

    private suspend fun accept(room: WatchRoom): WatchRoom {
        remember(room)
        local.tryEmit(room)
        return room
    }

    private suspend fun remember(room: WatchRoom): WatchRoom = lock.withLock {
        val id = room.id.lowercase()
        val cached = cache[id]
        if (cached == null || room.revision >= cached.revision) cache[id] = room
        room
    }

    companion object {
        internal fun parseRoomUpdated(content: String): WatchRoom? {
            val data = SignalCodec.decode(content, PaircastSignal.ROOM_UPDATED, RoomUpdatedDto.serializer()) ?: return null
            return data.room?.toDomain()
        }
    }
}
