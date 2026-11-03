package com.chaisz.paircast.core

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.ManagedUser
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.ReportAction
import com.chaisz.paircast.core.model.ReportFilter
import com.chaisz.paircast.core.model.ReportStatus
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.User
import com.chaisz.paircast.core.model.UserReport
import com.chaisz.paircast.core.rules.HostTransferRules
import com.chaisz.paircast.core.session.WatchDependencies
import com.chaisz.paircast.core.session.WatchEvent
import com.chaisz.paircast.core.session.WatchSession
import com.chaisz.paircast.core.store.ChatSafetyStore
import com.chaisz.paircast.core.store.InMemoryKeyValueStore
import com.chaisz.paircast.core.store.SubtitleOffsetStore
import com.chaisz.paircast.core.usecase.BlockUserUseCase
import com.chaisz.paircast.core.usecase.ChangeMovieUseCase
import com.chaisz.paircast.core.usecase.CreateUserUseCase
import com.chaisz.paircast.core.usecase.DeleteAccountUseCase
import com.chaisz.paircast.core.usecase.DeleteUserUseCase
import com.chaisz.paircast.core.usecase.LeaveRoomUseCase
import com.chaisz.paircast.core.usecase.ListMoviesUseCase
import com.chaisz.paircast.core.usecase.LoadReportsUseCase
import com.chaisz.paircast.core.usecase.LoadUsersUseCase
import com.chaisz.paircast.core.usecase.LoginUseCase
import com.chaisz.paircast.core.usecase.ReportMessageUseCase
import com.chaisz.paircast.core.usecase.ResolveReportUseCase
import com.chaisz.paircast.core.usecase.SaveCloudConfigUseCase
import com.chaisz.paircast.core.usecase.SetUserDisabledUseCase
import com.chaisz.paircast.core.usecase.SyncBlockListUseCase
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

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

class AccountUseCaseTest {
    private fun admin() = FakeAuthGateway().apply { currentUser.value = User("1", "root", isAdmin = true) }

    @Test fun createUserRequiresAdmin() = runTest {
        val accounts = FakeAccountAdminGateway()
        val auth = FakeAuthGateway().apply { currentUser.value = User("2", "bob") }
        assertEquals(AppError.AdminRequired, assertFailsWith<AppError> { CreateUserUseCase(auth, accounts)("a@b.co", "") })
        assertTrue(accounts.created.isEmpty())
    }

    @Test fun createUserValidatesBeforeNetwork() = runTest {
        val accounts = FakeAccountAdminGateway()
        val sut = CreateUserUseCase(admin(), accounts)
        assertIs<AppError.Validation>(assertFailsWith<AppError> { sut("not-an-email", "") })
        assertIs<AppError.Validation>(assertFailsWith<AppError> { sut("a@b.co", "x".repeat(17)) })
        assertTrue(accounts.created.isEmpty())
    }

    @Test fun createUserNormalizesAndReturnsPassword() = runTest {
        val accounts = FakeAccountAdminGateway()
        val sut = CreateUserUseCase(admin(), accounts)
        val created = sut(" Dana@Example.com ", "  ")
        assertEquals(listOf<Pair<String, String?>>("dana@example.com" to null), accounts.created)
        assertEquals("Init1234", created.initialPassword)
        assertFalse(created.mailed)
        accounts.mailer = true
        assertTrue(sut("eve@example.com", " Eve ").mailed)
        assertEquals("Eve", accounts.created.last().second)
        assertEquals(AppError.EmailAlreadyRegistered, assertFailsWith<AppError> { sut("dana@example.com", "") })
    }

    private fun managed(id: String, admin: Boolean = false) =
        ManagedUser(id, "u$id", null, null, isAdmin = admin, isDisabled = false, createdAtMs = 0)

    @Test fun userManagementRequiresAdmin() = runTest {
        val accounts = FakeAccountAdminGateway()
        val auth = FakeAuthGateway().apply { currentUser.value = User("2", "bob") }
        assertEquals(AppError.AdminRequired, assertFailsWith<AppError> { LoadUsersUseCase(auth, accounts)() })
        assertEquals(AppError.AdminRequired, assertFailsWith<AppError> { DeleteUserUseCase(auth, accounts)(managed("3")) })
        assertTrue(accounts.calls.isEmpty())
    }

    @Test fun adminCannotChangeSelfOrOtherAdmins() = runTest {
        val accounts = FakeAccountAdminGateway()
        val auth = admin()
        val disable = SetUserDisabledUseCase(auth, accounts)
        val delete = DeleteUserUseCase(auth, accounts)
        assertEquals(AppError.CannotManageAccount, assertFailsWith<AppError> { disable(managed("1"), true) })
        assertEquals(AppError.CannotManageAccount, assertFailsWith<AppError> { delete(managed("5", admin = true)) })
        assertTrue(accounts.calls.isEmpty())

        disable(managed("3"), true)
        disable(managed("3"), false)
        delete(managed("3"))
        assertEquals(listOf("disable 3 true", "disable 3 false", "delete 3"), accounts.calls)
    }

    @Test fun loadUsersPages() = runTest {
        val accounts = FakeAccountAdminGateway().apply { repeat(3) { users += managed("${it + 2}") } }
        val page = LoadUsersUseCase(admin(), accounts)(offset = 0, limit = 2)
        assertEquals(listOf("2", "3"), page.users.map { it.id })
        assertTrue(page.hasMore)
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
        val moderation = FakeModerationGateway()
        val safety = ChatSafetyStore(InMemoryKeyValueStore())
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
                chatSafety = safety,
                moderation = moderation,
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

    @Test fun blockAndReportGoToTheServer() = runTest {
        val h = Harness(this, User("member", "Member"), roomHost = "host")
        h.moderation.remote += "spammer"
        h.session.start()
        runCurrent()
        h.chat.incoming.emit(ChatMessage(id = "1", roomId = "room1", senderId = "spammer", senderNickname = "S", text = "buy"))
        h.chat.incoming.emit(ChatMessage(id = "2", roomId = "room1", senderId = "carol", senderNickname = "Carol", text = "rude"))
        runCurrent()
        assertEquals(listOf("2"), h.session.state.value.messages.map { it.id })

        val rude = h.session.state.value.messages.single()
        h.session.report(rude)
        runCurrent()
        assertEquals(Triple("carol", "rude", "2"), h.moderation.reported.single())

        h.session.blockSender(rude)
        runCurrent()
        assertTrue(h.session.state.value.messages.isEmpty())
        assertTrue("carol" in h.moderation.remote)
        assertTrue(h.safety.pendingUploads("member").isEmpty())
        h.session.close()
    }
}

class ModerationUseCaseTest {
    @Test fun firstSyncUploadsLegacyLocalBlocksAndKeepsFailedOnesPending() = runTest {
        val safety = ChatSafetyStore(InMemoryKeyValueStore())
        val server = FakeModerationGateway().apply { remote += "fromOtherDevice" }
        safety.block("legacy", ownerId = "me")
        safety.markUploaded("legacy", ownerId = "me")

        val merged = SyncBlockListUseCase(server, safety)("me")
        assertEquals(setOf("legacy", "fromOtherDevice"), merged)
        assertTrue("legacy" in server.remote)

        server.failing = true
        BlockUserUseCase(server, safety)("offline", ownerId = "me")
        assertTrue(safety.isBlocked("offline", ownerId = "me"))
        assertEquals(setOf("offline"), safety.pendingUploads("me"))

        server.failing = false
        server.remote -= "legacy"
        SyncBlockListUseCase(server, safety)("me")
        assertEquals(setOf("fromOtherDevice", "offline"), safety.blockedUserIds("me"))
        assertTrue(safety.pendingUploads("me").isEmpty())
    }

    @Test fun reportListNeedsAdmin() = runTest {
        val server = FakeModerationGateway()
        val auth = FakeAuthGateway(User("u", "U"))
        assertIs<AppError.AdminRequired>(assertFailsWith<AppError> { LoadReportsUseCase(auth, server)(ReportFilter.PENDING) })
        auth.currentUser.value = User("root", "Root", isAdmin = true)
        LoadReportsUseCase(auth, server)(ReportFilter.PENDING)
        val report = UserReport(7, "a", "A", "root", "Root", false, "x", null, ReportStatus.PENDING, 0, null)
        assertIs<AppError.Validation>(assertFailsWith<AppError> { ResolveReportUseCase(auth, server)(report, ReportAction.BAN) })
        ResolveReportUseCase(auth, server)(report.copy(targetId = "b"), ReportAction.BAN)
        assertEquals(listOf(7L to ReportAction.BAN), server.resolved)
    }

    @Test fun reportUploadFailureSurfacesAsError() = runTest {
        val server = FakeModerationGateway().apply { failing = true }
        val message = ChatMessage(id = "1", roomId = "r", senderId = "x", senderNickname = "X", text = "")
        assertIs<AppError.ServerUnreachable>(assertFailsWith<AppError> { ReportMessageUseCase(server)(message) })
        server.failing = false
        ReportMessageUseCase(server)(message.copy(sticker = null))
        assertEquals("", server.reported.single().second)
    }
}
