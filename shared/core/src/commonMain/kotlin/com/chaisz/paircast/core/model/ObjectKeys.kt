package com.chaisz.paircast.core.model

import com.chaisz.paircast.core.support.Paths

/** Reserved prefix for Paircast-owned objects (rooms, legacy avatars). */
const val PAIRCAST_RESERVED_PREFIX = "_paircast/"

/**
 * Kodi-style metadata sidecars next to the movie object.
 * `films/Foo.2010.mkv` → `Foo.2010.nfo` / `Foo.2010-poster.jpg` / `Foo.2010-fanart.jpg`
 */
object MovieMetadataObjectKey {
    fun movieBase(movieObjectKey: String): String? {
        val key = movieObjectKey.trim()
        if (key.isEmpty() || key.startsWith(PAIRCAST_RESERVED_PREFIX)) return null
        return Paths.deletingPathExtension(key).ifEmpty { null }
    }

    fun nfoKey(movieObjectKey: String): String? = movieBase(movieObjectKey)?.let { "$it.nfo" }
    fun posterKey(movieObjectKey: String): String? = movieBase(movieObjectKey)?.let { "$it-poster.jpg" }
    fun fanartKey(movieObjectKey: String): String? = movieBase(movieObjectKey)?.let { "$it-fanart.jpg" }
    fun isNFO(objectKey: String): Boolean = Paths.pathExtension(objectKey).lowercase() == "nfo"
}

/**
 * Host-shared / sidecar subtitles live next to the movie object:
 * `films/Inception.2010.mkv` → `films/Inception.2010.srt`
 */
object SharedSubtitleObjectKey {
    private val subtitleExtensions = setOf("srt", "vtt", "ass", "ssa")

    /** Same directory + same basename as the movie, with a subtitle extension. */
    fun sidecarKey(movieObjectKey: String, fileExtension: String): String? {
        val movieKey = movieObjectKey.trim()
        if (movieKey.isEmpty() || movieKey.startsWith(PAIRCAST_RESERVED_PREFIX)) return null
        val base = Paths.deletingPathExtension(movieKey)
        if (base.isEmpty()) return null
        return "$base.${normalizedExtension(fileExtension)}"
    }

    fun isValid(objectKey: String): Boolean {
        val key = objectKey.trim()
        if (key.isEmpty() || key.startsWith("${PAIRCAST_RESERVED_PREFIX}avatars/")) return false
        return Paths.pathExtension(key).lowercase() in subtitleExtensions
    }

    fun isSubtitleExtension(ext: String): Boolean = ext.lowercase() in subtitleExtensions

    fun normalizedExtension(raw: String): String {
        val ext = raw.lowercase()
        return if (ext in subtitleExtensions) ext else "srt"
    }
}

/** Object keys under the user's bucket: `{prefix?}stickers/…`. */
object StickersObjectKey {
    const val FOLDER_NAME = "stickers"

    fun root(storagePrefix: String?): String = join(storagePrefix, "$FOLDER_NAME/")
    fun catalogKey(storagePrefix: String?): String = join(storagePrefix, "$FOLDER_NAME/catalog.json")

    fun packManifestKey(packId: String, storagePrefix: String?): String =
        join(storagePrefix, "$FOLDER_NAME/${sanitizePathComponent(packId)}/pack.json")

    fun assetKey(packId: String, fileName: String, storagePrefix: String?): String =
        join(storagePrefix, "$FOLDER_NAME/${sanitizePathComponent(packId)}/${sanitizeFileName(fileName)}")

    /** Joins optional storage prefix with a relative path under the bucket. */
    fun join(storagePrefix: String?, relative: String): String {
        val rel = relative.trim('/')
        val raw = storagePrefix?.trim()?.takeIf { it.isNotEmpty() } ?: return rel
        var prefix = raw.trimStart('/')
        if (!prefix.endsWith("/")) prefix += "/"
        return prefix + rel
    }

    private fun sanitizePathComponent(value: String): String {
        val filtered = value.trim().map { c -> if (c.isLetterOrDigit() || c in "-_.") c else '_' }.joinToString("")
        return filtered.ifEmpty { "pack" }
    }

    private fun sanitizeFileName(value: String): String =
        value.trim().replace("/", "_").replace("\\", "_")
}
