package com.chaisz.paircast.core

import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.rules.ConfigQRCodec
import com.chaisz.paircast.core.rules.HostTransferRules
import com.chaisz.paircast.core.session.WatchDependencies
import com.chaisz.paircast.core.session.WatchEvent
import com.chaisz.paircast.core.session.WatchSession
import com.chaisz.paircast.core.store.ChatSafetyStore
import com.chaisz.paircast.core.store.InMemoryKeyValueStore
import com.chaisz.paircast.core.store.SubtitleOffsetStore
import com.chaisz.paircast.core.usecase.ChangeMovieUseCase
import com.chaisz.paircast.core.usecase.ExportConfigUseCase
import com.chaisz.paircast.core.usecase.ImportConfigUseCase
import com.chaisz.paircast.core.usecase.LeaveRoomUseCase
import com.chaisz.paircast.core.usecase.LoginUseCase
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class LoginUseCaseTest {
    @Test fun requiresConfig() = runTest {
        val sut = LoginUseCase(FakeConfigGateway(null), FakeAuthGateway())
        assertEquals(AppError.NotConfigured, assertFailsWith<AppError> { sut("alice", "secret") })
    }

    @Test fun requiresServerUrl() = runTest {
        val sut = LoginUseCase(FakeConfigGateway(configFixture().copy(im = IMConfig(""))), FakeAuthGateway())
        assertIs<AppError.IncompleteConfig>(assertFailsWith<AppError> { sut("alice", "secret") })
    }

    @Test fun successLogsIn() = runTest {
        val auth = FakeAuthGateway(null)
        val result = LoginUseCase(FakeConfigGateway(configFixture()), auth)(" alice ", "secret")
        assertEquals("alice", result.user.id)
        assertEquals(1, auth.loginCalls)
    }

    @Test fun wrongPasswordSurfacesInvalidCredentials() = runTest {
        val sut = LoginUseCase(FakeConfigGateway(configFixture()), FakeAuthGateway(null))
        assertEquals(AppError.InvalidCredentials, assertFailsWith<AppError> { sut("alice", "nope") })
    }
}

class ConfigUseCaseTest {
    @Test fun invalidImportDoesNotOverwrite() = runTest {
        val existing = configFixture()
        val gateway = FakeConfigGateway(existing)
        assertFailsWith<AppError> { ImportConfigUseCase(gateway, PlainLinkCodec())("not-json") }
        assertEquals(existing, gateway.config)
    }

    @Test fun validImportReplacesConfig() = runTest {
        val gateway = FakeConfigGateway(configFixture())
        val next = configFixture().copy(storage = configFixture().storage.copy(bucket = "other-bucket"))
        val codec = PlainLinkCodec()
        val result = ImportConfigUseCase(gateway, codec)(codec.shareUrl(next))
        assertFalse(result.needsServerUrl)
        assertEquals("other-bucket", gateway.config?.storage?.bucket)
    }

    @Test fun legacyImportKeepsExistingServer() = runTest {
        val gateway = FakeConfigGateway(configFixture())
        val legacy = """{"v":3,"type":"paircast-config","im":{"sdkAppId":1,"secretKey":"x"},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"legacy","endpoint":"s3.cn-south-1.qiniucs.com","useSSL":true,"forcePathStyle":true}}"""
        val result = ImportConfigUseCase(gateway, PlainLinkCodec())(legacy)
        assertFalse(result.needsServerUrl)
        assertEquals("legacy", gateway.config?.storage?.bucket)
        assertEquals("https://im.example.com", gateway.config?.im?.serverUrl)
    }

    @Test fun legacyImportWithoutServerAsksForIt() = runTest {
        val gateway = FakeConfigGateway(null)
        val legacy = """{"v":3,"type":"paircast-config","im":{"sdkAppId":1,"secretKey":"x"},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"legacy","endpoint":"s3.cn-south-1.qiniucs.com","useSSL":true,"forcePathStyle":true}}"""
        val result = ImportConfigUseCase(gateway, PlainLinkCodec())(legacy)
        assertTrue(result.needsServerUrl)
        assertEquals(null, gateway.config)
    }

    @Test fun exportReturnsShareLink() = runTest {
        val exported = ExportConfigUseCase(FakeConfigGateway(configFixture()), PlainLinkCodec())()
        assertTrue(exported.startsWith("paircast://config?args="))
        assertEquals("movies", ConfigQRCodec.decode(exported.substringAfter("args=")).storage.bucket)
    }
}

class RoomUseCaseTest {
    @Test fun memberCannotChangeMovie() = runTest {
        val sut = ChangeMovieUseCase(FakeRoomGateway(), FakeSyncGateway(), FakeChatGateway())
        val error = assertFailsWith<AppError> { sut(roomFixture("host"), "member", movieFixture("m2"), 1) }
        assertEquals(AppError.OnlyHostCanSwitchMovie, error)
    }

    @Test fun hostChangeBroadcastsSignal() = runTest {
        val sync = FakeSyncGateway()
        val chat = FakeChatGateway()
        val result = ChangeMovieUseCase(FakeRoomGateway(), sync, chat)(roomFixture("host"), "host", movieFixture("m2", "New"), 3)
        assertEquals("m2", result.room.movieId)
        assertEquals(PlaybackAction.MOVIE_CHANGE, result.signal.action)
        assertEquals(1, sync.sent.size)
        assertTrue(chat.systemTexts.any { "New" in it })
    }

    @Test fun hostLeaveSignalsBeforeLeavingGroup() = runTest {
        val rooms = FakeRoomGateway()
        val sync = FakeSyncGateway()
        val chat = FakeChatGateway()
        val room = roomFixture("a").copy(memberIds = listOf("a", "b"), joinOrder = listOf("a", "b"))
        val outcome = LeaveRoomUseCase(rooms, chat, sync)(room, "a", 1_000, 9)
        assertIs<HostTransferRules.Outcome.Transfer>(outcome)
        assertEquals(PlaybackAction.HOST_TRANSFER, sync.sent.single().action)
        assertEquals("b", sync.sent.single().hostUserId)
        assertEquals(listOf("a"), rooms.left)
        assertEquals("b", rooms.rooms["room1"]?.hostUserId)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class WatchSessionTest {
    private class Harness(scope: TestScope, self: User, roomHost: String, nowMs: () -> Long = { 0L }) {
        val auth = FakeAuthGateway(self)
        val rooms = FakeRoomGateway().apply {
            rooms["room1"] = roomFixture(roomHost).copy(movieId = "m1", memberIds = listOf(roomHost), joinOrder = listOf(roomHost))
        }
        val sync = FakeSyncGateway()
        val chat = FakeChatGateway()
        val catalog = FakeCatalog(listOf(movieFixture("m1", "One"), movieFixture("m2", "Two")))
        val subtitles = FakeSubtitles()
        val player = FakePlayer()
        val session = WatchSession(
            WatchDependencies(
                authGateway = auth,
                configGateway = FakeConfigGateway(configFixture()),
                roomGateway = rooms,
                chatGateway = chat,
                syncGateway = sync,
                catalogGateway = catalog,
                metadataGateway = catalog,
                subtitleGateway = subtitles,
                sharedSubtitleStorage = subtitles,
                subtitleOffsets = SubtitleOffsetStore(InMemoryKeyValueStore()),
                chatSafety = ChatSafetyStore(InMemoryKeyValueStore()),
            ),
            player,
            initialRoomId = "room1",
            initialMovieId = "m1",
            initialHostUserId = roomHost,
            dispatcher = StandardTestDispatcher(scope.testScheduler),
            nowMs = nowMs,
        )
    }

    @Test fun memberJoinsPreparesAndFollowsHostPlay() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.session.start()
        runCurrent()
        val state = h.session.state.value
        assertEquals(listOf("host", "member"), state.room?.memberIds)
        assertEquals("One", state.movie?.title)
        assertEquals("https://cdn/m1.mp4", h.player.prepared)
        assertFalse(state.isHost)
        assertEquals("One", state.suggestedOnlineQuery)

        h.sync.incoming.emit(PlaybackSyncSignal(action = PlaybackAction.PLAY, positionMs = 5_000, senderId = "host", seq = 2))
        runCurrent()
        assertFalse(h.player.isPaused)
        assertEquals(listOf(5_000L), h.player.seeks)
        h.session.close()
    }

    @Test fun hostTogglePlayBroadcasts() = runTest {
        val h = Harness(this, User("host", "Host"), roomHost = "host")
        h.session.start()
        runCurrent()
        assertTrue(h.session.state.value.isHost)
        h.session.togglePlay()
        runCurrent()
        assertEquals(PlaybackAction.PLAY, h.sync.sent.last().action)
        assertFalse(h.player.isPaused)
        h.session.close()
    }

    @Test fun promotedHostEmitsAboveSeenSequence() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.session.start()
        runCurrent()
        h.sync.incoming.emit(PlaybackSyncSignal(action = PlaybackAction.PAUSE, positionMs = 0, senderId = "host", seq = 40))
        h.sync.incoming.emit(
            PlaybackSyncSignal(action = PlaybackAction.HOST_TRANSFER, positionMs = 0, hostUserId = "member", senderId = "host", seq = 41),
        )
        runCurrent()
        assertTrue(h.session.state.value.isHost)
        h.session.togglePlay()
        runCurrent()
        assertTrue(h.sync.sent.last().seq > 41)
        h.session.close()
    }

    @Test fun reopenedHostEmitsAboveClockSoMembersDoNotDropAsStale() = runTest {
        val h = Harness(this, User("host", "Host"), roomHost = "host", nowMs = { 1_700_000_000_000L })
        h.session.start()
        runCurrent()
        h.session.togglePlay()
        runCurrent()
        h.session.togglePlay()
        runCurrent()
        val seqs = h.sync.sent.map { it.seq }
        assertTrue(seqs.first() >= 1_700_000_000_000L)
        assertTrue(seqs.zipWithNext().all { (a, b) -> b > a })
        h.session.close()
    }

    @Test fun hostPushesStateWhenMemberJoins() = runTest {
        val h = Harness(this, User("host", "Host"), roomHost = "host")
        h.session.start()
        runCurrent()
        val room = h.session.state.value.room!!
        h.rooms.updates.emit(room.copy(memberIds = room.memberIds + "member", joinOrder = room.joinOrder + "member"))
        runCurrent()
        assertEquals(PlaybackAction.PAUSE, h.sync.sent.last().action)
        h.session.close()
    }

    @Test fun failedChatSendShowsToast() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.session.start()
        runCurrent()
        h.chat.failSend = true
        val toast = backgroundScope.async { h.session.events.first { it is WatchEvent.Toast } }
        h.session.sendChat("hi")
        runCurrent()
        assertEquals("Message failed to send", (toast.await() as WatchEvent.Toast).text.key)
        h.session.close()
    }

    @Test fun leaveEmitsLeftEvent() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.session.start()
        runCurrent()
        val left = backgroundScope.launch { h.session.events.first { it is WatchEvent.Left } }
        h.session.leave()
        runCurrent()
        assertTrue(left.isCompleted)
        assertEquals(listOf("member"), h.rooms.left)
        h.session.close()
    }
}
