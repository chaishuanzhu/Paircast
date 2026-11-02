package com.chaisz.paircast.data.subtitles

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

internal actual fun decodeLegacy(bytes: ByteArray, charset: LegacyCharset): String? {
    val name = when (charset) {
        LegacyCharset.GB18030 -> "GB18030"
        LegacyCharset.BIG5 -> "Big5"
        LegacyCharset.LATIN1 -> "ISO-8859-1"
        LegacyCharset.CP1252 -> "windows-1252"
    }
    val cs = runCatching { Charset.forName(name) }.getOrNull() ?: return null
    return try {
        cs.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }
}
