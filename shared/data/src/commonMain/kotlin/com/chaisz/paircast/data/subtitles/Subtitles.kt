package com.chaisz.paircast.data.subtitles

import com.chaisz.paircast.core.gateway.SharedSubtitleStorageGateway
import com.chaisz.paircast.core.gateway.SubtitleGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.SharedSubtitleObjectKey
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.support.Paths
import com.chaisz.paircast.data.files.FileStore
import com.chaisz.paircast.data.net.apiJson
import com.chaisz.paircast.data.s3.S3Client
import com.chaisz.paircast.data.support.PaircastLog
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.roundToInt
import kotlin.uuid.Uuid

/** Library sidecar subtitles (ListObjects by movie basename) + OpenSubtitles search/download. */
class OpenSubtitlesGateway(
    private val http: HttpClient,
    private val s3: S3Client,
    private val cache: FileStore,
    private val userAgent: String,
    private val presignExpiresSeconds: Int = S3Client.DEFAULT_PRESIGN_SECONDS,
) : SubtitleGateway {

    override suspend fun listOSSSidecars(movie: Movie, config: AppCloudConfig): List<SubtitleTrack> {
        val base = Paths.deletingPathExtension(movie.objectKey)
        if (base.isEmpty()) return emptyList()
        val keys = try {
            s3.listAll(config.storage, base, maxPages = 20)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            PaircastLog.error("subtitles", "sidecar list failed movie=${movie.objectKey}: ${e.message}")
            emptyList()
        }
        var sidecars = matchingSidecarKeys(keys, movie.objectKey)
        if (sidecars.isEmpty()) {
            sidecars = candidateSidecarKeys(base).filter { s3.exists(it, config.storage) }
        }
        return sidecars.sorted().map { key ->
            val leaf = Paths.lastPathComponent(key)
            val ext = Paths.pathExtension(leaf).uppercase()
            val (code, badge) = guessLanguage(leaf)
            SubtitleTrack(
                id = "oss:$key",
                label = if (badge.isNotEmpty()) "$badge (sidecar)" else leaf,
                language = code,
                source = SubtitleSource.OSS,
                url = s3.presignGet(key, config.storage, presignExpiresSeconds),
                detail = "Library sidecar · $ext",
                languageBadge = badge,
                format = ext,
            )
        }
    }

    override suspend fun searchOnline(query: String, year: String?, apiKey: String?): List<SubtitleTrack> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        val key = apiKey?.takeIf { it.isNotEmpty() } ?: throw AppError.Validation(MISSING_KEY)
        val response = guarded {
            http.get("https://api.opensubtitles.com/api/v1/subtitles") {
                osHeaders(key)
                parameter("query", trimmed)
                parameter("languages", "zh-cn,zh-tw,en")
                parameter("order_by", "download_count")
                parameter("order_direction", "desc")
                if (!year.isNullOrEmpty()) parameter("year", year)
            }
        }
        val status = response.status.value
        if (status == 401 || status == 403) throw AppError.Validation("Invalid OpenSubtitles API Key")
        if (status !in 200..299) throw AppError.SubtitleUnavailable
        val decoded = apiJson.decodeFromString(OsSearchResponse.serializer(), response.bodyAsText())
        return decoded.data.mapNotNull { item ->
            val file = item.attributes.files?.firstOrNull() ?: return@mapNotNull null
            val name = file.fileName ?: item.attributes.release ?: "Subtitle ${file.fileId}"
            val lang = item.attributes.language.orEmpty()
            val downloads = item.attributes.downloadCount ?: 0
            val format = Paths.pathExtension(name).uppercase().ifEmpty { "SRT" }
            val badge = guessLanguage("$name.$lang").second
            val downloadLabel = if (downloads >= 1000) "${(downloads / 100.0).roundToInt() / 10.0}k" else downloads.toString()
            SubtitleTrack(
                id = "os:${file.fileId}",
                label = name,
                language = lang,
                source = SubtitleSource.ONLINE,
                url = "opensubtitles://file/${file.fileId}",
                detail = "OpenSubtitles · Downloads $downloadLabel · $format",
                languageBadge = badge.ifEmpty { lang.uppercase() },
                format = format,
            )
        }
    }

    override suspend fun download(track: SubtitleTrack, config: AppCloudConfig?): String = when (track.source) {
        SubtitleSource.OSS -> {
            val key = ossObjectKey(track)
            val fresh = if (key != null && config != null && config.storage.isComplete) {
                s3.presignGet(key, config.storage, presignExpiresSeconds)
            } else {
                null
            }
            downloadRemote(fresh ?: track.url ?: throw AppError.SubtitleUnavailable, track.label)
        }
        SubtitleSource.ONLINE -> {
            val key = config?.subtitleApiKey?.takeIf { it.isNotEmpty() } ?: throw AppError.Validation(MISSING_KEY)
            val link = requestDownloadLink(parseFileId(track), key)
            downloadRemote(link, track.label)
        }
        SubtitleSource.EMBEDDED, SubtitleSource.OFF -> throw AppError.SubtitleUnavailable
    }

    private suspend fun requestDownloadLink(fileId: Long, apiKey: String): String {
        val response = guarded {
            http.post("https://api.opensubtitles.com/api/v1/download") {
                osHeaders(apiKey)
                contentType(ContentType.Application.Json)
                setBody("""{"file_id":$fileId}""")
            }
        }
        if (response.status.value !in 200..299) throw AppError.SubtitleUnavailable
        return apiJson.decodeFromString(OsDownloadResponse.serializer(), response.bodyAsText()).link
            ?: throw AppError.SubtitleUnavailable
    }

    private suspend fun downloadRemote(url: String, suggestedName: String): String {
        val response = guarded { http.get(url) }
        if (response.status.value !in 200..299) throw AppError.SubtitleUnavailable
        val bytes = response.bodyAsBytes()
        val safe = suggestedName.replace("/", "_").replace(":", "_")
        val ext = Paths.pathExtension(url.substringBefore('?')).ifEmpty { "srt" }
        val fileName = if (safe.endsWith(".$ext")) safe else "$safe.$ext"
        // Unique file so stale wrong-encoding copies are never reused.
        return cache.write("subtitles/${uniqueStamp()}-$fileName", SubtitleEncodingNormalizer.utf8BytesWithBom(bytes))
    }

    private fun io.ktor.client.request.HttpRequestBuilder.osHeaders(apiKey: String) {
        header("Api-Key", apiKey)
        header(HttpHeaders.UserAgent, userAgent)
        header(HttpHeaders.Accept, "application/json")
    }

    private fun parseFileId(track: SubtitleTrack): Long =
        track.id.removePrefix("os:").takeIf { track.id.startsWith("os:") }?.toLongOrNull()
            ?: track.url?.takeIf { it.startsWith("opensubtitles://") }?.substringAfterLast('/')?.toLongOrNull()
            ?: throw AppError.SubtitleUnavailable

    companion object {
        const val MISSING_KEY = "Add an OpenSubtitles API Key in Service Configuration first"

        fun matchingSidecarKeys(keys: List<String>, movieObjectKey: String): List<String> {
            val movieLeaf = Paths.lastPathComponent(movieObjectKey)
            val movieBase = Paths.lastPathComponent(Paths.deletingPathExtension(movieObjectKey)).lowercase()
            if (movieBase.isEmpty()) return emptyList()
            return keys.filter { key ->
                val leaf = Paths.lastPathComponent(key)
                if (leaf == movieLeaf || !SharedSubtitleObjectKey.isSubtitleExtension(Paths.pathExtension(leaf))) return@filter false
                val leafBase = Paths.deletingPathExtension(leaf).lowercase()
                leafBase == movieBase || listOf(".", "_", "-").any { leafBase.startsWith(movieBase + it) }
            }.distinct()
        }

        fun ossObjectKey(track: SubtitleTrack): String? =
            if (track.source == SubtitleSource.OSS && track.id.startsWith("oss:")) track.id.removePrefix("oss:").ifEmpty { null } else null

        private fun candidateSidecarKeys(base: String): List<String> = listOf(
            ".srt", ".zh.srt", ".chi.srt", ".chs.srt", ".zh-cn.srt", ".zh_cn.srt",
            ".en.srt", ".eng.srt",
            ".vtt", ".zh.vtt", ".en.vtt",
            ".ass", ".ssa", ".zh.ass",
        ).map { base + it }

        internal fun guessLanguage(name: String): Pair<String?, String> {
            val lower = name.lowercase()
            return when {
                listOf("zh-cn", "zh_cn", ".chs", "简体", "chi", ".zh.", "chinese").any { it in lower } || lower.endsWith(".zh") -> "zh" to "ZH"
                listOf("zh-tw", "zh_tw", ".cht", "繁体").any { it in lower } -> "zh-tw" to "ZH-TW"
                listOf(".en", "eng", "english").any { it in lower } -> "en" to "English"
                listOf("双语", "dual").any { it in lower } -> null to "Bilingual"
                else -> null to ""
            }
        }
    }
}

/** Host-shared subtitles saved beside the movie: `{movieBase}.{srt|vtt|ass}`. */
class OssSharedSubtitleStorage(
    private val s3: S3Client,
    private val cache: FileStore,
) : SharedSubtitleStorageGateway {

    override suspend fun upload(filePath: String, roomId: String, movieId: String, config: AppCloudConfig): String {
        if (!config.storage.isComplete) throw AppError.NotConfigured
        val bytes = runCatching { cache.readAbsolute(filePath) }.getOrNull()?.takeIf { it.isNotEmpty() }
            ?: throw AppError.SubtitleShareFailed
        val ext = SharedSubtitleObjectKey.normalizedExtension(Paths.pathExtension(filePath))
        val key = SharedSubtitleObjectKey.sidecarKey(movieId, ext) ?: throw AppError.SubtitleShareFailed
        try {
            s3.put(key, bytes, contentType(ext), config.storage)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            throw AppError.SubtitleShareFailed
        }
        PaircastLog.info("subtitles", "sidecar uploaded room=$roomId key=$key")
        return key
    }

    override suspend fun download(objectKey: String, config: AppCloudConfig): String {
        if (!config.storage.isComplete) throw AppError.NotConfigured
        val key = objectKey.trim()
        if (!SharedSubtitleObjectKey.isValid(key)) throw AppError.Validation("Invalid shared subtitle key")
        val r = s3.get(key, config.storage)
        if (!r.isSuccess) throw AppError.SubtitleUnavailable
        val ext = SharedSubtitleObjectKey.normalizedExtension(Paths.pathExtension(key))
        return cache.write("subtitles/shared/${uniqueStamp()}.$ext", SubtitleEncodingNormalizer.utf8BytesWithBom(r.body))
    }

    private fun contentType(ext: String) = when (ext) {
        "vtt" -> "text/vtt"
        "ass", "ssa" -> "text/x-ssa"
        else -> "application/x-subrip"
    }
}

private fun uniqueStamp(): String = Uuid.random().toString().lowercase().take(13)

private suspend fun guarded(block: suspend () -> HttpResponse): HttpResponse = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (_: Exception) {
    throw AppError.Network
}

@Serializable
private data class OsSearchResponse(val data: List<OsSearchItem> = emptyList())

@Serializable
private data class OsSearchItem(val attributes: OsAttributes)

@Serializable
private data class OsAttributes(
    val language: String? = null,
    val release: String? = null,
    @SerialName("download_count") val downloadCount: Int? = null,
    val files: List<OsFile>? = null,
)

@Serializable
private data class OsFile(
    @SerialName("file_id") val fileId: Long,
    @SerialName("file_name") val fileName: String? = null,
)

@Serializable
private data class OsDownloadResponse(val link: String? = null)
