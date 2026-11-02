package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.ChatGateway
import com.chaisz.paircast.core.gateway.PlaybackSyncGateway
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.rules.ChatStickerCodec
import com.chaisz.paircast.core.support.PaircastJson
import im.Message
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.merge
import kotlin.time.Clock

/**
 * Room chat over GO-IM group chat (`CmdChat`, `chat_type=2`): text `msg_type=1` (system lines
 * carry `[sys]`), stickers `msg_type=6` with JSON [StickerRef]. Own messages are echoed locally
 * once the server acks them (the gateway does not echo to the sending connection).
 */
class GoImChatGateway(
    private val connection: GoImConnection,
    private val auth: GoImAuthGateway,
) : ChatGateway {
    private val localEcho = MutableSharedFlow<ChatMessage>(extraBufferCapacity = 64)

    override suspend fun send(room: WatchRoom, text: String, sender: User): ChatMessage {
        val msgId = sendGroup(room, MsgType.TEXT, text)
        return echo(ChatMessage(id = msgId, roomId = room.id, senderId = sender.id, senderNickname = sender.displayName, text = text, createdAtMs = now()))
    }

    override suspend fun sendSticker(room: WatchRoom, sticker: StickerRef, sender: User): ChatMessage {
        val msgId = sendGroup(room, MsgType.STICKER, ChatStickerCodec.encodeJson(sticker))
        return echo(
            ChatMessage(
                id = msgId,
                roomId = room.id,
                senderId = sender.id,
                senderNickname = sender.displayName,
                text = ChatStickerCodec.FALLBACK_TEXT,
                kind = ChatMessageKind.STICKER,
                sticker = sticker,
                createdAtMs = now(),
            ),
        )
    }

    override suspend fun postSystemMessage(room: WatchRoom, text: String): ChatMessage {
        val msgId = sendGroup(room, MsgType.TEXT, SYSTEM_PREFIX + text)
        return echo(ChatMessage(id = msgId, roomId = room.id, senderNickname = "System", text = text, kind = ChatMessageKind.SYSTEM, createdAtMs = now()))
    }

    override fun messages(room: WatchRoom): Flow<ChatMessage> {
        val groupId = room.groupId ?: return localEcho.filter { it.roomId == room.id }
        val remote = connection.inbound
            .filter { it.cmd == Cmd.CHAT && it.chat_type == ChatType.GROUP && it.to == groupId }
            .mapNotNull { map(room.id, it) }
        return merge(remote, localEcho.filter { it.roomId == room.id })
    }

    private suspend fun map(roomId: String, m: Message): ChatMessage? {
        if (m.content.isEmpty()) return null
        val id = if (m.msg_id != 0L) m.msg_id.toString() else "${m.from}-${m.seq}"
        val sticker = if (m.msg_type == MsgType.STICKER || ChatStickerCodec.isStickerPayload(m.content)) {
            ChatStickerCodec.decode(m.content)
        } else {
            null
        }
        if (sticker != null) {
            return ChatMessage(id, roomId, m.from, auth.nickname(m.from), ChatStickerCodec.FALLBACK_TEXT, ChatMessageKind.STICKER, sticker, m.timestamp)
        }
        if (m.content.startsWith(SYSTEM_PREFIX)) {
            return ChatMessage(id, roomId, m.from, "System", m.content.removePrefix(SYSTEM_PREFIX), ChatMessageKind.SYSTEM, null, m.timestamp)
        }
        return ChatMessage(id, roomId, m.from, auth.nickname(m.from), m.content, ChatMessageKind.USER, null, m.timestamp)
    }

    private suspend fun sendGroup(room: WatchRoom, msgType: Int, content: String): String {
        val groupId = room.groupId ?: throw AppError.RoomNotFound
        val msgId = connection.sendAwaitingAck(
            Message(
                cmd = Cmd.CHAT,
                to = groupId,
                chat_type = ChatType.GROUP,
                msg_type = msgType,
                content = content,
                timestamp = now(),
            ),
        )
        return msgId.toString()
    }

    private suspend fun echo(message: ChatMessage): ChatMessage {
        localEcho.emit(message)
        return message
    }

    private fun now() = Clock.System.now().toEpochMilliseconds()

    companion object {
        const val SYSTEM_PREFIX = "[sys]"
    }
}

/** Playback signals over the transient `CmdGroupSignal` (never stored, no unread, no echo). */
class GoImPlaybackSyncGateway(private val connection: GoImConnection) : PlaybackSyncGateway {
    override suspend fun send(room: WatchRoom, signal: PlaybackSyncSignal) {
        val groupId = room.groupId ?: throw AppError.RoomNotFound
        connection.send(
            Message(
                cmd = Cmd.GROUP_SIGNAL,
                seq = connection.nextSeq(),
                to = groupId,
                chat_type = ChatType.GROUP,
                content = PaircastJson.default.encodeToString(PlaybackSyncSignal.serializer(), signal),
                timestamp = Clock.System.now().toEpochMilliseconds(),
            ),
        )
    }

    override fun signals(room: WatchRoom): Flow<PlaybackSyncSignal> {
        val groupId = room.groupId
        return connection.inbound
            .filter { it.cmd == Cmd.GROUP_SIGNAL && it.to == groupId }
            .mapNotNull { m ->
                runCatching { PaircastJson.default.decodeFromString(PlaybackSyncSignal.serializer(), m.content) }.getOrNull()
                    // Trust the server-stamped sender over the payload.
                    ?.let { it.copy(senderId = m.from.ifEmpty { it.senderId }) }
            }
            .filter { it.senderId != connection.selfUid }
    }
}
