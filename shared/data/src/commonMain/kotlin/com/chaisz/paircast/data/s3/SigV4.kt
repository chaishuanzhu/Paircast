package com.chaisz.paircast.data.s3

import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.core.rules.ConfigValidation
import dev.whyoleg.cryptography.CryptographyProvider
import dev.whyoleg.cryptography.algorithms.HMAC
import dev.whyoleg.cryptography.algorithms.SHA256
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlin.time.Clock
import kotlin.time.Instant

internal object Digest {
    private val provider by lazy { CryptographyProvider.Default }
    private val sha256 by lazy { provider.get(SHA256).hasher() }
    private val hmac by lazy { provider.get(HMAC) }

    fun sha256(bytes: ByteArray): ByteArray = sha256.hashBlocking(bytes)

    fun hmacSha256(key: ByteArray, message: ByteArray): ByteArray =
        hmac.keyDecoder(SHA256).decodeFromByteArrayBlocking(HMAC.Key.Format.RAW, key)
            .signatureGenerator()
            .generateSignatureBlocking(message)

    fun hex(bytes: ByteArray): String {
        val chars = CharArray(bytes.size * 2)
        bytes.forEachIndexed { i, b ->
            val v = b.toInt() and 0xFF
            chars[i * 2] = HEX[v ushr 4]
            chars[i * 2 + 1] = HEX[v and 0x0F]
        }
        return chars.concatToString()
    }

    private val HEX = "0123456789abcdef".toCharArray()
}

/**
 * S3 request URL with an already percent-encoded path; query pairs are raw (encoded on render).
 * Avoids generic URL types so the canonical path matches what we sign byte-for-byte.
 */
data class S3Url(
    val scheme: String,
    val host: String,
    val port: Int?,
    val encodedPath: String,
    val query: List<Pair<String, String>> = emptyList(),
) {
    val hostHeader: String get() = SigV4.hostHeaderValue(host, port, scheme)

    fun withQuery(pairs: List<Pair<String, String>>) = copy(query = pairs)

    override fun toString(): String {
        val authority = if (port != null) "$host:$port" else host
        val q = if (query.isEmpty()) "" else "?" + SigV4.canonicalQueryPairs(query)
        return "$scheme://$authority$encodedPath$q"
    }
}

/** AWS Signature Version 4 signer for S3-compatible APIs. */
object SigV4 {
    const val EMPTY_PAYLOAD_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    data class SignedRequest(val url: S3Url, val headers: Map<String, String>, val method: String)

    fun signHeader(
        method: String,
        url: S3Url,
        region: String,
        accessKey: String,
        secretKey: String,
        headers: Map<String, String> = emptyMap(),
        payloadHash: String = EMPTY_PAYLOAD_HASH,
        now: Instant = Clock.System.now(),
        service: String = "s3",
    ): SignedRequest {
        val amzDate = amzDateString(now)
        val dateStamp = amzDate.take(8)
        val hostHeader = url.hostHeader

        val normalized = mutableMapOf<String, String>()
        headers.forEach { (k, v) -> normalized[k.lowercase()] = trimmedHeaderValue(v) }
        normalized["host"] = hostHeader
        normalized["x-amz-content-sha256"] = payloadHash
        normalized["x-amz-date"] = amzDate
        val names = normalized.keys.sorted()

        val canonicalHeaders = names.joinToString("") { "$it:${normalized.getValue(it)}\n" }
        val signedHeaders = names.joinToString(";")
        val canonicalRequest = listOf(
            method.uppercase(),
            url.encodedPath.ifEmpty { "/" },
            canonicalQueryPairs(url.query),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ).joinToString("\n")

        val scope = "$dateStamp/$region/$service/aws4_request"
        val stringToSign = listOf("AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(canonicalRequest)).joinToString("\n")
        val signature = Digest.hex(Digest.hmacSha256(signingKey(secretKey, dateStamp, region, service), stringToSign.encodeToByteArray()))
        val authorization = "AWS4-HMAC-SHA256 Credential=$accessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature"

        val out = linkedMapOf(
            "x-amz-content-sha256" to payloadHash,
            "x-amz-date" to amzDate,
            "Authorization" to authorization,
        )
        headers.forEach { (k, v) -> if (!k.equals("host", ignoreCase = true)) out[k] = v }
        return SignedRequest(url, out, method.uppercase())
    }

    /** Query-string presigned GET (signed header: host only, `UNSIGNED-PAYLOAD`). */
    fun presignGet(
        url: S3Url,
        region: String,
        accessKey: String,
        secretKey: String,
        expiresSeconds: Int = 6 * 3600,
        now: Instant = Clock.System.now(),
        service: String = "s3",
    ): S3Url {
        val amzDate = amzDateString(now)
        val dateStamp = amzDate.take(8)
        val scope = "$dateStamp/$region/$service/aws4_request"
        val items = mutableListOf(
            "X-Amz-Algorithm" to "AWS4-HMAC-SHA256",
            "X-Amz-Credential" to "$accessKey/$scope",
            "X-Amz-Date" to amzDate,
            "X-Amz-Expires" to expiresSeconds.toString(),
            "X-Amz-SignedHeaders" to "host",
        )
        items += url.query
        val canonicalRequest = listOf(
            "GET",
            url.encodedPath.ifEmpty { "/" },
            canonicalQueryPairs(items),
            "host:${url.hostHeader}\n",
            "host",
            "UNSIGNED-PAYLOAD",
        ).joinToString("\n")
        val stringToSign = listOf("AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(canonicalRequest)).joinToString("\n")
        val signature = Digest.hex(Digest.hmacSha256(signingKey(secretKey, dateStamp, region, service), stringToSign.encodeToByteArray()))
        items += "X-Amz-Signature" to signature
        return url.withQuery(items)
    }

    fun hostHeaderValue(host: String, port: Int?, scheme: String?): String {
        if (port == null) return host
        val s = (scheme ?: "https").lowercase()
        if (s == "https" && port == 443) return host
        if (s == "http" && port == 80) return host
        return "$host:$port"
    }

    fun amzDateString(instant: Instant): String {
        val t = instant.toLocalDateTime(TimeZone.UTC)
        fun p(v: Int, n: Int = 2) = v.toString().padStart(n, '0')
        return "${p(t.year, 4)}${p(t.month.ordinal + 1)}${p(t.day)}T${p(t.hour)}${p(t.minute)}${p(t.second)}Z"
    }

    fun canonicalQueryPairs(pairs: List<Pair<String, String>>): String =
        pairs.map { uriEncode(it.first) to uriEncode(it.second) }
            .sortedWith(compareBy<Pair<String, String>> { it.first }.thenBy { it.second })
            .joinToString("&") { "${it.first}=${it.second}" }

    /** AWS unreserved set is ASCII-only. */
    fun uriEncode(value: String, encodeSlash: Boolean = true): String {
        val sb = StringBuilder()
        for (byte in value.encodeToByteArray()) {
            val c = (byte.toInt() and 0xFF)
            val ch = c.toChar()
            val unreserved = ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~'
            if (unreserved || (!encodeSlash && ch == '/')) {
                sb.append(ch)
            } else {
                sb.append('%').append(HEX_UPPER[c ushr 4]).append(HEX_UPPER[c and 0x0F])
            }
        }
        return sb.toString()
    }

    fun sha256Hex(text: String): String = sha256Hex(text.encodeToByteArray())
    fun sha256Hex(bytes: ByteArray): String = Digest.hex(Digest.sha256(bytes))

    private fun trimmedHeaderValue(value: String) = value.trim().replace(Regex("\\s+"), " ")

    private fun signingKey(secretKey: String, dateStamp: String, region: String, service: String): ByteArray {
        val kDate = Digest.hmacSha256("AWS4$secretKey".encodeToByteArray(), dateStamp.encodeToByteArray())
        val kRegion = Digest.hmacSha256(kDate, region.encodeToByteArray())
        val kService = Digest.hmacSha256(kRegion, service.encodeToByteArray())
        return Digest.hmacSha256(kService, "aws4_request".encodeToByteArray())
    }

    private val HEX_UPPER = "0123456789ABCDEF".toCharArray()
}

/** Path-style (or virtual-hosted) object URLs for any S3-compatible provider. */
object S3CompatibleUrl {
    fun objectUrl(objectKey: String, storage: ObjectStorageConfig): S3Url {
        val (host, port) = splitHostPort(ConfigValidation.normalizedHost(storage.endpoint))
        val segments = objectKey.split('/').filter { it.isNotEmpty() }
        val scheme = if (storage.useSSL) "https" else "http"
        return if (storage.forcePathStyle) {
            S3Url(scheme, host, port, "/" + (listOf(storage.bucket) + segments).joinToString("/") { SigV4.uriEncode(it) })
        } else {
            S3Url(scheme, "${storage.bucket}.$host", port, "/" + segments.joinToString("/") { SigV4.uriEncode(it) })
        }
    }

    fun bucketUrl(storage: ObjectStorageConfig): S3Url {
        val (host, port) = splitHostPort(ConfigValidation.normalizedHost(storage.endpoint))
        val scheme = if (storage.useSSL) "https" else "http"
        return if (storage.forcePathStyle) {
            S3Url(scheme, host, port, "/" + SigV4.uriEncode(storage.bucket))
        } else {
            S3Url(scheme, "${storage.bucket}.$host", port, "/")
        }
    }

    internal fun splitHostPort(endpoint: String): Pair<String, Int?> {
        val idx = endpoint.lastIndexOf(':')
        if (idx > 0) {
            val port = endpoint.substring(idx + 1).toIntOrNull()
            if (port != null && port in 1..65535) return endpoint.substring(0, idx) to port
        }
        return endpoint to null
    }
}

data class S3ListPage(val keys: List<String>, val isTruncated: Boolean, val nextContinuationToken: String? = null)

class S3ErrorResponse(val code: String, override val message: String) : Exception("$code: $message")

/** Minimal ListObjectsV2 XML parser (`Contents/Key`, truncation, continuation, `<Error>`). */
object S3ListObjectsV2Parser {
    private val contents = Regex("<(?:\\w+:)?Contents\\b[^>]*>(.*?)</(?:\\w+:)?Contents>", RegexOption.DOT_MATCHES_ALL)
    private val error = Regex("<(?:\\w+:)?Error\\b[^>]*>(.*?)</(?:\\w+:)?Error>", RegexOption.DOT_MATCHES_ALL)

    fun parsePage(xml: String): S3ListPage {
        error.find(xml)?.let { m ->
            val body = m.groupValues[1]
            throw S3ErrorResponse(Xml.element(body, "Code").orEmpty(), Xml.element(body, "Message").orEmpty())
        }
        if (!xml.contains("ListBucketResult")) throw IllegalArgumentException("invalid listing XML")
        val keys = contents.findAll(xml).mapNotNull { Xml.element(it.groupValues[1], "Key")?.takeIf(String::isNotEmpty) }.toList()
        val stripped = contents.replace(xml, "")
        val truncated = Xml.element(stripped, "IsTruncated")?.lowercase().let { it == "true" || it == "1" }
        val next = Xml.element(stripped, "NextContinuationToken")?.takeIf { it.isNotEmpty() }
        return S3ListPage(keys, truncated, next)
    }
}

internal object Xml {
    fun element(xml: String, name: String): String? =
        Regex("<(?:\\w+:)?$name\\b[^>]*>(.*?)</(?:\\w+:)?$name>", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE))
            .find(xml)?.groupValues?.get(1)?.let { unescape(it).trim() }

    fun unescape(raw: String): String {
        var s = raw
        if (s.startsWith("<![CDATA[") && s.endsWith("]]>")) return s.removePrefix("<![CDATA[").removeSuffix("]]>")
        s = Regex("&#(x?)([0-9a-fA-F]+);").replace(s) { m ->
            val code = if (m.groupValues[1].isNotEmpty()) m.groupValues[2].toIntOrNull(16) else m.groupValues[2].toIntOrNull()
            code?.let { codePointToString(it) } ?: m.value
        }
        return s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
    }

    fun escape(raw: String): String =
        raw.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    private fun codePointToString(cp: Int): String =
        if (cp < 0x10000) cp.toChar().toString()
        else {
            val v = cp - 0x10000
            charArrayOf((0xD800 + (v shr 10)).toChar(), (0xDC00 + (v and 0x3FF)).toChar()).concatToString()
        }
}
