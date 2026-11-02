package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.RoomGateway
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.data.rooms.OssRoomStore
import com.chaisz.paircast.data.support.PaircastLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlin.uuid.Uuid

/**
 * Room = OSS JSON record (roster, host, revision) + a GO-IM group (`groupId`) for chat and
 * playback signals. The host creates the group first, so a record without `groupId` is invalid.
 */
class GoImRoomGateway(
    private val store: OssRoomStore,
    private val api: GoImApi,
    private val auth: GoImAuthGateway,
    private val fetchAttempts: Int = 4,
    private val fetchRetryDelayMs: Long = 1_500,
) : RoomGateway {

    override suspend fun createRoom(movieId: String, hostUserId: String): WatchRoom {
        val session = auth.session ?: throw AppError.SessionExpired
        val id = Uuid.random().toString().lowercase()
        val groupId = authed { api.createGroup(session, "paircast-$id") }
        return store.write(WatchRoom(id = id, movieId = movieId, hostUserId = hostUserId, groupId = groupId))
    }

    override suspend fun joinRoom(roomId: String, userId: String, movieId: String?, hostUserId: String?): WatchRoom {
        val id = roomId.trim().lowercase()
        if (id.isEmpty()) throw AppError.RoomNotFound
        val session = auth.session ?: throw AppError.SessionExpired

        // The host's PUT can be briefly invisible right after an invite is shared.
        var room: WatchRoom? = null
        for (attempt in 1..fetchAttempts) {
            room = store.fetch(id)
            if (room?.groupId != null) break
            if (attempt < fetchAttempts) delay(fetchRetryDelayMs)
        }
        val found = room ?: throw AppError.RoomNotFound
        if (found.status != RoomStatus.ACTIVE) throw AppError.RoomEnded
        val groupId = found.groupId ?: throw AppError.RoomNotFound

        try {
            api.joinGroup(session, groupId)
        } catch (e: GoImHttpException) {
            if (e.status == 401) throw AppError.SessionExpired
            // Re-entering a room we never left reports "already a member"; a missing group means
            // everyone left and it dissolved.
            if (userId !in found.memberIds) throw AppError.RoomEnded
        }

        if (userId in found.memberIds) return store.write(found)
        return store.write(found.copy(memberIds = found.memberIds + userId, joinOrder = found.joinOrder + userId))
    }

    override suspend fun leaveRoom(room: WatchRoom, userId: String): WatchRoom? {
        val session = auth.session
        val groupId = room.groupId
        if (session != null && groupId != null) {
            try {
                api.leaveGroup(session, groupId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                PaircastLog.error("rooms", "leaveGroup failed group=$groupId: ${e.message}")
            }
        }
        return store.cached(room.id) ?: runCatching { store.fetch(room.id) }.getOrNull()
    }

    override suspend fun updateRoom(room: WatchRoom) {
        store.write(room)
    }

    override fun observeRoom(roomId: String): Flow<WatchRoom> = store.observe(roomId)

    private suspend fun <T> authed(block: suspend () -> T): T = try {
        block()
    } catch (e: GoImHttpException) {
        if (e.status == 401) throw AppError.SessionExpired
        throw AppError.Unknown("Server error {{code}}", mapOf("code" to e.status.toString()))
    }
}
