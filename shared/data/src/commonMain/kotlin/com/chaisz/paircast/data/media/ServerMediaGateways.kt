package com.chaisz.paircast.data.media

import com.chaisz.paircast.core.gateway.MetadataGateway
import com.chaisz.paircast.core.gateway.MovieCatalogGateway
import com.chaisz.paircast.core.gateway.SharedSubtitleStorageGateway
import com.chaisz.paircast.core.gateway.SubtitleGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.MediaSource
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.support.Paths
import com.chaisz.paircast.data.files.FileStore
import com.chaisz.paircast.data.subtitles.SubtitleEncodingNormalizer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.uuid.Uuid

/** Movie list, play URLs and server-scraped metadata (`/media/items|item|play`). */
class ServerCatalogGateway(private val api: ServerMediaApi) : MovieCatalogGateway, MetadataGateway {
    private val lock = Mutex()
    private val enriched = mutableMapOf<String, Movie>()

    override suspend fun listSources(config: AppCloudConfig): List<MediaSource> = api.sources().sources.map { it.toDomain() }

    override suspend fun listMovies(config: AppCloudConfig, sourceId: String?): List<Movie> {
        val movies = api.items(sourceId).map { it.toDomain() }
        val known = lock.withLock { enriched.toMap() }
        return movies.map { movie -> known[movie.id]?.let { movie.withArtworkFrom(it) } ?: movie }
    }

    override suspend fun playUrl(movie: Movie, config: AppCloudConfig): String = api.play(movie.id).url

    /** Server scrapes NFO / poster sidecars / TMDB once and caches; failures keep the input. */
    override suspend fun enrich(movie: Movie, config: AppCloudConfig): Movie {
        lock.withLock { enriched[movie.id] }?.let { return movie.withArtworkFrom(it) }
        val item = try {
            api.item(movie.id).toDomain()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return movie
        }
        lock.withLock { enriched[movie.id] = item }
        return movie.withArtworkFrom(item)
    }

    suspend fun clearCache() = lock.withLock { enriched.clear() }

    private fun Movie.withArtworkFrom(other: Movie) = copy(
        title = other.title.ifEmpty { title },
        year = other.year ?: year,
        overview = other.overview ?: overview,
        posterUrl = other.posterUrl ?: posterUrl,
        backdropUrl = other.backdropUrl ?: backdropUrl,
    )
}

/**
 * Sidecar / host-shared / online subtitles through the server. Track ids and urls carry the
 * server ref (`src:…` sidecar, `blob:…` stored, `os:…` online result); bytes are cached locally
 * as UTF-8 for the player.
 */
class ServerSubtitleGateway(
    private val api: ServerMediaApi,
    private val cache: FileStore,
) : SubtitleGateway, SharedSubtitleStorageGateway {

    override suspend fun listSidecars(movie: Movie, config: AppCloudConfig): List<SubtitleTrack> =
        api.subtitles(movie.id).map { it.toTrack(SubtitleSource.LIBRARY) }

    override suspend fun searchOnline(query: String, year: String?): List<SubtitleTrack> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        return api.searchSubtitles(trimmed, year).map { it.toTrack(SubtitleSource.ONLINE) }
    }

    override suspend fun download(track: SubtitleTrack, config: AppCloudConfig?): String {
        val ref = track.url ?: track.id
        return when (track.source) {
            SubtitleSource.LIBRARY -> readRef(ref, track.label)
            SubtitleSource.ONLINE -> readRef(if (ref.startsWith(ONLINE_PREFIX)) api.fetchSubtitle(ref) else ref, track.label)
            SubtitleSource.EMBEDDED, SubtitleSource.OFF -> throw AppError.SubtitleUnavailable
        }
    }

    override suspend fun upload(filePath: String, roomId: String, label: String?, config: AppCloudConfig): String {
        val bytes = runCatching { cache.readAbsolute(filePath) }.getOrNull()?.takeIf { it.isNotEmpty() }
            ?: throw AppError.SubtitleShareFailed
        return try {
            api.shareSubtitle(roomId, label, Paths.lastPathComponent(filePath), bytes)
        } catch (e: CancellationException) {
            throw e
        } catch (e: AppError.SessionExpired) {
            throw e
        } catch (_: Exception) {
            throw AppError.SubtitleShareFailed
        }
    }

    override suspend fun download(ref: String, config: AppCloudConfig): String = readRef(ref, "shared")

    private suspend fun readRef(ref: String, name: String): String {
        val (bytes, ext) = api.subtitle(ref)
        if (bytes.isEmpty()) throw AppError.SubtitleUnavailable
        val safe = name.replace("/", "_").replace(":", "_").take(60)
        // Unique file so stale wrong-encoding copies are never reused.
        return cache.write("subtitles/${uniqueStamp()}-$safe.$ext", SubtitleEncodingNormalizer.utf8BytesWithBom(bytes))
    }

    companion object {
        const val ONLINE_PREFIX = "os:"
    }
}

internal fun SubtitleRefDto.toTrack(source: SubtitleSource) = SubtitleTrack(
    id = ref,
    label = label.ifEmpty { Paths.lastPathComponent(ref) },
    language = language?.ifEmpty { null },
    source = source,
    url = ref,
    detail = detail?.ifEmpty { null },
    languageBadge = badge?.ifEmpty { null },
    format = format?.ifEmpty { null },
)

private fun uniqueStamp(): String = Uuid.random().toString().lowercase().take(13)
