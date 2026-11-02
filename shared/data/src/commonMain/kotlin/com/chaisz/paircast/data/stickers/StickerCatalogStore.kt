package com.chaisz.paircast.data.stickers

import com.chaisz.paircast.core.gateway.StickerCatalogGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.StickerCatalogDTO
import com.chaisz.paircast.core.model.StickerPack
import com.chaisz.paircast.core.model.StickerPackDTO
import com.chaisz.paircast.core.model.StickerPackSummary
import com.chaisz.paircast.core.model.StickerRef
import com.chaisz.paircast.core.model.StickersObjectKey
import com.chaisz.paircast.core.support.PaircastJson
import com.chaisz.paircast.data.files.FileStore
import com.chaisz.paircast.data.s3.S3Client
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Sticker packs from the user's bucket `stickers/` (SigV4 GET), cached in memory and on disk. */
class StickerCatalogStore(
    private val s3: S3Client,
    private val disk: FileStore,
) : StickerCatalogGateway {
    private val lock = Mutex()
    private val memoryImages = mutableMapOf<String, ByteArray>()
    private val packCache = mutableMapOf<String, StickerPack>()
    private var catalogFingerprint: String? = null
    private var catalog: List<StickerPackSummary> = emptyList()

    override suspend fun loadCatalog(config: AppCloudConfig): List<StickerPackSummary> {
        requireStorage(config)
        val fp = fingerprint(config)
        lock.withLock { if (catalogFingerprint == fp && catalog.isNotEmpty()) return catalog }
        val bytes = s3.getBytes(StickersObjectKey.catalogKey(config.storage.prefix), config.storage)
        val summaries = PaircastJson.default.decodeFromString(StickerCatalogDTO.serializer(), bytes.decodeToString()).packs.map { it.asSummary() }
        lock.withLock {
            if (catalogFingerprint != fp) {
                packCache.clear()
                memoryImages.clear()
            }
            catalog = summaries
            catalogFingerprint = fp
        }
        return summaries
    }

    override suspend fun loadPack(packId: String, config: AppCloudConfig): StickerPack {
        requireStorage(config)
        val cacheKey = "${fingerprint(config)}|$packId"
        lock.withLock { packCache[cacheKey] }?.let { return it }
        val bytes = s3.getBytes(StickersObjectKey.packManifestKey(packId, config.storage.prefix), config.storage)
        val pack = PaircastJson.default.decodeFromString(StickerPackDTO.serializer(), bytes.decodeToString()).asPack()
        lock.withLock { packCache[cacheKey] = pack }
        return pack
    }

    override suspend fun imageData(packId: String, fileName: String, config: AppCloudConfig): ByteArray {
        requireStorage(config)
        val fp = fingerprint(config)
        val memKey = "$fp|$packId|$fileName"
        lock.withLock { memoryImages[memKey] }?.let { return it }
        val relative = diskRelativePath(fp, packId, fileName)
        disk.read(relative)?.takeIf { it.isNotEmpty() }?.let { cached ->
            lock.withLock { memoryImages[memKey] = cached }
            return cached
        }
        val bytes = s3.getBytes(StickersObjectKey.assetKey(packId, fileName, config.storage.prefix), config.storage)
        lock.withLock { memoryImages[memKey] = bytes }
        runCatching { disk.write(relative, bytes) }
        return bytes
    }

    override suspend fun imageDataForRef(ref: StickerRef, config: AppCloudConfig): ByteArray =
        imageData(ref.packId, resolveFileName(ref, config), config)

    override suspend fun imageUrl(ref: StickerRef, config: AppCloudConfig): String {
        requireStorage(config)
        val key = StickersObjectKey.assetKey(ref.packId, resolveFileName(ref, config), config.storage.prefix)
        return s3.presignGet(key, config.storage, S3Client.MAX_PRESIGN_SECONDS)
    }

    private suspend fun resolveFileName(ref: StickerRef, config: AppCloudConfig): String {
        ref.file?.takeIf { it.isNotEmpty() }?.let { return it }
        val pack = loadPack(ref.packId, config)
        return pack.stickers.firstOrNull { it.stickerId == ref.stickerId }?.fileName ?: "${ref.stickerId}.${ref.format}"
    }

    private fun requireStorage(config: AppCloudConfig) {
        if (!config.storage.isComplete) throw AppError.NotConfigured
    }

    private fun fingerprint(config: AppCloudConfig): String =
        listOf(config.storage.bucket, config.storage.endpoint, config.storage.prefix.orEmpty()).joinToString("|")

    private fun diskRelativePath(fp: String, packId: String, fileName: String): String {
        fun safe(s: String) = s.replace("/", "_").replace(":", "_").replace("|", "_")
        return "stickers/${safe(fp)}/${safe(packId)}/${safe(fileName)}"
    }
}
