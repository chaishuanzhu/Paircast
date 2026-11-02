package com.chaisz.paircast.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Sticker wire payload. Authority is `pack_id` + `sticker_id`. */
@Serializable
data class StickerRef(
    @SerialName("pack_id") val packId: String,
    @SerialName("sticker_id") val stickerId: String,
    val format: String = "png",
    val width: Int = 240,
    val height: Int = 240,
    /** Optional object key or absolute URL fallback; receivers prefer resolving via storage. */
    val url: String? = null,
    /** Optional file name inside the pack (e.g. `001-file_1437.gif`). */
    val file: String? = null,
) {
    val bindKey: String get() = "$packId/$stickerId"
}

data class StickerItem(
    val packId: String,
    val stickerId: String,
    val fileName: String,
    val width: Int = 240,
    val height: Int = 240,
    /** Server-signed download URL (valid for days; not sent over the wire). */
    val url: String? = null,
) {
    val id: String get() = stickerId

    fun asRef(): StickerRef {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return StickerRef(
            packId = packId,
            stickerId = stickerId,
            format = ext.ifEmpty { "png" },
            width = width,
            height = height,
            file = fileName,
        )
    }
}

data class StickerPack(
    val packId: String,
    val name: String,
    val version: Int,
    val coverFileName: String? = null,
    val stickers: List<StickerItem> = emptyList(),
    val coverUrl: String? = null,
) {
    val id: String get() = packId
}

/** Index entry from `stickers/catalog.json` (full sticker list loaded from pack.json). */
data class StickerPackSummary(
    val packId: String,
    val name: String,
    val version: Int = 1,
    val coverFileName: String? = null,
    val count: Int = 0,
) {
    val id: String get() = packId
}

// Wire DTOs (ignore cdn_base / base_url)

@Serializable
data class StickerCatalogDTO(
    val version: Int? = 1,
    val packs: List<StickerPackSummaryDTO>,
)

@Serializable
data class StickerPackSummaryDTO(
    @SerialName("pack_id") val packId: String,
    val name: String,
    val version: Int? = null,
    val cover: String? = null,
    val count: Int? = null,
) {
    fun asSummary() = StickerPackSummary(
        packId = packId,
        name = name,
        version = version ?: 1,
        coverFileName = cover,
        count = count ?: 0,
    )
}

@Serializable
data class StickerPackDTO(
    @SerialName("pack_id") val packId: String,
    val name: String,
    val version: Int? = null,
    val cover: String? = null,
    @SerialName("cover_url") val coverUrl: String? = null,
    val stickers: List<StickerItemDTO>,
) {
    fun asPack() = StickerPack(
        packId = packId,
        name = name,
        version = version ?: 1,
        coverFileName = cover,
        coverUrl = coverUrl,
        stickers = stickers.map {
            StickerItem(
                packId = packId,
                stickerId = it.id,
                fileName = it.file,
                width = it.w ?: 240,
                height = it.h ?: 240,
                url = it.url,
            )
        },
    )
}

@Serializable
data class StickerItemDTO(
    val id: String,
    val file: String,
    val w: Int? = null,
    val h: Int? = null,
    /** Added by the server (`/media/stickers/pack`). */
    val url: String? = null,
)
