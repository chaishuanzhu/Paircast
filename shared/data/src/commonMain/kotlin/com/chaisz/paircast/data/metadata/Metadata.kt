package com.chaisz.paircast.data.metadata

import com.chaisz.paircast.core.gateway.MetadataGateway
import com.chaisz.paircast.core.gateway.MovieMetadataStorageGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.MovieMetadataObjectKey
import com.chaisz.paircast.core.rules.MovieCatalogRules
import com.chaisz.paircast.core.support.Paths
import com.chaisz.paircast.data.net.apiJson
import com.chaisz.paircast.data.s3.S3Client
import com.chaisz.paircast.data.support.PaircastLog
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.Url
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.time.Clock

/** In-memory enrichment cache (7 days), keyed by movie object key. */
class MetadataCache(private val ttlMs: Long = 7 * 24 * 3600_000L) {
    private val lock = Mutex()
    private val memory = mutableMapOf<String, Pair<Movie, Long>>()

    suspend fun movie(key: String): Movie? = lock.withLock {
        memory[key]?.takeIf { now() - it.second < ttlMs }?.first
    }

    suspend fun store(movie: Movie, key: String) = lock.withLock { memory[key] = movie to now() }

    suspend fun clear() = lock.withLock { memory.clear() }

    private fun now() = Clock.System.now().toEpochMilliseconds()
}

/**
 * OSS sidecars first (`{base}.nfo`, poster/fanart), then TMDB (user token only), then persists
 * scraped art + NFO beside the movie so the next launch skips scraping.
 */
class CascadingMetadataGateway(
    private val http: HttpClient,
    private val storage: MovieMetadataStorageGateway?,
    private val cache: MetadataCache = MetadataCache(),
    private val tmdbLanguage: () -> String = { "en-US" },
) : MetadataGateway {

    override suspend fun enrich(movie: Movie, config: AppCloudConfig): Movie {
        cache.movie(movie.objectKey)?.let { cached ->
            if (storage == null || !needsOssArtPersist(cached)) return cached
            val saved = storage.save(cached, config)
            cache.store(saved, movie.objectKey)
            return saved
        }

        val parsed = MovieCatalogRules.parseFilenameMetadata(movie.objectKey)
        var result = movie.copy(title = parsed.title, year = parsed.year ?: movie.year)

        storage?.load(movie, config)?.let { stored ->
            if (stored.posterUrl != null) {
                cache.store(stored, movie.objectKey)
                return stored
            }
            result = stored.copy(
                title = stored.title.ifBlank { parsed.title },
                year = stored.year?.takeIf { it.isNotEmpty() } ?: parsed.year ?: stored.year,
            )
        }

        if (result.posterUrl == null || needsOssArtPersist(result) || result.overview.isNullOrEmpty()) {
            fetchTmdb(result.title, result.year, config.tmdbAccessToken)?.let { tmdb ->
                result = merge(result, tmdb)
                PaircastLog.info("metadata", "tmdb hit movie=${movie.objectKey} poster=${result.posterUrl != null}")
            }
        }

        val hasContent = result.posterUrl != null || !result.overview.isNullOrEmpty()
        if (storage != null && hasContent) {
            result = storage.save(result, config)
        }
        if (hasContent) cache.store(result, movie.objectKey)
        return result
    }

    private suspend fun fetchTmdb(title: String, year: String?, token: String?): TmdbMovieResult? {
        val bearer = token?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val query = title.trim().takeIf { it.isNotEmpty() } ?: return null
        return try {
            val response = http.get("https://api.themoviedb.org/3/search/movie") {
                header(HttpHeaders.Authorization, "Bearer $bearer")
                header(HttpHeaders.Accept, "application/json")
                parameter("query", query)
                parameter("include_adult", "false")
                parameter("language", tmdbLanguage())
                parameter("page", "1")
                if (!year.isNullOrEmpty()) parameter("primary_release_year", year)
            }
            if (response.status.value !in 200..299) {
                PaircastLog.error("metadata", "tmdb search HTTP ${response.status.value}")
                return null
            }
            val payload = apiJson.decodeFromString(TmdbSearchResponse.serializer(), response.bodyAsText())
            pickTmdbResult(payload.results, year)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            PaircastLog.error("metadata", "tmdb search error=${e.message}")
            null
        }
    }

    private fun merge(movie: Movie, meta: TmdbMovieResult): Movie {
        val title = meta.title.ifEmpty { meta.originalTitle.orEmpty() }
        return movie.copy(
            title = title.ifEmpty { movie.title },
            year = meta.releaseYear ?: movie.year,
            overview = meta.overview?.trim()?.takeIf { it.isNotEmpty() } ?: movie.overview,
            posterUrl = tmdbImageUrl(meta.posterPath, "w500") ?: movie.posterUrl,
            backdropUrl = tmdbImageUrl(meta.backdropPath, "w1280") ?: movie.backdropUrl,
        )
    }

    companion object {
        /** True when the poster still points at the TMDB CDN and needs upload to object storage. */
        fun needsOssArtPersist(movie: Movie): Boolean {
            val host = movie.posterUrl?.let { runCatching { Url(it).host.lowercase() }.getOrNull() } ?: return false
            return host == "image.tmdb.org" || host.endsWith(".tmdb.org")
        }

        internal fun pickTmdbResult(results: List<TmdbMovieResult>, year: String?): TmdbMovieResult? =
            if (year.isNullOrEmpty()) results.firstOrNull() else results.firstOrNull { it.releaseYear == year }

        fun tmdbImageUrl(path: String?, size: String): String? =
            if (path == null || !path.startsWith("/") || size.isEmpty()) null else "https://image.tmdb.org/t/p/$size$path"

        /** `zh-CN` for Chinese UIs, otherwise `en-US`. */
        fun tmdbLanguageFor(preferredLanguage: String): String =
            if (preferredLanguage.startsWith("zh")) "zh-CN" else "en-US"
    }
}

@Serializable
internal data class TmdbSearchResponse(val results: List<TmdbMovieResult> = emptyList())

@Serializable
internal data class TmdbMovieResult(
    val id: Int,
    val title: String = "",
    @SerialName("original_title") val originalTitle: String? = null,
    val overview: String? = null,
    @SerialName("release_date") val releaseDate: String? = null,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("backdrop_path") val backdropPath: String? = null,
) {
    val releaseYear: String? get() = releaseDate?.takeIf { it.length >= 4 }?.take(4)
}

/** Kodi-style sidecars beside the movie: `{base}.nfo`, `{base}-poster.jpg`, `{base}-fanart.jpg`. */
class OssMovieMetadataStorage(
    private val http: HttpClient,
    private val s3: S3Client,
) : MovieMetadataStorageGateway {

    override suspend fun load(movie: Movie, config: AppCloudConfig): Movie? {
        if (!config.storage.isComplete) return null
        val nfoKey = MovieMetadataObjectKey.nfoKey(movie.objectKey) ?: return null
        val nfo = runCatching { s3.get(nfoKey, config.storage) }.getOrNull()?.takeIf { it.isSuccess } ?: return null
        val payload = MovieNfoCodec.decode(nfo.body.decodeToString()) ?: return null

        val posterKey = MovieMetadataObjectKey.posterKey(movie.objectKey) ?: directoryJoined(movie.objectKey, payload.posterFileName)
        val fanartKey = MovieMetadataObjectKey.fanartKey(movie.objectKey) ?: directoryJoined(movie.objectKey, payload.fanartFileName)
        return movie.copy(
            title = payload.title,
            year = payload.year?.takeIf { it.isNotEmpty() } ?: movie.year,
            overview = payload.overview?.takeIf { it.isNotEmpty() } ?: movie.overview,
            posterUrl = posterKey?.takeIf { s3.exists(it, config.storage) }?.let { signed(it, config) } ?: movie.posterUrl,
            backdropUrl = fanartKey?.takeIf { s3.exists(it, config.storage) }?.let { signed(it, config) } ?: movie.backdropUrl,
        )
    }

    override suspend fun save(movie: Movie, config: AppCloudConfig): Movie {
        if (!config.storage.isComplete) return movie
        val nfoKey = MovieMetadataObjectKey.nfoKey(movie.objectKey) ?: return movie
        val posterKey = MovieMetadataObjectKey.posterKey(movie.objectKey) ?: return movie
        val fanartKey = MovieMetadataObjectKey.fanartKey(movie.objectKey) ?: return movie
        var result = movie

        var posterBytes: Pair<ByteArray, String>? = null
        movie.posterUrl?.let { remote ->
            downloadImage(remote)?.let { (bytes, type) ->
                posterBytes = bytes to type
                if (tryPut(posterKey, bytes, type, config)) result = result.copy(posterUrl = signed(posterKey, config))
            }
        }

        val remoteFanart = movie.backdropUrl
        val poster = posterBytes
        if (remoteFanart != null && remoteFanart != movie.posterUrl) {
            downloadImage(remoteFanart)?.let { (bytes, type) ->
                if (tryPut(fanartKey, bytes, type, config)) result = result.copy(backdropUrl = signed(fanartKey, config))
            }
        } else if (poster != null) {
            // No distinct backdrop from scrape — reuse poster as fanart sidecar.
            if (tryPut(fanartKey, poster.first, poster.second, config)) result = result.copy(backdropUrl = signed(fanartKey, config))
        }

        val hasPoster = s3.exists(posterKey, config.storage)
        val hasFanart = s3.exists(fanartKey, config.storage)
        val nfo = MovieNfoCodec.encode(
            MovieNfoCodec.Payload(
                title = result.title,
                year = result.year,
                overview = result.overview,
                posterFileName = if (hasPoster) Paths.lastPathComponent(posterKey) else null,
                fanartFileName = if (hasFanart) Paths.lastPathComponent(fanartKey) else null,
            ),
        )
        if (tryPut(nfoKey, nfo.encodeToByteArray(), "application/xml; charset=utf-8", config)) {
            if (hasPoster) result = result.copy(posterUrl = signed(posterKey, config))
            if (hasFanart) result = result.copy(backdropUrl = signed(fanartKey, config))
        }
        return result
    }

    private suspend fun tryPut(key: String, bytes: ByteArray, contentType: String, config: AppCloudConfig): Boolean = try {
        s3.put(key, bytes, contentType, config.storage)
        true
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        false
    }

    private suspend fun downloadImage(remote: String): Pair<ByteArray, String>? {
        repeat(3) { attempt ->
            try {
                val response = http.get(remote) { header(HttpHeaders.Accept, "image/avif,image/webp,image/*,*/*;q=0.8") }
                val status = response.status.value
                val bytes = response.bodyAsBytes()
                if (status in 200..299 && bytes.isNotEmpty()) {
                    return bytes to normalizedImageContentType(response.headers[HttpHeaders.ContentType])
                }
                if (status != 429 && status !in 500..599) return null
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
            delay(200L * (attempt + 1))
        }
        return null
    }

    private fun signed(key: String, config: AppCloudConfig) = s3.presignGet(key, config.storage, S3Client.MAX_PRESIGN_SECONDS)

    private fun directoryJoined(movieObjectKey: String, fileName: String?): String? {
        if (fileName.isNullOrEmpty()) return null
        if ('/' in fileName) return fileName
        val parent = movieObjectKey.substringBeforeLast('/', "")
        return if (parent.isEmpty()) fileName else "$parent/$fileName"
    }

    companion object {
        /** Strip charset / parameters so SigV4 + S3-compatible PUTs stay stable. */
        fun normalizedImageContentType(raw: String?): String {
            val base = raw?.substringBefore(';')?.trim()?.lowercase().orEmpty()
            return if (base.startsWith("image/")) base else "image/jpeg"
        }
    }
}
