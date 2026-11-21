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
import com.goim.kmp.domain.InboundEvent
import com.goim.kmp.model.ChatType
import com.goim.kmp.model.MsgType
import com.goim.kmp.model.StickerRef as GoImStickerRef
import com.goim.sdk.core.GoImSdkPreview
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.merge

/**
 * Room chat over GO-IM group chat via sdk-core: text / stickers, with local echo after send.
 * System lines carry `[sys]`; group membership notifications are filtered out.
 */
@OptIn(GoImSdkPreview::class, ExperimentalCoroutinesApi::class)
class GoImChatGateway(
    private val link: GoImRealtimeLink,
    private val auth: GoImAuthGateway,
) : ChatGateway {
    private val localEcho = MutableSharedFlow<ChatMessage>(extraBufferCapacity = 64)

    override suspend fun send(room: WatchRoom, text: String, sender: User): ChatMessage {
        val groupId = room.groupId ?: throw AppError.RoomNotFound
        val sent = link.requireLite().messages.sendText(groupId, ChatType.GROUP, text, link.requireLite().user)
        return echo(
            ChatMessage(
                id = sent.serverMsgId?.toString() ?: sent.id,
                roomId = room.id,
                senderId = sender.id,
                senderNickname = sender.displayName,
                text = text,
                createdAtMs = sent.timestampMs,
            ),
        )
    }

    override suspend fun sendSticker(room: WatchRoom, sticker: StickerRef, sender: User): ChatMessage {
        val groupId = room.groupId ?: throw AppError.RoomNotFound
        val goimSticker = GoImStickerRef(
            packId = sticker.packId,
            stickerId = sticker.stickerId,
            format = sticker.format,
            width = sticker.width,
            height = sticker.height,
        )
        val sent = link.requireLite().messages.sendSticker(groupId, ChatType.GROUP, goimSticker, link.requireLite().user)
        return echo(
            ChatMessage(
                id = sent.serverMsgId?.toString() ?: sent.id,
                roomId = room.id,
                senderId = sender.id,
                senderNickname = sender.displayName,
                text = ChatStickerCodec.FALLBACK_TEXT,
                kind = ChatMessageKind.STICKER,
                sticker = sticker,
                createdAtMs = sent.timestampMs,
            ),
        )
    }

    override suspend fun postSystemMessage(room: WatchRoom, text: String): ChatMessage {
        val groupId = room.groupId ?: throw AppError.RoomNotFound
        val sent = link.requireLite().messages.sendText(groupId, ChatType.GROUP, SYSTEM_PREFIX + text, link.requireLite().user)
        return echo(
            ChatMessage(
                id = sent.serverMsgId?.toString() ?: sent.id,
                roomId = room.id,
                senderNickname = "System",
                text = text,
                kind = ChatMessageKind.SYSTEM,
                createdAtMs = sent.timestampMs,
            ),
        )
    }

    override fun messages(room: WatchRoom): Flow<ChatMessage> {
        val groupId = room.groupId ?: return localEcho.filter { it.roomId == room.id }
        val remote = link.liteSession.flatMapLatest { lite ->
            if (lite == null) {
                emptyFlow()
            } else {
                lite.connection.inboundEvents
                    .filterIsInstance<InboundEvent.MessageReceived>()
                    .mapNotNull { map(room.id, groupId, it) }
            }
        }
        return merge(remote, localEcho.filter { it.roomId == room.id })
    }

    private suspend fun map(roomId: String, groupId: String, event: InboundEvent.MessageReceived): ChatMessage? {
        val m = event.message
        if (m.chatType != ChatType.GROUP || m.toUid != groupId) return null
        if (m.content.isEmpty() || isGroupNotification(m.content, m.msgType)) return null
        val id = m.serverMsgId?.takeIf { it != 0L }?.toString() ?: m.id
        val sticker = if (m.msgType == MsgType.Sticker || ChatStickerCodec.isStickerPayload(m.content)) {
            ChatStickerCodec.decode(m.content)
        } else {
            null
        }
        if (sticker != null) {
            return ChatMessage(id, roomId, m.fromUid, auth.nickname(m.fromUid), ChatStickerCodec.FALLBACK_TEXT, ChatMessageKind.STICKER, sticker, m.timestampMs)
        }
        if (m.content.startsWith(SYSTEM_PREFIX)) {
            return ChatMessage(id, roomId, m.fromUid, "System", m.content.removePrefix(SYSTEM_PREFIX), ChatMessageKind.SYSTEM, null, m.timestampMs)
        }
        return ChatMessage(id, roomId, m.fromUid, auth.nickname(m.fromUid), m.content, ChatMessageKind.USER, null, m.timestampMs)
    }

    private suspend fun echo(message: ChatMessage): ChatMessage {
        localEcho.emit(message)
        return message
    }

    companion object {
        const val SYSTEM_PREFIX = "[sys]"
        private val NOTIFICATION_TYPES = setOf("member_joined", "member_left", "member_kicked", "group_renamed", "owner_transferred")

        /** REST group join/leave makes the gateway push `{"type":"member_joined","group_id":…}` as group chat. */
        internal fun isGroupNotification(content: String, msgType: MsgType = MsgType.Text): Boolean {
            if (msgType != MsgType.Text || !content.startsWith("{")) return false
            val obj = runCatching { PaircastJson.default.parseToJsonElement(content).jsonObject }.getOrNull() ?: return false
            val type = (obj["type"] as? JsonPrimitive)?.contentOrNull ?: return false
            return type in NOTIFICATION_TYPES && obj["group_id"] != null
        }
    }
}

/** Playback signals ([PaircastSignal.PLAYBACK]) over Lite [GoImSession.sendSignal] / [GoImSession.signals]. */
@OptIn(GoImSdkPreview::class, ExperimentalCoroutinesApi::class)
class GoImPlaybackSyncGateway(private val link: GoImRealtimeLink) : PlaybackSyncGateway {
    override suspend fun send(room: WatchRoom, signal: PlaybackSyncSignal) {
        val groupId = room.groupId ?: throw AppError.RoomNotFound
        val dataJson = PaircastJson.default.encodeToString(PlaybackSyncSignal.serializer(), signal)
        link.requireLite().sendSignal(to = groupId, type = PaircastSignal.PLAYBACK, dataJson = dataJson)
    }

    override fun signals(room: WatchRoom): Flow<PlaybackSyncSignal> {
        val groupId = room.groupId
        return link.liteSession.flatMapLatest { lite ->
            if (lite == null) {
                emptyFlow()
            } else {
                lite.signals
                    .filter { it.type == PaircastSignal.PLAYBACK && it.to == groupId }
                    .mapNotNull { event ->
                        runCatching {
                            PaircastJson.default.decodeFromString(PlaybackSyncSignal.serializer(), event.dataJson)
                        }.getOrNull()?.let { it.copy(senderId = event.from.ifEmpty { it.senderId }) }
                    }
                    .filter { it.senderId != link.selfUid }
            }
        }
    }
}
