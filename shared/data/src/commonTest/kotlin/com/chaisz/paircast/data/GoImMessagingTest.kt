package com.chaisz.paircast.data

import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.data.goim.GoImChatGateway
import com.chaisz.paircast.data.goim.PaircastSignal
import com.chaisz.paircast.data.goim.SignalCodec
import com.goim.kmp.model.MsgType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GoImMessagingTest {
    @Test
    fun gatewayMembershipNotificationsAreNotChat() {
        assertTrue(GoImChatGateway.isGroupNotification("""{"type":"member_joined","group_id":"g_1","uid":"bob"}"""))
        assertTrue(GoImChatGateway.isGroupNotification("""{"group_id":"g_1","type":"member_left","uid":"bob"}"""))
    }

    @Test
    fun userTextThatLooksLikeJsonStaysChat() {
        assertFalse(GoImChatGateway.isGroupNotification("hello"))
        assertFalse(GoImChatGateway.isGroupNotification("""{"type":"member_joined"}"""))
        assertFalse(GoImChatGateway.isGroupNotification("""{"type":"party","group_id":"g_1"}"""))
        assertFalse(GoImChatGateway.isGroupNotification("""{"pack":"a","id":"b"}""", MsgType.Sticker))
    }

    @Test
    fun playbackSignalUsesTypedEnvelope() {
        val signal = PlaybackSyncSignal(action = PlaybackAction.PLAY, positionMs = 1_000, seq = 3, senderId = "alice")
        val content = SignalCodec.encode(PaircastSignal.PLAYBACK, PlaybackSyncSignal.serializer(), signal)
        assertTrue(content.startsWith("""{"type":"paircast.playback","data":{"""), content)
        assertEquals(signal, SignalCodec.decode(content, PaircastSignal.PLAYBACK, PlaybackSyncSignal.serializer()))
        assertNull(SignalCodec.decode(content, PaircastSignal.ROOM_UPDATED, PlaybackSyncSignal.serializer()))
        assertNull(SignalCodec.decode("""{"action":"play","positionMs":1,"seq":2}""", PaircastSignal.PLAYBACK, PlaybackSyncSignal.serializer()))
    }
}
