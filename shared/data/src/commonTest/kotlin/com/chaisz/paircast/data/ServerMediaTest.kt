package com.chaisz.paircast.data

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.PlaybackSyncSignal
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.VideoFormat
import com.chaisz.paircast.core.store.InMemorySecureStore
import com.chaisz.paircast.data.goim.GoImApi
import com.chaisz.paircast.data.goim.GoImAuthGateway
import com.chaisz.paircast.data.goim.GoImConnection
import com.chaisz.paircast.data.goim.GoImHttpException
import com.chaisz.paircast.data.goim.PaircastSignal
import com.chaisz.paircast.data.goim.SignalCodec
import com.chaisz.paircast.data.media.ServerCatalogGateway
import com.chaisz.paircast.data.media.ServerMediaApi
import com.chaisz.paircast.data.media.ServerRoomGateway
import com.chaisz.paircast.data.media.SubtitleRefDto
import com.chaisz.paircast.data.media.toTrack
import com.chaisz.paircast.data.net.createHttpClient
import com.chaisz.paircast.data.secure.SecureConfigStore
import com.chaisz.paircast.data.secure.SessionStore
import com.chaisz.paircast.data.subtitles.SubtitleEncodingNormalizer
import com.chaisz.paircast.data.support.PaircastLog
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull

class ServerMediaTest {
    private val json = headersOf(HttpHeaders.ContentType, "application/json")
    private val config = AppCloudConfig(im = IMConfig("https://im.example.com"))

    private class Harness(val api: ServerMediaApi, val connection: GoImConnection, val requests: List<HttpRequestData>, val scope: CoroutineScope)

    private suspend fun harness(handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData): Harness {
        val requests = mutableListOf<HttpRequestData>()
        val client = createHttpClient(
            MockEngine { req ->
                if (req.url.encodedPath == "/account/login") {
                    respond(
                        """{"uid":"u1","token":"pc","nickname":"alice","must_change_password":true,"im":{"token":"jwt"}}""",
                        HttpStatusCode.OK,
                        headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                } else {
                    requests += req
                    handler(req)
                }
            },
        )
        val store = InMemorySecureStore()
        SecureConfigStore(store).save(config)
        val goim = GoImApi(client)
        val scope = CoroutineScope(SupervisorJob())
        val connection = GoImConnection(client, goim, scope, deviceId = "dev", platform = "test")
        val auth = GoImAuthGateway(SecureConfigStore(store), SessionStore(store), goim, connection)
        auth.login("alice", "pw")
        return Harness(ServerMediaApi(client, goim, auth), connection, requests, scope)
    }

    @Test
    fun listsAllPagesAndMapsItems() = runTest {
        val h = harness { req ->
            val page = if (req.url.parameters["cursor"] == null) {
                """{"items":[{"id":"oss:films/A.mkv","source_id":"oss","title":"A","year":"2010","format":"mkv"}],"next_cursor":"c1"}"""
            } else {
                """{"items":[{"id":"oss:films/B.mp4","source_id":"oss","title":"","poster_url":"https://p/b.jpg"}]}"""
            }
            respond(page, HttpStatusCode.OK, json)
        }
        val movies = ServerCatalogGateway(h.api).listMovies(config, "oss")
        assertEquals(listOf("oss:films/A.mkv", "oss:films/B.mp4"), movies.map { it.id })
        assertEquals(VideoFormat.MKV, movies[0].format)
        assertEquals("B.mp4", movies[1].title)
        assertEquals("https://p/b.jpg", movies[1].posterUrl)
        assertEquals("oss", h.requests.first().url.parameters["source"])
        assertEquals("pc", h.requests.first().url.parameters["token"])
        h.scope.cancel()
    }

    @Test
    fun mapsServerStatusToAppErrors() = runTest {
        var status = HttpStatusCode.ServiceUnavailable
        val h = harness { respond("media library not configured", status) }
        assertFailsWith<AppError.MediaLibraryUnavailable> { h.api.sources() }
        status = HttpStatusCode.NotFound
        assertFailsWith<AppError.RoomNotFound> { h.api.joinRoom("abc") }
        assertFailsWith<AppError.PlaybackFailed> { h.api.play("oss:x.mp4") }
        status = HttpStatusCode.Gone
        assertFailsWith<AppError.RoomEnded> { h.api.joinRoom("abc") }
        status = HttpStatusCode.NotImplemented
        assertFailsWith<AppError.OnlineSubtitlesUnavailable> { h.api.searchSubtitles("x", null) }
        h.scope.cancel()
    }

    @Test
    fun forbiddenHostChangeMapsToHostOnly() {
        assertEquals(AppError.OnlyHostCanSwitchMovie, ServerMediaApi.mapError(GoImHttpException(403, "only the host can do this"), AppError.RoomNotFound))
        assertEquals(AppError.RoomNotFound, ServerMediaApi.mapError(GoImHttpException(403, "not a member"), AppError.RoomNotFound))
    }

    @Test
    fun enrichFallsBackToInputOnFailure() = runTest {
        val h = harness { respond("boom", HttpStatusCode.InternalServerError) }
        val movie = com.chaisz.paircast.core.model.Movie.placeholder("oss:films/A.mkv")
        assertEquals(movie, ServerCatalogGateway(h.api).enrich(movie, config))
        h.scope.cancel()
    }

    @Test
    fun parsesRoomUpdatedAndIgnoresOtherSignals() {
        val content = """{"type":"paircast.room_updated","data":{"group_id":"g_1","room":{"id":"r1","group_id":"g_1","movie_id":"oss:a.mp4","host_uid":"u2",""" +
            """"members":["u1","u2"],"join_order":["u1","u2"],"status":"active","last_applied_seq":3,"host_transfer_seq":9,""" +
            """"subtitle_ref":"blob:paircast/subtitles/r1/x.srt","subtitle_label":"ZH","revision":7,"created_at":1,"updated_at":2}}}"""
        val room = ServerRoomGateway.parseRoomUpdated(content)!!
        assertEquals("u2", room.hostUserId)
        assertEquals(7, room.revision)
        assertEquals(9, room.hostTransferSeq)
        assertEquals("g_1", room.groupId)
        assertEquals("blob:paircast/subtitles/r1/x.srt", room.subtitleRef)
        assertEquals(RoomStatus.ACTIVE, room.status)
        assertNull(ServerRoomGateway.parseRoomUpdated("""{"type":"paircast.playback","data":{"action":"play","positionMs":1,"seq":2}}"""))
        assertNull(ServerRoomGateway.parseRoomUpdated("""{"type":"room_updated","room":{"id":"r1"}}"""))
        // The playback channel shares CmdSignal; room snapshots must not decode as playback signals.
        assertNull(SignalCodec.decode(content, PaircastSignal.PLAYBACK, PlaybackSyncSignal.serializer()))
    }

    @Test
    fun subtitleRefsBecomeTracksKeyedByRef() {
        val track = SubtitleRefDto(ref = "src:oss:films/A.zh.srt", label = "ZH (sidecar)", language = "zh", badge = "ZH", format = "SRT", origin = "sidecar")
            .toTrack(SubtitleSource.LIBRARY)
        assertEquals("src:oss:films/A.zh.srt", track.id)
        assertEquals(track.id, track.url)
        assertEquals("ZH", track.languageBadge)
        val unnamed = SubtitleRefDto(ref = "blob:paircast/subtitles/r/abc.vtt").toTrack(SubtitleSource.LIBRARY)
        assertEquals("abc.vtt", unnamed.label)
    }

    @Test
    fun configStorePurgesLegacyStorageKeys() = runTest {
        val store = InMemorySecureStore()
        store.write(
            SecureConfigStore.CONFIG_KEY,
            """{"serverUrl":"https://im.example.com","accessKey":"AK","secretKey":"SK","bucket":"b","endpoint":"e","updatedAtMs":5,"configVersion":4}""",
        )
        val loaded = SecureConfigStore(store).load()!!
        assertEquals("https://im.example.com", loaded.im.serverUrl)
        assertEquals(AppCloudConfig.CURRENT_VERSION, loaded.configVersion)
        val raw = store.read(SecureConfigStore.CONFIG_KEY)!!
        assertFalse("SK" in raw)
        assertFalse("accessKey" in raw)
    }
}

class MiscDataTest {
    @Test
    fun redactsSignatures() {
        val redacted = PaircastLog.redactedUrl("https://h/p?X-Amz-Signature=abc&X-Amz-Expires=60&token=t")
        assertEquals("https://h/p?X-Amz-Signature=<redacted>&X-Amz-Expires=60&token=<redacted>", redacted)
    }

    @Test
    fun normalizesGb18030AndKeepsUtf8() {
        // "你好" in GB18030 followed by an SRT arrow.
        val gb = byteArrayOf(0xC4.toByte(), 0xE3.toByte(), 0xBA.toByte(), 0xC3.toByte()) + " -->".encodeToByteArray()
        assertEquals("你好 -->", SubtitleEncodingNormalizer.utf8Text(gb))
        assertEquals("中文 -->", SubtitleEncodingNormalizer.utf8Text("中文 -->".encodeToByteArray()))
        val withBom = SubtitleEncodingNormalizer.utf8BytesWithBom("a".encodeToByteArray())
        assertEquals(4, withBom.size)
    }
}
