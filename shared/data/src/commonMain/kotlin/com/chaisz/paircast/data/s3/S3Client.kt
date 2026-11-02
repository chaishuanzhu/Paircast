package com.chaisz.paircast.data.s3

import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.data.support.PaircastLog
import io.ktor.client.HttpClient
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.http.ContentType
import io.ktor.http.HttpMethod
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.takeFrom
import kotlinx.coroutines.CancellationException

class S3Response(val status: Int, val body: ByteArray) {
    val isSuccess: Boolean get() = status in 200..299
}

/** Signed S3-compatible object IO shared by rooms, catalog, metadata, subtitles and stickers. */
class S3Client(private val http: HttpClient) {

    fun presignGet(objectKey: String, storage: ObjectStorageConfig, expiresSeconds: Int = DEFAULT_PRESIGN_SECONDS): String =
        SigV4.presignGet(
            url = S3CompatibleUrl.objectUrl(objectKey, storage),
            region = storage.signingRegion,
            accessKey = storage.accessKey,
            secretKey = storage.secretKey,
            expiresSeconds = expiresSeconds,
        ).toString()

    suspend fun get(objectKey: String, storage: ObjectStorageConfig): S3Response =
        send("GET", S3CompatibleUrl.objectUrl(objectKey, storage), storage)

    suspend fun getBytes(objectKey: String, storage: ObjectStorageConfig): ByteArray {
        val r = get(objectKey, storage)
        if (!r.isSuccess) throw AppError.Network
        return r.body
    }

    suspend fun exists(objectKey: String, storage: ObjectStorageConfig): Boolean = try {
        send("HEAD", S3CompatibleUrl.objectUrl(objectKey, storage), storage).isSuccess
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        false
    }

    suspend fun put(objectKey: String, bytes: ByteArray, contentType: String, storage: ObjectStorageConfig) {
        val r = send("PUT", S3CompatibleUrl.objectUrl(objectKey, storage), storage, bytes, contentType)
        if (!r.isSuccess) {
            PaircastLog.error("s3", "PUT HTTP ${r.status} key=$objectKey ${r.body.decodeToString().take(200)}")
            throw AppError.Network
        }
    }

    /** Returns the HTTP status; 404 counts as already deleted for callers. */
    suspend fun delete(objectKey: String, storage: ObjectStorageConfig): Int =
        send("DELETE", S3CompatibleUrl.objectUrl(objectKey, storage), storage).status

    suspend fun listPage(storage: ObjectStorageConfig, prefix: String?, continuationToken: String?, maxKeys: Int = 1000): S3ListPage {
        val query = buildList {
            add("list-type" to "2")
            add("max-keys" to maxKeys.toString())
            if (!prefix.isNullOrEmpty()) add("prefix" to prefix)
            if (!continuationToken.isNullOrEmpty()) add("continuation-token" to continuationToken)
        }
        val url = S3CompatibleUrl.bucketUrl(storage).withQuery(query)
        val r = send("GET", url, storage)
        val xml = r.body.decodeToString()
        if (!r.isSuccess) {
            PaircastLog.error("s3", "listObjects HTTP ${r.status} ${PaircastLog.redactedUrl(url.toString())}")
            throw try {
                S3ListObjectsV2Parser.parsePage(xml)
                listFailure(r.status)
            } catch (e: S3ErrorResponse) {
                mapS3Error(e)
            } catch (_: Exception) {
                listFailure(r.status)
            }
        }
        return try {
            S3ListObjectsV2Parser.parsePage(xml)
        } catch (e: S3ErrorResponse) {
            throw mapS3Error(e)
        } catch (_: Exception) {
            throw AppError.Unknown("Failed to parse listing")
        }
    }

    suspend fun listAll(storage: ObjectStorageConfig, prefix: String?, maxPages: Int = 50, maxKeys: Int = 1000): List<String> {
        val keys = mutableListOf<String>()
        var token: String? = null
        var pages = 0
        do {
            if (++pages > maxPages) break
            val page = listPage(storage, prefix, token, maxKeys)
            keys += page.keys
            token = page.nextContinuationToken?.takeIf { page.isTruncated && it.isNotEmpty() }
        } while (token != null)
        return keys
    }

    private suspend fun send(
        method: String,
        url: S3Url,
        storage: ObjectStorageConfig,
        body: ByteArray? = null,
        contentType: String? = null,
    ): S3Response {
        val signed = SigV4.signHeader(
            method = method,
            url = url,
            region = storage.signingRegion,
            accessKey = storage.accessKey,
            secretKey = storage.secretKey,
            headers = contentType?.let { mapOf("content-type" to it) } ?: emptyMap(),
            payloadHash = body?.let { SigV4.sha256Hex(it) } ?: SigV4.EMPTY_PAYLOAD_HASH,
        )
        return try {
            val response = http.request {
                this.method = HttpMethod.parse(signed.method)
                this.url.takeFrom(signed.url.toString())
                signed.headers.forEach { (k, v) -> if (!k.equals("content-type", ignoreCase = true)) header(k, v) }
                if (body != null) {
                    setBody(ByteArrayContent(body, contentType?.let(ContentType::parse) ?: ContentType.Application.OctetStream))
                }
            }
            S3Response(response.status.value, if (method == "HEAD") ByteArray(0) else response.bodyAsBytes())
        } catch (e: CancellationException) {
            throw e
        } catch (e: AppError) {
            throw e
        } catch (e: Exception) {
            PaircastLog.error("s3", "$method failed ${PaircastLog.redactedUrl(url.toString())}: ${e.message}")
            throw AppError.Network
        }
    }

    private fun listFailure(status: Int): AppError =
        if (status == 401 || status == 403) AppError.CatalogUnauthorized
        else AppError.Unknown("Failed to list objects (HTTP {{code}})", mapOf("code" to status.toString()))

    private fun mapS3Error(e: S3ErrorResponse): AppError = when (e.code) {
        "InvalidAccessKeyId", "SignatureDoesNotMatch", "AccessDenied", "InvalidToken" -> AppError.CatalogUnauthorized
        "NoSuchBucket" -> AppError.IncompleteConfig(listOf("Bucket"))
        else -> AppError.Unknown("Object storage: {{code}} — {{message}}", mapOf("code" to e.code, "message" to e.message))
    }

    companion object {
        /** Default play URL lifetime: 6 hours. */
        const val DEFAULT_PRESIGN_SECONDS = 6 * 3600
        /** SigV4 maximum (7 days) for poster / subtitle / sticker GETs. */
        const val MAX_PRESIGN_SECONDS = 7 * 24 * 3600
    }
}
