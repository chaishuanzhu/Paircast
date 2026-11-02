package com.chaisz.paircast.data.metadata

import com.chaisz.paircast.data.s3.Xml

/** Minimal Kodi-compatible movie NFO (title / year / plot + local art filenames). */
object MovieNfoCodec {
    data class Payload(
        val title: String,
        val year: String? = null,
        val overview: String? = null,
        val posterFileName: String? = null,
        val fanartFileName: String? = null,
    )

    fun encode(payload: Payload): String = buildList {
        add("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>""")
        add("<movie>")
        add("  <title>${Xml.escape(payload.title)}</title>")
        payload.year?.takeIf { it.isNotEmpty() }?.let { add("  <year>${Xml.escape(it)}</year>") }
        payload.overview?.takeIf { it.isNotEmpty() }?.let { add("  <plot>${Xml.escape(it)}</plot>") }
        payload.posterFileName?.takeIf { it.isNotEmpty() }?.let { add("  <thumb aspect=\"poster\">${Xml.escape(it)}</thumb>") }
        payload.fanartFileName?.takeIf { it.isNotEmpty() }?.let {
            add("  <fanart>")
            add("    <thumb>${Xml.escape(it)}</thumb>")
            add("  </fanart>")
        }
        add("</movie>")
        add("")
    }.joinToString("\n")

    private val fanartBlock = Regex("<fanart\\b[^>]*>(.*?)</fanart>", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE))
    private val thumb = Regex("<thumb\\b([^>]*)>(.*?)</thumb>", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE))
    private val aspect = Regex("aspect\\s*=\\s*\"([^\"]*)\"", RegexOption.IGNORE_CASE)

    fun decode(xml: String): Payload? {
        if (!xml.contains("<movie", ignoreCase = true)) return null
        val title = Xml.element(xml, "title")?.takeIf { it.isNotEmpty() } ?: return null
        val fanart = fanartBlock.find(xml)?.groupValues?.get(1)
        val fanartFile = fanart?.let { block -> thumb.find(block)?.groupValues?.get(2)?.let(Xml::unescape)?.trim()?.takeIf { it.isNotEmpty() } }
        val outside = fanartBlock.replace(xml, "")
        val posterFile = thumb.findAll(outside).firstNotNullOfOrNull { m ->
            val a = aspect.find(m.groupValues[1])?.groupValues?.get(1)?.lowercase()
            val text = Xml.unescape(m.groupValues[2]).trim()
            text.takeIf { it.isNotEmpty() && (a == null || a == "poster") }
        }
        return Payload(
            title = title,
            year = Xml.element(xml, "year")?.takeIf { it.isNotEmpty() },
            overview = Xml.element(xml, "plot")?.takeIf { it.isNotEmpty() },
            posterFileName = posterFile,
            fanartFileName = fanartFile,
        )
    }
}
