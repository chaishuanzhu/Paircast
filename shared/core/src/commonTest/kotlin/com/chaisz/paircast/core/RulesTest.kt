package com.chaisz.paircast.core

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.VideoFormat
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackState
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleState
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.rules.AccountRules
import com.chaisz.paircast.core.rules.ChatStickerCodec
import com.chaisz.paircast.core.rules.ConfigValidation
import com.chaisz.paircast.core.rules.HostTransferRules
import com.chaisz.paircast.core.rules.LegalRules
import com.chaisz.paircast.core.rules.LoginRules
import com.chaisz.paircast.core.rules.PlaybackSyncRules
import com.chaisz.paircast.core.rules.PlaybackSyncRules.ApplyResult
import com.chaisz.paircast.core.rules.ProfileRules
import com.chaisz.paircast.core.rules.StringTemplate
import com.chaisz.paircast.core.store.ChatSafetyStore
import com.chaisz.paircast.core.store.InMemoryKeyValueStore
import com.chaisz.paircast.core.store.SubtitleOffsetStore
import com.chaisz.paircast.core.support.PaircastJson
import com.chaisz.paircast.core.support.Paths
import com.chaisz.paircast.core.support.Twemoji
import com.chaisz.paircast.core.usecase.InviteLinks
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal fun configFixture() = AppCloudConfig(im = IMConfig("https://im.example.com"))

internal fun roomFixture(host: String = "host1") = WatchRoom(id = "room1", movieId = "m1", hostUserId = host)

class LoginRulesTest {
    @Test fun emptyAccountFails() {
        assertFailsWith<AppError.Validation> { LoginRules.validateAccount("   ") }
    }

    @Test fun emptyPasswordFails() {
        assertFailsWith<AppError.Validation> { LoginRules.validatePassword("") }
    }

    @Test fun newPasswordRules() {
        assertFailsWith<AppError.Validation> { LoginRules.validateNewPassword("old", "short", "short") }
        assertFailsWith<AppError.Validation> { LoginRules.validateNewPassword("old", "abcdefg", "abcdefx") }
        assertFailsWith<AppError.Validation> { LoginRules.validateNewPassword("abcdefg", "abcdefg", "abcdefg") }
        LoginRules.validateNewPassword("old", "abcdefg", "abcdefg")
    }
}

class LegalRulesTest {
    @Test fun localizedPageUrls() {
        assertEquals("https://paircast.chaisz.com/zh-Hans/terms/", LegalRules.termsUrl(chinese = true))
        assertEquals("https://paircast.chaisz.com/en-US/privacy/", LegalRules.privacyUrl(chinese = false))
    }

    @Test fun agreementRequired() {
        LegalRules.requireAgreement(true)
        assertFailsWith<AppError.Validation> { LegalRules.requireAgreement(false) }
    }
}

class AccountRulesTest {
    @Test fun emailNormalizedAndValidated() {
        assertEquals("dana@example.com", AccountRules.normalizedEmail("  Dana@Example.COM "))
        assertFailsWith<AppError.Validation> { AccountRules.normalizedEmail("") }
        assertFailsWith<AppError.Validation> { AccountRules.normalizedEmail("dana@localhost") }
        assertFailsWith<AppError.Validation> { AccountRules.normalizedEmail("a b@c.de") }
    }

    @Test fun chosenPasswordBounds() {
        LoginRules.validateChosenPassword("secret", "secret")
        assertFailsWith<AppError.Validation> { LoginRules.validateChosenPassword("short", "short") }
        val long = "x".repeat(73)
        assertFailsWith<AppError.Validation> { LoginRules.validateChosenPassword(long, long) }
        assertFailsWith<AppError.Validation> { LoginRules.validateChosenPassword("secret1", "secret2") }
    }

    @Test fun blankNicknameIsOptional() {
        assertNull(AccountRules.normalizedNickname("   "))
        assertEquals("Dana", AccountRules.normalizedNickname(" Dana "))
    }
}

class ProfileRulesTest {
    @Test fun trimsAndValidates() = assertEquals("Alice", ProfileRules.validatedNickname("  Alice  "))

    @Test fun rejectsBlank() {
        assertFailsWith<AppError> { ProfileRules.validatedNickname("   ") }
    }

    @Test fun rejectsTooLong() {
        assertFailsWith<AppError> { ProfileRules.validatedNickname("a".repeat(17)) }
    }

    @Test fun countsEmojiAsOneCharacter() {
        assertEquals("😀".repeat(16), ProfileRules.validatedNickname("😀".repeat(16)))
    }

    @Test fun rejectsOversizedAvatar() {
        assertFailsWith<AppError> { ProfileRules.validatedAvatarData(ByteArray(ProfileRules.AVATAR_MAX_BYTES + 1)) }
    }
}

class ConfigValidationTest {
    @Test fun normalizesConfigServerUrl() {
        val normalized = ConfigValidation.normalized(AppCloudConfig(im = IMConfig(" im.example.com/ws ")))
        assertEquals("https://im.example.com", normalized.im.serverUrl)
        assertTrue(normalized.isComplete)
    }

    @Test fun normalizesServerUrl() {
        assertEquals("https://im.chaisz.com", ConfigValidation.normalizedServerUrl(" im.chaisz.com/ "))
        assertEquals("http://192.168.1.2:8080", ConfigValidation.normalizedServerUrl("http://192.168.1.2:8080/ws?x=1"))
        assertEquals("https://im.chaisz.com", ConfigValidation.normalizedServerUrl("wss://im.chaisz.com/ws"))
        assertNull(ConfigValidation.normalizedServerUrl("ftp://x"))
        assertNull(ConfigValidation.normalizedServerUrl("   "))
    }

    @Test fun missingServerIsReported() {
        val error = assertFailsWith<AppError.IncompleteConfig> {
            ConfigValidation.validate(configFixture().copy(im = IMConfig("")))
        }
        assertEquals(listOf("Server"), error.missing)
    }
}

class SubtitleStateTest {
    @Test fun clampsOffset() {
        var state = SubtitleState(movieId = "m")
        state = state.withOffsetDelta(40_000)
        assertEquals(30_000, state.offsetMs)
        state = state.withOffsetDelta(-100_000)
        assertEquals(-30_000, state.offsetMs)
    }

    @Test fun resetForMovieChange() {
        val state = SubtitleState.resetForMovieChange("new")
        assertEquals("new", state.movieId)
        assertEquals(SubtitleSource.OFF, state.source)
        assertEquals(0, state.offsetMs)
    }

    @Test fun offsetLabel() {
        assertEquals("+0.0s", SubtitleState(movieId = "m").offsetLabel)
        assertEquals("+1.5s", SubtitleState(movieId = "m", offsetMs = 1_500).offsetLabel)
        assertEquals("-0.3s", SubtitleState(movieId = "m", offsetMs = -300).offsetLabel)
    }
}

class PlaybackSyncRulesTest {
    private fun signal(action: PlaybackAction, position: Long, sender: String?, seq: Long, movieId: String? = null) =
        PlaybackSyncSignal(action = action, positionMs = position, movieId = movieId, senderId = sender, seq = seq)

    @Test fun staleSeqIgnored() {
        val room = roomFixture()
        val result = PlaybackSyncRules.shouldAccept(
            signal(PlaybackAction.PAUSE, 100, room.hostUserId, 5),
            room,
            PlaybackState(movieId = "m1", lastSeq = 5),
        )
        assertEquals(ApplyResult.Ignored(PlaybackSyncRules.IgnoreReason.STALE_SEQ), result)
    }

    @Test fun nonHostIgnored() {
        val result = PlaybackSyncRules.shouldAccept(
            signal(PlaybackAction.PLAY, 0, "intruder", 2),
            roomFixture(),
            PlaybackState(movieId = "m1", lastSeq = 1),
        )
        assertEquals(ApplyResult.Ignored(PlaybackSyncRules.IgnoreReason.NON_HOST), result)
    }

    @Test fun endedRoomIgnored() {
        val result = PlaybackSyncRules.shouldAccept(
            signal(PlaybackAction.PLAY, 0, "host1", 2),
            roomFixture().copy(status = RoomStatus.ENDED),
            PlaybackState(movieId = "m1", lastSeq = 1),
        )
        assertEquals(ApplyResult.Ignored(PlaybackSyncRules.IgnoreReason.ROOM_ENDED), result)
    }

    @Test fun hostPlayApplied() {
        val room = roomFixture()
        val result = assertIs<ApplyResult.Applied>(
            PlaybackSyncRules.shouldAccept(
                signal(PlaybackAction.PLAY, 1500, room.hostUserId, 2),
                room,
                PlaybackState(movieId = "m1", lastSeq = 1),
            ),
        )
        assertTrue(result.seek)
        assertFalse(result.state.isPaused)
        assertEquals(1500, result.state.positionMs)
        assertEquals(2, result.state.lastSeq)
    }

    @Test fun heartbeatWithinThresholdDoesNotSeekAgainstLiveClock() {
        val room = roomFixture()
        val result = assertIs<ApplyResult.Applied>(
            PlaybackSyncRules.shouldAccept(
                signal(PlaybackAction.HEARTBEAT, 6_000, room.hostUserId, 2),
                room,
                PlaybackState(positionMs = 1000, isPaused = false, movieId = "m1", lastSeq = 1),
                localPositionMs = 5_500,
            ),
        )
        assertFalse(result.seek)
        assertEquals(6_000, result.state.positionMs)
    }

    @Test fun heartbeatBeyondThresholdSeeksAgainstLiveClock() {
        val room = roomFixture()
        val result = assertIs<ApplyResult.Applied>(
            PlaybackSyncRules.shouldAccept(
                signal(PlaybackAction.HEARTBEAT, 3000, room.hostUserId, 2),
                room,
                PlaybackState(positionMs = 1000, isPaused = false, movieId = "m1", lastSeq = 1),
                localPositionMs = 1000,
            ),
        )
        assertTrue(result.seek)
        assertEquals(3000, result.state.positionMs)
    }

    @Test fun heartbeatWithoutLocalClockUsesBookkeepingFallback() {
        val room = roomFixture()
        val result = assertIs<ApplyResult.Applied>(
            PlaybackSyncRules.shouldAccept(
                signal(PlaybackAction.HEARTBEAT, 1500, room.hostUserId, 2),
                room,
                PlaybackState(positionMs = 1000, isPaused = false, movieId = "m1", lastSeq = 1),
            ),
        )
        assertFalse(result.seek)
    }

    @Test fun movieChangeResetsPosition() {
        val room = roomFixture()
        val result = assertIs<ApplyResult.Applied>(
            PlaybackSyncRules.shouldAccept(
                signal(PlaybackAction.MOVIE_CHANGE, 0, room.hostUserId, 2, movieId = "m2"),
                room,
                PlaybackState(positionMs = 9999, isPaused = false, movieId = "m1", lastSeq = 1),
            ),
        )
        assertTrue(result.seek)
        assertEquals("m2", result.state.movieId)
        assertEquals(0, result.state.positionMs)
        assertTrue(result.state.isPaused)
    }

    @Test fun subtitleChangeAdvancesSeqWithoutSeek() {
        val room = roomFixture()
        val result = assertIs<ApplyResult.Applied>(
            PlaybackSyncRules.shouldAccept(
                PlaybackSyncSignal(
                    action = PlaybackAction.SUBTITLE_CHANGE,
                    positionMs = 4_200,
                    movieId = "m1",
                    senderId = room.hostUserId,
                    seq = 4,
                    subtitleObjectKey = "films/Inception.2010.srt",
                    subtitleLabel = "简体中文",
                ),
                room,
                PlaybackState(positionMs = 4_200, isPaused = false, movieId = "m1", lastSeq = 3),
            ),
        )
        assertFalse(result.seek)
        assertEquals(4_200, result.state.positionMs)
        assertFalse(result.state.isPaused)
        assertEquals(4, result.state.lastSeq)
    }

    @Test fun hostTransferUsesRoomTransferSeq() {
        val room = roomFixture().copy(hostTransferSeq = 3)
        val transfer = PlaybackSyncSignal(
            action = PlaybackAction.HOST_TRANSFER,
            positionMs = 10,
            hostUserId = "b",
            senderId = "host1",
            seq = 4,
        )
        val applied = assertIs<ApplyResult.Applied>(
            PlaybackSyncRules.shouldAccept(transfer, room, PlaybackState(movieId = "m1", lastSeq = 50)),
        )
        assertTrue(applied.state.isPaused)
        assertEquals(50, applied.state.lastSeq)
        assertEquals(
            ApplyResult.Ignored(PlaybackSyncRules.IgnoreReason.STALE_SEQ),
            PlaybackSyncRules.shouldAccept(transfer.copy(seq = 3), room, PlaybackState(movieId = "m1")),
        )
    }

    @Test fun signalJsonWireFormat() {
        val json = PaircastJson.default.encodeToString(
            PlaybackSyncSignal.serializer(),
            PlaybackSyncSignal(action = PlaybackAction.MOVIE_CHANGE, positionMs = 0, movieId = "m2", seq = 7),
        )
        assertTrue("\"action\":\"movie_change\"" in json, json)
        assertFalse("subtitleObjectKey" in json, json)
        val back = PaircastJson.default.decodeFromString(PlaybackSyncSignal.serializer(), json)
        assertEquals("m2", back.movieId)
    }
}

class HostTransferRulesTest {
    @Test fun hostLeaveTransfersToNextJoinOrder() {
        val room = roomFixture("a").copy(memberIds = listOf("a", "b", "c"), joinOrder = listOf("a", "b", "c"))
        val outcome = assertIs<HostTransferRules.Outcome.Transfer>(HostTransferRules.resolveLeave(room, "a", 10))
        assertEquals("b", outcome.newHostUserId)
        assertEquals("b", outcome.room.hostUserId)
        assertEquals(10, outcome.room.hostTransferSeq)
        assertFalse("a" in outcome.room.memberIds)
    }

    @Test fun lastMemberEndsRoom() {
        val outcome = assertIs<HostTransferRules.Outcome.EndRoom>(
            HostTransferRules.resolveLeave(roomFixture("solo"), "solo", 1),
        )
        assertEquals(RoomStatus.ENDED, outcome.room.status)
    }

    @Test fun memberLeaveKeepsHost() {
        val room = roomFixture("a").copy(memberIds = listOf("a", "b"), joinOrder = listOf("a", "b"))
        val outcome = assertIs<HostTransferRules.Outcome.MemberLeft>(HostTransferRules.resolveLeave(room, "b", 1))
        assertEquals("a", outcome.room.hostUserId)
        assertEquals(listOf("a"), outcome.room.memberIds)
    }

    @Test fun endedRoomUnchanged() {
        assertEquals(
            HostTransferRules.Outcome.Unchanged,
            HostTransferRules.resolveLeave(roomFixture().copy(status = RoomStatus.ENDED), "host1", 1),
        )
    }
}

class StoresTest {
    @Test fun blockHidesOtherUsersMessages() {
        val store = ChatSafetyStore(InMemoryKeyValueStore())
        store.block("bob", ownerId = "alice")
        assertTrue(store.isBlocked("bob", ownerId = "alice"))
        val visible = store.visibleMessages(
            listOf(
                ChatMessage(id = "1", roomId = "r", senderId = "bob", senderNickname = "Bob", text = "hi"),
                ChatMessage(id = "2", roomId = "r", senderId = "alice", senderNickname = "Alice", text = "hey"),
                ChatMessage(id = "3", roomId = "r", senderNickname = "System", text = "joined", kind = ChatMessageKind.SYSTEM),
            ),
            ownerId = "alice",
        )
        assertEquals(listOf("2", "3"), visible.map { it.id })
    }

    @Test fun cannotBlockSelf() {
        val store = ChatSafetyStore(InMemoryKeyValueStore())
        store.block("alice", ownerId = "alice")
        assertTrue(store.blockedUserIds("alice").isEmpty())
    }

    @Test fun subtitleOffsetPersistsClamped() {
        val offsets = SubtitleOffsetStore(InMemoryKeyValueStore())
        assertEquals(0, offsets.load("m"))
        offsets.save("m", 99_000)
        assertEquals(30_000, offsets.load("m"))
        offsets.clear("m")
        assertEquals(0, offsets.load("m"))
    }
}

class MiscTest {
    @Test fun replacesNamedPlaceholders() {
        assertEquals(
            "Host is now Alice (host)",
            StringTemplate.apply("Host is now {{name}} ({{role}})", mapOf("name" to "Alice", "role" to "host")),
        )
    }

    @Test fun incompleteConfigUserMessage() {
        val error = AppError.IncompleteConfig(listOf("Bucket", "Endpoint"))
        assertEquals("Incomplete configuration: {{fields}}", error.localizationKey)
        assertEquals("Incomplete configuration: Bucket, Endpoint", error.userMessage)
        assertEquals("This room has ended", AppError.RoomEnded.localizationKey)
    }

    @Test fun stickerCodecRoundTripAndLegacyPrefix() {
        val ref = StickerRef(packId = "cats", stickerId = "001", format = "gif", file = "001.gif")
        val json = ChatStickerCodec.encodeJson(ref)
        assertTrue("\"pack_id\":\"cats\"" in json)
        assertEquals(ref, ChatStickerCodec.decode(json))
        assertEquals(ref, ChatStickerCodec.decode(ChatStickerCodec.encode(ref)))
        assertNull(ChatStickerCodec.decode("hello"))
    }

    @Test fun moviePlaceholderFromServerId() {
        val movie = Movie.placeholder("oss:films/Inception.2010.mkv")
        assertEquals("oss", movie.sourceId)
        assertEquals("Inception.2010", movie.title)
        assertEquals(VideoFormat.MKV, movie.format)
        val legacy = Movie.placeholder("films/a.mp4")
        assertNull(legacy.sourceId)
        assertEquals(VideoFormat.MP4, legacy.format)
    }

    @Test fun paths() {
        assertEquals("mkv", Paths.pathExtension("a/b.c.mkv"))
        assertEquals("", Paths.pathExtension("a/.hidden"))
        assertEquals("a/b.c", Paths.deletingPathExtension("a/b.c.mkv"))
        assertEquals("b.c.mkv", Paths.lastPathComponent("a/b.c.mkv"))
    }

    @Test fun twemojiCodepoints() {
        assertEquals("2764", Twemoji.codepoints("❤️"))
        assertEquals("1f600", Twemoji.codepoints("😀"))
        assertEquals("1f468-200d-1f4bb", Twemoji.codepoints("👨‍💻"))
    }

    @Test fun inviteUrlEncodesQuery() {
        val url = InviteLinks.inviteUrl("r1", "films/a b.mkv", "100001", "小明", "A&B")
        assertTrue(url.startsWith("https://paircast.chaisz.com/invite/?roomId=r1&"))
        assertTrue("movieId=films%2Fa%20b.mkv" in url)
        assertTrue("title=A%26B" in url)
    }
}
