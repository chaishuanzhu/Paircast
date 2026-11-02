package com.chaisz.paircast.data.subtitles

/** Legacy subtitle encodings we try besides UTF-8 / UTF-16. */
internal enum class LegacyCharset { GB18030, BIG5, LATIN1, CP1252 }

/** Platform decoder (Charset / CFStringEncoding); null when the bytes are invalid for it. */
internal expect fun decodeLegacy(bytes: ByteArray, charset: LegacyCharset): String?

/** Detects common subtitle encodings and re-encodes as UTF-8 (with BOM for VLC). */
object SubtitleEncodingNormalizer {
    private val BOM = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())

    fun utf8Text(raw: ByteArray): String {
        if (raw.isEmpty()) return ""
        val candidates = buildList<() -> String?> {
            add { runCatching { stripBom(raw).decodeToString(throwOnInvalidSequence = true) }.getOrNull() }
            add { decodeLegacy(raw, LegacyCharset.GB18030) }
            add { decodeLegacy(raw, LegacyCharset.BIG5) }
            add { decodeUtf16(raw, littleEndian = true) }
            add { decodeUtf16(raw, littleEndian = false) }
            add { decodeLegacy(raw, LegacyCharset.LATIN1) }
            add { decodeLegacy(raw, LegacyCharset.CP1252) }
        }
        var best: Pair<Int, String>? = null
        for (candidate in candidates) {
            val text = runCatching { candidate() }.getOrNull() ?: continue
            val score = score(text)
            if (best == null || score > best.first) best = score to text
        }
        return (best?.second ?: raw.decodeToString()).removePrefix("\uFEFF")
    }

    /** UTF-8 bytes prefixed with a BOM (helps the VLC subtitle decoder pick UTF-8). */
    fun utf8BytesWithBom(raw: ByteArray): ByteArray = BOM + utf8Text(raw).encodeToByteArray()

    internal fun score(text: String): Int {
        var cjk = 0
        var replacement = 0
        var weird = 0
        for (ch in text) {
            val v = ch.code
            when {
                v in 0x4E00..0x9FFF || v in 0x3400..0x4DBF || v in 0xF900..0xFAFF -> cjk++
                v == 0xFFFD -> replacement++
                v < 0x20 && v != 0x0A && v != 0x0D && v != 0x09 -> weird++
                v in 0x80..0x9F -> weird++
            }
        }
        var score = minOf(cjk * 3, 600) - replacement * 8 - weird * 3
        if ("-->" in text) score += 20
        if ("[Script Info]" in text || "Dialogue:" in text) score += 20
        if ('\u0000' in text) score -= 50
        return score
    }

    private fun stripBom(raw: ByteArray): ByteArray =
        if (raw.size >= 3 && raw[0] == BOM[0] && raw[1] == BOM[1] && raw[2] == BOM[2]) raw.copyOfRange(3, raw.size) else raw

    private fun decodeUtf16(raw: ByteArray, littleEndian: Boolean): String? {
        if (raw.size % 2 != 0) return null
        val chars = CharArray(raw.size / 2) { i ->
            val a = raw[i * 2].toInt() and 0xFF
            val b = raw[i * 2 + 1].toInt() and 0xFF
            (if (littleEndian) (b shl 8) or a else (a shl 8) or b).toChar()
        }
        return chars.concatToString()
    }
}
