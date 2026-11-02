package com.chaisz.paircast.core

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ChatMessage
import com.chaisz.paircast.core.model.ChatMessageKind
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.MovieMetadataObjectKey
import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.core.model.ObjectStorageProvider
import com.chaisz.paircast.core.model.PlaybackAction
import com.chaisz.paircast.core.model.PlaybackState
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.SharedSubtitleObjectKey
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.StickersObjectKey
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleState
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.core.rules.ChatStickerCodec
import com.chaisz.paircast.core.rules.ConfigQRCodec
import com.chaisz.paircast.core.rules.ConfigValidation
import com.chaisz.paircast.core.rules.HostTransferRules
import com.chaisz.paircast.core.rules.LoginRules
import com.chaisz.paircast.core.rules.MovieCatalogRules
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

internal fun configFixture() = AppCloudConfig(
    im = IMConfig("https://im.example.com"),
    storage = ObjectStorageConfig(accessKey = "ak", secretKey = "sk", bucket = "movies", endpoint = "s3-cn-east-1.qiniucs.com"),
    tmdbAccessToken = "tmdb-token",
)

internal fun roomFixture(host: String = "host1") = WatchRoom(id = "room1", movieId = "m1", hostUserId = host)

class MovieCatalogRulesTest {
    @Test fun filtersOnlySupportedVideoExtensions() {
        val keys = listOf("a.mp4", "b.mkv", "c.avi", "d.srt", "folder/e.MP4", "f.m4v")
        assertEquals(listOf("a.mp4", "b.mkv", "folder/e.MP4", "f.m4v"), MovieCatalogRules.filterVideoKeys(keys))
    }

    @Test fun parseFilenameWithYear() {
        val parsed = MovieCatalogRules.parseFilenameMetadata("films/Inception.2010.1080p.mkv")
        assertEquals("Inception", parsed.title)
        assertEquals("2010", parsed.year)
    }

    @Test fun parseFilenameWithParenthesizedYear() {
        val parsed = MovieCatalogRules.parseFilenameMetadata("画江湖之天罡 (2023).mkv")
        assertEquals("画江湖之天罡", parsed.title)
        assertEquals("2023", parsed.year)
    }

    @Test fun parseFilenameWithFullwidthParentheses() {
        val parsed = MovieCatalogRules.parseFilenameMetadata("流浪地球（2019）.mp4")
        assertEquals("流浪地球", parsed.title)
        assertEquals("2019", parsed.year)
    }

    @Test fun parseFilenameWithoutYear() {
        val parsed = MovieCatalogRules.parseFilenameMetadata("my-movie.mp4")
        assertEquals("my-movie", parsed.title)
        assertNull(parsed.year)
    }
}

class ConfigQRCodecTest {
    @Test fun roundTrip() {
        val config = configFixture()
        val decoded = ConfigQRCodec.decode(ConfigQRCodec.encode(config))
        assertEquals(config.im.serverUrl, decoded.im.serverUrl)
        assertEquals(config.storage.bucket, decoded.storage.bucket)
        assertEquals(config.tmdbAccessToken, decoded.tmdbAccessToken)
        assertEquals(4, decoded.configVersion)
    }

    @Test fun invalidTypeDoesNotDecode() {
        val raw = """{"v":4,"type":"other","im":{"serverUrl":"https://im"},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"c","endpoint":"d","useSSL":true,"forcePathStyle":true}}"""
        assertEquals(AppError.InvalidConfigQR, assertFailsWith<AppError> { ConfigQRCodec.decode(raw) })
    }

    @Test fun roundTripPreservesProviderAndFlags() {
        val config = AppCloudConfig(
            im = IMConfig("http://192.168.1.2:8080"),
            storage = ObjectStorageConfig(
                provider = ObjectStorageProvider.MINIO,
                accessKey = "a",
                secretKey = "b",
                bucket = "bucket",
                endpoint = "minio.local:9000",
                region = "us-east-1",
                useSSL = false,
                forcePathStyle = true,
            ),
        )
        val decoded = ConfigQRCodec.decode(ConfigQRCodec.encode(config))
        assertEquals(ObjectStorageProvider.MINIO, decoded.storage.provider)
        assertEquals("minio.local:9000", decoded.storage.endpoint)
        assertFalse(decoded.storage.useSSL)
        assertTrue(decoded.storage.forcePathStyle)
    }

    @Test fun tooLargeRejected() {
        val config = configFixture().copy(subtitleApiKey = "x".repeat(3_000))
        assertEquals(AppError.ConfigQRTooLarge, assertFailsWith<AppError> { ConfigQRCodec.encode(config) })
    }

    @Test fun legacyV3PayloadKeepsStorageButNeedsServer() {
        val raw = """{"v":3,"type":"paircast-config","im":{"sdkAppId":1,"secretKey":"x"},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"c","endpoint":"s3.cn-south-1.qiniucs.com","useSSL":true,"forcePathStyle":true},"tmdbAccessToken":"t"}"""
        val decoded = ConfigQRCodec.decode(raw)
        assertEquals(3, decoded.configVersion)
        assertEquals("c", decoded.storage.bucket)
        assertEquals("t", decoded.tmdbAccessToken)
        assertTrue(ConfigQRCodec.needsServerUrl(decoded))
    }

    @Test fun decodesV2PayloadWithoutTMDBToken() {
        val raw = """{"v":2,"type":"tandem-config","im":{"sdkAppId":1,"secretKey":"x"},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"c","endpoint":"s3.cn-south-1.qiniucs.com","useSSL":true,"forcePathStyle":true}}"""
        val decoded = ConfigQRCodec.decode(raw)
        assertEquals(2, decoded.configVersion)
        assertNull(decoded.tmdbAccessToken)
    }

    @Test fun rejectsV1Payload() {
        val raw = """{"v":1,"type":"tandem-config","im":{"sdkAppId":1,"secretKey":"x"},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"c","endpoint":"s3.cn-south-1.qiniucs.com","useSSL":true,"forcePathStyle":true}}"""
        assertEquals(AppError.InvalidConfigQR, assertFailsWith<AppError> { ConfigQRCodec.decode(raw) })
    }

    @Test fun v4WithoutServerRejected() {
        val raw = """{"v":4,"type":"paircast-config","im":{},"storage":{"provider":"qiniu","accessKey":"a","secretKey":"b","bucket":"c","endpoint":"s3.cn-south-1.qiniucs.com","useSSL":true,"forcePathStyle":true}}"""
        assertEquals(AppError.InvalidConfigQR, assertFailsWith<AppError> { ConfigQRCodec.decode(raw) })
    }
}

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
    @Test fun rejectsCustomDomainAsEndpoint() {
        val config = configFixture().copy(
            storage = ObjectStorageConfig(accessKey = "a", secretKey = "b", bucket = "c", endpoint = "https://qiniu.chaisz.com"),
        )
        val error = assertFailsWith<AppError.Validation> { ConfigValidation.validate(config) }
        assertTrue("Endpoint" in error.key)
    }

    @Test fun normalizesEndpointScheme() {
        val config = configFixture().copy(
            storage = ObjectStorageConfig(accessKey = "a", secretKey = "b", bucket = "c", endpoint = "https://s3.cn-south-1.qiniucs.com/"),
        )
        assertEquals("s3.cn-south-1.qiniucs.com", ConfigValidation.normalized(config).storage.endpoint)
    }

    @Test fun acceptsAliyunOSSEndpoint() {
        val config = configFixture().copy(
            storage = ObjectStorageConfig(
                provider = ObjectStorageProvider.ALIYUN_OSS,
                accessKey = "a",
                secretKey = "b",
                bucket = "c",
                endpoint = "https://oss-cn-hangzhou.aliyuncs.com/",
            ),
        )
        val normalized = ConfigValidation.normalized(config)
        assertEquals("oss-cn-hangzhou.aliyuncs.com", normalized.storage.endpoint)
        assertEquals("cn-hangzhou", normalized.storage.signingRegion)
    }

    @Test fun acceptsTencentCOSAndMinio() {
        val cos = ConfigValidation.normalizedStorage(
            ObjectStorageConfig(ObjectStorageProvider.TENCENT_COS, "a", "b", "c", "cos.ap-guangzhou.myqcloud.com"),
        )
        assertEquals("ap-guangzhou", cos.signingRegion)
        val minio = ConfigValidation.normalizedStorage(
            ObjectStorageConfig(ObjectStorageProvider.MINIO, "a", "b", "c", "192.168.1.10:9000", useSSL = false),
        )
        assertEquals("192.168.1.10:9000", minio.endpoint)
        assertEquals("us-east-1", minio.signingRegion)
        assertFalse(minio.useSSL)
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
        assertEquals(listOf("IM Server"), error.missing)
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

    @Test fun objectKeys() {
        assertEquals("films/Inception.2010.srt", SharedSubtitleObjectKey.sidecarKey("films/Inception.2010.mkv", "SRT"))
        assertNull(SharedSubtitleObjectKey.sidecarKey("_paircast/rooms/x.mkv", "srt"))
        assertTrue(SharedSubtitleObjectKey.isValid("films/a.ass"))
        assertFalse(SharedSubtitleObjectKey.isValid("_paircast/avatars/a.srt"))
        assertEquals("films/Foo.2010-poster.jpg", MovieMetadataObjectKey.posterKey("films/Foo.2010.mkv"))
        assertEquals("films/Foo.2010.nfo", MovieMetadataObjectKey.nfoKey("films/Foo.2010.mkv"))
        assertEquals("media/stickers/cats/pack.json", StickersObjectKey.packManifestKey("cats", "/media"))
        assertEquals("stickers/c_t/a_b.png", StickersObjectKey.assetKey("c t", "a/b.png", null))
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
