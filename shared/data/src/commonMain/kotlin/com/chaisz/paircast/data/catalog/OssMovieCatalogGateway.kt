package com.chaisz.paircast.data.catalog

import com.chaisz.paircast.core.gateway.MovieCatalogGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.Movie
import com.chaisz.paircast.core.model.VideoFormat
import com.chaisz.paircast.core.rules.MovieCatalogRules
import com.chaisz.paircast.data.s3.S3Client
import com.chaisz.paircast.data.support.PaircastLog

/** S3-compatible ListObjectsV2 + SigV4 (paginated) over the configured bucket/prefix. */
class OssMovieCatalogGateway(
    private val s3: S3Client,
    private val presignExpiresSeconds: Int = S3Client.DEFAULT_PRESIGN_SECONDS,
    private val maxPages: Int = 50,
) : MovieCatalogGateway {

    override suspend fun listMovies(config: AppCloudConfig): List<Movie> {
        val keys = s3.listAll(config.storage, config.storage.prefix, maxPages)
        val movies = keys.mapNotNull { key ->
            val format = VideoFormat.fromFilename(key) ?: return@mapNotNull null
            val parsed = MovieCatalogRules.parseFilenameMetadata(key)
            Movie(id = key, objectKey = key, title = parsed.title, year = parsed.year, format = format)
        }
        PaircastLog.info("catalog", "listMovies objects=${keys.size} videos=${movies.size}")
        return movies
    }

    override suspend fun playUrl(movie: Movie, config: AppCloudConfig): String =
        movie.playUrl ?: s3.presignGet(movie.objectKey, config.storage, presignExpiresSeconds)
}
