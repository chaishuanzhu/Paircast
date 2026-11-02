package com.chaisz.paircast.core.support

/** Twemoji helpers — wire format stays Unicode; clients render bundled PNGs, then CDN. */
object Twemoji {
    const val VERSION = "15.1.0"
    const val CDN_BASE = "https://raw.githubusercontent.com/jdecked/twemoji/v$VERSION/assets/72x72/"

    /** Curated picker list (Unicode inserted into the draft). */
    val pickerEmojis: List<String> = listOf(
        "😀", "😂", "🥰", "😍", "🤔", "😎", "😭", "😡",
        "👍", "👎", "👏", "🙏", "🔥", "✨", "🎉", "❤️",
        "😊", "🤗", "😴", "🤝", "💪", "🌟", "💯", "😅",
        "🤣", "😘", "😜", "🥺", "😱", "🙄", "😇", "🤩",
        "😢", "😤", "🥳", "😋", "😏", "😌", "😳", "🤭",
        "👋", "✌️", "🤞", "👀", "💬", "🎵", "🍿", "🎬",
    )

    /** Twemoji `grabTheRightIcon`: hyphenated hex codepoints, U+FE0F stripped unless the glyph has a ZWJ. */
    fun codepoints(emoji: String): String {
        val scalars = codePoints(emoji)
        val hasZwj = scalars.contains(0x200D)
        val filtered = scalars.filter { hasZwj || it != 0xFE0F }.ifEmpty { scalars }
        return filtered.joinToString("-") { it.toString(16) }
    }

    fun imageUrl(emoji: String): String? = codepoints(emoji).takeIf { it.isNotEmpty() }?.let { "$CDN_BASE$it.png" }

    private fun codePoints(s: String): List<Int> {
        val out = ArrayList<Int>(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c.isHighSurrogate() && i + 1 < s.length && s[i + 1].isLowSurrogate()) {
                out += ((c.code - 0xD800) shl 10) + (s[i + 1].code - 0xDC00) + 0x10000
                i += 2
            } else {
                out += c.code
                i++
            }
        }
        return out
    }
}
