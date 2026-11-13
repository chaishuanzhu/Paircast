package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.StickerCatalogGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.StickerCatalogDTO
import com.chaisz.paircast.core.model.StickerPack
import com.chaisz.paircast.core.model.StickerPackDTO
import com.chaisz.paircast.core.model.StickerPackSummary
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.support.PaircastJson
import com.chaisz.paircast.data.files.FileStore
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.time.Clock

/** Sticker packs from the GO-IM gateway (`GET /stickers/catalog.json|{pack}/pack.json|{pack}/{file}`, no login). */
class GoImStickerCatalog(
    private val auth: GoImAuthGateway,
    private val http: HttpClient,
    private val disk: FileStore,
    private val nowMs: () -> Long = { Clock.System.now().toEpochMilliseconds() },
) : StickerCatalogGateway {
    private val lock = Mutex()
    private val memoryImages = mutableMapOf<String, ByteArray>()
    private val packCache = mutableMapOf<String, Pair<StickerPack, Long>>()
    private var catalogBase: String? = null
    private var catalog: List<StickerPackSummary> = emptyList()

    override suspend fun loadCatalog(config: AppCloudConfig): List<StickerPackSummary> {
        val base = imBase()
        lock.withLock { if (catalogBase == base && catalog.isNotEmpty()) return catalog }
        val text = fetch(stickerUrl(base, "catalog.json")).bodyAsText()
        val summaries = PaircastJson.default.decodeFromString(StickerCatalogDTO.serializer(), text).packs.map { it.asSummary() }
        lock.withLock {
            if (catalogBase != base) {
                packCache.clear()
                memoryImages.clear()
            }
            catalog = summaries
            catalogBase = base
        }
        return summaries
    }

    override suspend fun loadPack(packId: String, config: AppCloudConfig): StickerPack {
        val base = imBase()
        val key = "$base|$packId"
        lock.withLock { packCache[key] }?.let { (pack, at) -> if (nowMs() - at < PACK_TTL_MS) return pack }
        val text = fetch(stickerUrl(base, "$packId/pack.json")).bodyAsText()
        val pack = PaircastJson.default.decodeFromString(StickerPackDTO.serializer(), text).asPack()
        lock.withLock { packCache[key] = pack to nowMs() }
        return pack
    }

    override suspend fun imageData(packId: String, fileName: String, config: AppCloudConfig): ByteArray {
        val base = imBase()
        val memKey = "$base|$packId|$fileName"
        lock.withLock { memoryImages[memKey] }?.let { return it }
        val relative = diskRelativePath(base, packId, fileName)
        disk.read(relative)?.takeIf { it.isNotEmpty() }?.let { cached ->
            lock.withLock { memoryImages[memKey] = cached }
            return cached
        }
        val bytes = fetch(stickerUrl(base, "$packId/$fileName")).bodyAsBytes()
        lock.withLock { memoryImages[memKey] = bytes }
        runCatching { disk.write(relative, bytes) }
        return bytes
    }

    override suspend fun imageDataForRef(ref: StickerRef, config: AppCloudConfig): ByteArray =
        imageData(ref.packId, resolveFileName(ref, config), config)

    override suspend fun imageUrl(ref: StickerRef, config: AppCloudConfig): String =
        stickerUrl(imBase(), "${ref.packId}/${resolveFileName(ref, config)}")

    private suspend fun resolveFileName(ref: StickerRef, config: AppCloudConfig): String {
        ref.file?.takeIf { it.isNotEmpty() }?.let { return it }
        val pack = loadPack(ref.packId, config)
        return pack.stickers.firstOrNull { it.stickerId == ref.stickerId }?.fileName ?: "${ref.stickerId}.${ref.format}"
    }

    private fun imBase(): String = auth.requireSession().imBase

    private suspend fun fetch(url: String): HttpResponse {
        val response = try {
            http.get(url)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            throw AppError.Network
        }
        if (!response.status.isSuccess()) throw AppError.Unknown("Sticker not found")
        return response
    }

    private fun diskRelativePath(base: String, packId: String, fileName: String): String {
        fun safe(s: String) = s.replace("/", "_").replace(":", "_").replace("|", "_")
        return "stickers/${safe(base)}/${safe(packId)}/${safe(fileName)}"
    }

    companion object {
        /** Packs change rarely; re-read the manifest daily so new stickers show up without a restart. */
        const val PACK_TTL_MS = 24 * 60 * 60 * 1_000L

        fun stickerUrl(imBase: String, path: String) = GoImApi.url(imBase, "stickers/$path")
    }
}
