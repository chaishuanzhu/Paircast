package com.chaisz.paircast.data

import com.chaisz.paircast.data.goim.Cmd
import com.chaisz.paircast.data.goim.ChatType
import com.chaisz.paircast.data.goim.GoImApi
import com.chaisz.paircast.data.goim.GoImChatGateway
import com.chaisz.paircast.data.goim.GoImConnection
import com.chaisz.paircast.data.goim.MsgType
import com.chaisz.paircast.data.goim.PaircastSignal
import com.chaisz.paircast.data.goim.SignalCodec
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import im.Message
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respondOk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Clock

class GoImMessagingTest {
    private fun group(content: String, msgType: Int = MsgType.TEXT) =
        Message(cmd = Cmd.CHAT, chat_type = ChatType.GROUP, to = "g_1", from = "bob", msg_type = msgType, content = content)

    @Test fun gatewayMembershipNotificationsAreNotChat() {
        assertTrue(GoImChatGateway.isGroupNotification(group("""{"type":"member_joined","group_id":"g_1","uid":"bob"}""")))
        assertTrue(GoImChatGateway.isGroupNotification(group("""{"group_id":"g_1","type":"member_left","uid":"bob"}""")))
    }

    @Test fun userTextThatLooksLikeJsonStaysChat() {
        assertFalse(GoImChatGateway.isGroupNotification(group("hello")))
        assertFalse(GoImChatGateway.isGroupNotification(group("""{"type":"member_joined"}""")))
        assertFalse(GoImChatGateway.isGroupNotification(group("""{"type":"party","group_id":"g_1"}""")))
        assertFalse(GoImChatGateway.isGroupNotification(group("""{"pack":"a","id":"b"}""", MsgType.STICKER)))
    }

    @Test fun seqStartsFromClockAndIncreases() {
        val client = HttpClient(MockEngine { respondOk() })
        val connection = GoImConnection(client, GoImApi(client), CoroutineScope(SupervisorJob()), deviceId = "dev", platform = "test")
        val before = Clock.System.now().toEpochMilliseconds()
        val first = connection.nextSeq()
        val second = connection.nextSeq()
        assertTrue(first >= before)
        assertTrue(second > first)
    }

    @Test
    fun playbackSignalUsesTypedEnvelope() {
        val signal = PlaybackSyncSignal(action = PlaybackAction.PLAY, positionMs = 1_000, seq = 3, senderId = "alice")
        val content = SignalCodec.encode(PaircastSignal.PLAYBACK, PlaybackSyncSignal.serializer(), signal)
        assertTrue(content.startsWith("""{"type":"paircast.playback","data":{"""), content)
        assertEquals(signal, SignalCodec.decode(content, PaircastSignal.PLAYBACK, PlaybackSyncSignal.serializer()))
        assertNull(SignalCodec.decode(content, PaircastSignal.ROOM_UPDATED, PlaybackSyncSignal.serializer()))
        // Untyped legacy payloads are ignored.
        assertNull(SignalCodec.decode("""{"action":"play","positionMs":1,"seq":2}""", PaircastSignal.PLAYBACK, PlaybackSyncSignal.serializer()))
    }
}
