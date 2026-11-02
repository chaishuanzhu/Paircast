package com.chaisz.paircast.data

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.core.model.ObjectStorageProvider
import com.chaisz.paircast.core.model.RoomStatus
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.WatchRoom
import com.chaisz.paircast.data.config.ConfigShareLink
import com.chaisz.paircast.data.metadata.CascadingMetadataGateway
import com.chaisz.paircast.data.metadata.MovieNfoCodec
import com.chaisz.paircast.data.rooms.OssRoomStore
import com.chaisz.paircast.data.s3.S3CompatibleUrl
import com.chaisz.paircast.data.s3.S3ErrorResponse
import com.chaisz.paircast.data.s3.S3ListObjectsV2Parser
import com.chaisz.paircast.data.s3.S3Url
import com.chaisz.paircast.data.s3.SigV4
import com.chaisz.paircast.data.subtitles.OpenSubtitlesGateway
import com.chaisz.paircast.data.subtitles.SubtitleEncodingNormalizer
import com.chaisz.paircast.data.support.PaircastLog
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant

class SigV4Test {
    // AWS S3 SigV4 documentation examples.
    private val accessKey = "AKIAIOSFODNN7EXAMPLE"
    private val secretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    private val date = Instant.parse("2013-05-24T00:00:00Z")
    private val url = S3Url("https", "examplebucket.s3.amazonaws.com", null, "/test.txt")

    @Test
    fun headerSignatureMatchesAwsExample() {
        val signed = SigV4.signHeader(
            method = "GET",
            url = url,
            region = "us-east-1",
            accessKey = accessKey,
            secretKey = secretKey,
            headers = mapOf("Range" to "bytes=0-9"),
            now = date,
        )
        assertEquals(
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
                "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " +
                "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
            signed.headers["Authorization"],
        )
    }

    @Test
    fun presignMatchesAwsExample() {
        val presigned = SigV4.presignGet(url, "us-east-1", accessKey, secretKey, expiresSeconds = 86400, now = date)
        assertEquals(
            "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
            presigned.query.first { it.first == "X-Amz-Signature" }.second,
        )
        assertTrue(presigned.toString().startsWith("https://examplebucket.s3.amazonaws.com/test.txt?"))
    }

    @Test
    fun uriEncodeIsAsciiUnreserved() {
        assertEquals("a%20b%28%29~%E4%B8%AD", SigV4.uriEncode("a b()~中"))
        assertEquals("a/b", SigV4.uriEncode("a/b", encodeSlash = false))
    }

    @Test
    fun objectUrlPathStyleWithPort() {
        val storage = ObjectStorageConfig(ObjectStorageProvider.MINIO, "ak", "sk", "movies", "minio.local:9000")
        val u = S3CompatibleUrl.objectUrl("films/Foo (2010).mkv", storage)
        assertEquals("http://minio.local:9000/movies/films/Foo%20%282010%29.mkv", u.toString())
        assertEquals("minio.local:9000", u.hostHeader)
    }

    @Test
    fun objectUrlVirtualHosted() {
        val storage = ObjectStorageConfig(ObjectStorageProvider.QINIU, "ak", "sk", "b", "s3.cn-east-1.qiniucs.com", forcePathStyle = false)
        assertEquals("https://b.s3.cn-east-1.qiniucs.com/a/b.mp4", S3CompatibleUrl.objectUrl("a/b.mp4", storage).toString())
    }
}

class ParsersTest {
    @Test
    fun listPage() {
        val xml = """<?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <IsTruncated>true</IsTruncated>
              <Contents><Key>films/A &amp; B.mkv</Key><Size>1</Size></Contents>
              <Contents><Key>films/C.mp4</Key></Contents>
              <NextContinuationToken>tok==</NextContinuationToken>
            </ListBucketResult>"""
        val page = S3ListObjectsV2Parser.parsePage(xml)
        assertEquals(listOf("films/A & B.mkv", "films/C.mp4"), page.keys)
        assertTrue(page.isTruncated)
        assertEquals("tok==", page.nextContinuationToken)
    }

    @Test
    fun listError() {
        val e = assertFailsWith<S3ErrorResponse> {
            S3ListObjectsV2Parser.parsePage("<Error><Code>AccessDenied</Code><Message>no</Message></Error>")
        }
        assertEquals("AccessDenied", e.code)
    }

    @Test
    fun nfoRoundTrip() {
        val payload = MovieNfoCodec.Payload("Tom & Jerry <1>", "2010", "Plot \"x\"", "Foo-poster.jpg", "Foo-fanart.jpg")
        assertEquals(payload, MovieNfoCodec.decode(MovieNfoCodec.encode(payload)))
    }

    @Test
    fun nfoWithoutTitleIsNull() {
        assertNull(MovieNfoCodec.decode("<movie><year>2010</year></movie>"))
    }

    @Test
    fun redactsSignatures() {
        val redacted = PaircastLog.redactedUrl("https://h/p?X-Amz-Signature=abc&X-Amz-Expires=60&token=t")
        assertEquals("https://h/p?X-Amz-Signature=<redacted>&X-Amz-Expires=60&token=<redacted>", redacted)
    }
}

class ShareLinkTest {
    private val config = AppCloudConfig(
        im = IMConfig("https://im.example.com"),
        storage = ObjectStorageConfig(ObjectStorageProvider.MINIO, "AK_TEST", "SK_TEST", "movies", "minio.local:9000", useSSL = false),
    )

    @Test
    fun roundTripAndPaste() {
        val url = ConfigShareLink.shareUrl(config)
        assertTrue(url.startsWith("paircast://config?args="))
        assertEquals(config.storage, ConfigShareLink.decode(url).storage)
        assertEquals("https://im.example.com", ConfigShareLink.decode("给你配置：$url 打开即可").im.serverUrl)
    }

    /** Sealed by the Swift (CryptoKit) 1.x app with dummy credentials. */
    @Test
    fun decodesLegacyCryptoKitLink() {
        val args = "KyiwVh2UPRGtuUsjqHj3p3kCeJBEzwGO4kIQ58eR83zooERMWIi5SomJgdtXnBm_4YtZIJxTtEN0iJU0DRxZWOlMfGxIOOnqycp7e_kMwdhu9xaTh40HKrwtAxXyxTcyonqhLltTF4-proGY43dYvHx8otz2Py2dSpO6Mp3LQdwaQo9ZlgkhZUU-wPvZ3jGyWPycxyspoe1vK2y3MqDgZWFu6tCjhG7JeyTm2qF6UfEc85infL_Vfnyc4FZlAXLI7HzJOidcM1Qu8YgDHevZzT8gAA_4KUBsAMdDe66gJz8WUcHyxL6l2CUeMr47YGvi-Kb52SGDo5HVnJg5Y_0X2dYCV0z8G2rq-cOqkjmL9t494Y73"
        val decoded = ConfigShareLink.decode("paircast://config?args=$args")
        assertEquals("movies", decoded.storage.bucket)
        assertEquals("", decoded.im.serverUrl)
        assertFalse(decoded.im.isComplete)
    }

    @Test
    fun rejectsGarbage() {
        assertFailsWith<AppError.InvalidConfigQR> { ConfigShareLink.decode("paircast://config?args=AAAA") }
    }
}

class MiscDataTest {
    @Test
    fun reconcileRejectsStaleAndAcceptsLegacySuperset() {
        val cached = WatchRoom("r", "m", "h", memberIds = listOf("h", "a"), revision = 5)
        assertNull(OssRoomStore.reconciled(cached.copy(memberIds = listOf("h"), revision = 3), cached))
        val legacy = OssRoomStore.reconciled(cached.copy(memberIds = listOf("h", "a", "b"), revision = 0), cached)
        assertEquals(5, legacy?.revision)
        assertEquals(6, OssRoomStore.reconciled(cached.copy(revision = 6, status = RoomStatus.ENDED), cached)?.revision)
    }

    @Test
    fun sidecarMatching() {
        val keys = listOf("f/Foo.mkv", "f/Foo.srt", "f/Foo.zh.ass", "f/Foobar.srt", "f/Foo-en.vtt", "f/Bar.srt")
        assertEquals(listOf("f/Foo.srt", "f/Foo.zh.ass", "f/Foo-en.vtt"), OpenSubtitlesGateway.matchingSidecarKeys(keys, "f/Foo.mkv"))
        val track = SubtitleTrack("oss:f/Foo.srt", "x", source = SubtitleSource.OSS)
        assertEquals("f/Foo.srt", OpenSubtitlesGateway.ossObjectKey(track))
    }

    @Test
    fun tmdbHelpers() {
        assertEquals("https://image.tmdb.org/t/p/w500/a.jpg", CascadingMetadataGateway.tmdbImageUrl("/a.jpg", "w500"))
        assertNull(CascadingMetadataGateway.tmdbImageUrl("a.jpg", "w500"))
        assertEquals("zh-CN", CascadingMetadataGateway.tmdbLanguageFor("zh-Hans-CN"))
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
