package com.chaisz.paircast.core

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.rules.HostTransferRules
import com.chaisz.paircast.core.session.WatchDependencies
import com.chaisz.paircast.core.session.WatchEvent
import com.chaisz.paircast.core.session.WatchSession
import com.chaisz.paircast.core.store.ChatSafetyStore
import com.chaisz.paircast.core.store.InMemoryKeyValueStore
import com.chaisz.paircast.core.store.SubtitleOffsetStore
import com.chaisz.paircast.core.model.AuthOptions
import com.chaisz.paircast.core.usecase.ChangeMovieUseCase
import com.chaisz.paircast.core.usecase.DeleteAccountUseCase
import com.chaisz.paircast.core.usecase.LeaveRoomUseCase
import com.chaisz.paircast.core.usecase.ListMoviesUseCase
import com.chaisz.paircast.core.usecase.LoadAuthOptionsUseCase
import com.chaisz.paircast.core.usecase.LoginUseCase
import com.chaisz.paircast.core.usecase.RegisterUseCase
import com.chaisz.paircast.core.usecase.SaveCloudConfigUseCase
import com.chaisz.paircast.core.usecase.SendRegisterCodeUseCase
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
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
        assertEquals(AppError.NotConfigured, assertFailsWith<AppError> { sut("alice", "secret", true) })
    }

    @Test fun requiresServerUrl() = runTest {
        val sut = LoginUseCase(FakeConfigGateway(configFixture().copy(im = IMConfig(""))), FakeAuthGateway())
        assertIs<AppError.IncompleteConfig>(assertFailsWith<AppError> { sut("alice", "secret", true) })
    }

    @Test fun successLogsIn() = runTest {
        val auth = FakeAuthGateway(null)
        val result = LoginUseCase(FakeConfigGateway(configFixture()), auth)(" alice ", "secret", true)
        assertEquals("alice", result.user.id)
        assertEquals(1, auth.loginCalls)
    }

    @Test fun requiresTermsAgreementBeforeNetwork() = runTest {
        val auth = FakeAuthGateway(null)
        val error = assertFailsWith<AppError> { LoginUseCase(FakeConfigGateway(configFixture()), auth)("alice", "secret", false) }
        assertEquals("Please read and agree to the Terms of Service and Privacy Policy first", error.localizationKey)
        assertEquals(0, auth.loginCalls)
    }

    @Test fun wrongPasswordSurfacesInvalidCredentials() = runTest {
        val sut = LoginUseCase(FakeConfigGateway(configFixture()), FakeAuthGateway(null))
        assertEquals(AppError.InvalidCredentials, assertFailsWith<AppError> { sut("alice", "nope", true) })
    }
}

class RegisterUseCaseTest {
    @Test fun optionsUnavailableWithoutServer() = runTest {
        val sut = LoadAuthOptionsUseCase(FakeConfigGateway(null), FakeAuthGateway())
        assertEquals(AuthOptions.Unavailable, sut())
    }

    @Test fun optionsFromServer() = runTest {
        val auth = FakeAuthGateway().apply { options = AuthOptions(registrationOpen = false, emailVerification = true) }
        val options = LoadAuthOptionsUseCase(FakeConfigGateway(configFixture()), auth)()
        assertFalse(options.canRegister)
    }

    @Test fun sendCodeNormalizesEmail() = runTest {
        val auth = FakeAuthGateway(null)
        val cooldown = SendRegisterCodeUseCase(FakeConfigGateway(configFixture()), auth)(" Dana@Example.com ")
        assertEquals(60, cooldown)
        assertEquals(listOf("dana@example.com"), auth.sentCodes)
    }

    @Test fun sendCodeRejectsBadEmailBeforeNetwork() = runTest {
        val auth = FakeAuthGateway(null)
        assertIs<AppError.Validation>(assertFailsWith<AppError> {
            SendRegisterCodeUseCase(FakeConfigGateway(configFixture()), auth)("not-an-email")
        })
        assertTrue(auth.sentCodes.isEmpty())
    }

    @Test fun registerValidatesAndSignsIn() = runTest {
        val auth = FakeAuthGateway(null)
        val sut = RegisterUseCase(FakeConfigGateway(configFixture()), auth)
        assertIs<AppError.Validation>(assertFailsWith<AppError> { sut("a@b.co", "12345", "secret1", "secret1", "", true) })
        assertIs<AppError.Validation>(assertFailsWith<AppError> { sut("a@b.co", "123456", "secret1", "secret2", "", true) })
        assertIs<AppError.Validation>(assertFailsWith<AppError> { sut("a@b.co", "123456", "secret1", "secret1", "", false) })
        assertEquals(null, auth.registered)
        val result = sut("a@b.co", "123456", "secret1", "secret1", "  ", true)
        assertEquals("100000", result.user.id)
        assertEquals(Triple("a@b.co", "secret1", null), auth.registered)
    }

    @Test fun deleteAccountNeedsPassword() = runTest {
        val auth = FakeAuthGateway()
        assertIs<AppError.Validation>(assertFailsWith<AppError> { DeleteAccountUseCase(auth)("") })
        DeleteAccountUseCase(auth)("secret")
        assertTrue(auth.deleted)
    }
}

class ConfigUseCaseTest {
    @Test fun saveNormalizesServerAndStampsVersion() = runTest {
        val gateway = FakeConfigGateway(null)
        val saved = SaveCloudConfigUseCase(gateway)(AppCloudConfig(im = IMConfig(" im.example.com/ "), configVersion = 4))
        assertEquals("https://im.example.com", gateway.config?.im?.serverUrl)
        assertEquals(AppCloudConfig.CURRENT_VERSION, saved.configVersion)
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

    @Test fun listMoviesEnrichesOnlyItemsWithoutPoster() = runTest {
        val catalog = FakeCatalog(listOf(movieFixture("oss:a").copy(posterUrl = "https://p"), movieFixture("oss:b")))
        val movies = ListMoviesUseCase(FakeConfigGateway(configFixture()), catalog, catalog)(sourceId = "oss")
        assertEquals(listOf<String?>("oss"), catalog.listedSources)
        assertEquals(listOf("oss:b"), catalog.enriched)
        assertEquals(listOf<String?>(null, "enriched"), movies.map { it.overview })
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
        assertEquals("https://cdn/m1", h.player.prepared)
        assertFalse(state.isHost)
        assertEquals("One", state.suggestedOnlineQuery)

        h.sync.incoming.emit(PlaybackSyncSignal(action = PlaybackAction.PLAY, positionMs = 5_000, senderId = "host", seq = 2))
        runCurrent()
        assertFalse(h.player.isPaused)
        assertEquals(listOf(5_000L), h.player.seeks)
        h.session.close()
    }

    @Test fun lateJoinerLoadsRoomSharedSubtitle() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.rooms.rooms["room1"] = h.rooms.rooms["room1"]!!.copy(subtitleRef = "blob:paircast/subtitles/shared/room1/1.srt", subtitleLabel = "中文")
        h.session.start()
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(listOf("blob:paircast/subtitles/shared/room1/1.srt"), h.subtitles.sharedDownloads)
        assertEquals("shared:blob:paircast/subtitles/shared/room1/1.srt", h.session.state.value.subtitleState.trackId)
        h.session.close()
    }

    @Test fun hostSharesOnlineSubtitleThroughServer() = runTest {
        val h = Harness(this, User("host", "Host"), roomHost = "host")
        h.session.start()
        advanceTimeBy(1_000)
        runCurrent()
        h.session.selectTrack(SubtitleTrack(id = "os:1", label = "English", source = SubtitleSource.ONLINE))
        runCurrent()
        assertEquals(listOf("/tmp/os:1.srt"), h.subtitles.uploads)
        val signal = h.sync.sent.last { it.action == PlaybackAction.SUBTITLE_CHANGE }
        assertEquals("blob:paircast/subtitles/shared/room1/1.srt", signal.subtitleObjectKey)
        h.session.close()
    }

    @Test fun hostSharesLibrarySidecarByRefWithoutUpload() = runTest {
        val h = Harness(this, User("host", "Host"), roomHost = "host")
        h.session.start()
        advanceTimeBy(1_000)
        runCurrent()
        h.session.selectTrack(SubtitleTrack(id = "src:oss:films/a.srt", label = "ZH", source = SubtitleSource.LIBRARY, url = "src:oss:films/a.srt"))
        runCurrent()
        assertTrue(h.subtitles.uploads.isEmpty())
        assertEquals("src:oss:films/a.srt", h.sync.sent.last { it.action == PlaybackAction.SUBTITLE_CHANGE }.subtitleObjectKey)
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

    @Test fun playingHostPausesRoomInBackgroundAndReloadsAfterLongAbsence() = runTest {
        var now = 1_000_000L
        val h = Harness(this, User("host", "Host"), roomHost = "host", nowMs = { now })
        h.session.start()
        runCurrent()
        h.session.togglePlay()
        runCurrent()
        h.player.currentPositionMs = 42_000

        h.session.onBackground()
        runCurrent()
        assertTrue(h.player.isPaused)
        assertTrue(h.player.inBackground)
        assertEquals(PlaybackAction.PAUSE, h.sync.sent.last().action)
        assertEquals(42_000L, h.sync.sent.last().positionMs)

        h.player.prepared = null
        now += WatchSession.RELOAD_AFTER_BACKGROUND_MS
        h.session.onForeground()
        runCurrent()
        assertFalse(h.player.inBackground)
        assertEquals("https://cdn/m1", h.player.prepared)
        assertEquals(42_000L, h.player.seeks.last())
        assertTrue(h.player.isPaused)
        h.session.close()
    }

    @Test fun shortBackgroundKeepsStream() = runTest {
        var now = 1_000_000L
        val h = Harness(this, User("host", "Host"), roomHost = "host", nowMs = { now })
        h.session.start()
        runCurrent()
        h.session.onBackground()
        runCurrent()
        assertTrue(h.sync.sent.isEmpty(), "paused host has nothing to broadcast")
        h.player.prepared = null
        now += 2_000
        h.session.onForeground()
        runCurrent()
        assertEquals(null, h.player.prepared)
        h.session.close()
    }

    @Test fun backgroundedMemberIgnoresHostPlay() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.session.start()
        runCurrent()
        h.session.onBackground()
        h.sync.incoming.emit(PlaybackSyncSignal(action = PlaybackAction.PLAY, positionMs = 5_000, senderId = "host", seq = 2))
        runCurrent()
        assertTrue(h.player.isPaused)
        assertTrue(h.sync.sent.isEmpty())

        h.session.onForeground()
        h.sync.incoming.emit(PlaybackSyncSignal(action = PlaybackAction.HEARTBEAT, positionMs = 9_000, senderId = "host", seq = 3))
        runCurrent()
        assertFalse(h.player.isPaused)
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

    @Test fun chatFromSenderOutsideRosterLoadsTheirProfile() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.session.start()
        runCurrent()
        h.chat.incoming.emit(ChatMessage(id = "1", roomId = "room1", senderId = "carol", senderNickname = "Carol", text = "hi"))
        runCurrent()
        assertEquals("nick-carol", h.session.state.value.memberProfiles["carol"]?.nickname)
        h.session.close()
    }

    @Test fun ownProfileEditUpdatesRoomProfiles() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.session.start()
        runCurrent()
        h.auth.currentUser.value = User("member", "Member", avatarUrl = "https://im/avatar/9")
        runCurrent()
        assertEquals("https://im/avatar/9", h.session.state.value.memberAvatarUrl("member"))
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
