package com.chaisz.paircast.data.subtitles

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import platform.CoreFoundation.kCFStringEncodingBig5
import platform.CoreFoundation.kCFStringEncodingGB_18030_2000
import platform.Foundation.NSData
import platform.Foundation.NSISOLatin1StringEncoding
import platform.Foundation.NSString
import platform.Foundation.NSWindowsCP1252StringEncoding
import platform.Foundation.create

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal actual fun decodeLegacy(bytes: ByteArray, charset: LegacyCharset): String? {
    val encoding = when (charset) {
        LegacyCharset.GB18030 -> CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000.toUInt())
        LegacyCharset.BIG5 -> CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5.toUInt())
        LegacyCharset.LATIN1 -> NSISOLatin1StringEncoding
        LegacyCharset.CP1252 -> NSWindowsCP1252StringEncoding
    }
    if (bytes.isEmpty()) return ""
    val data = bytes.usePinned { NSData.create(bytes = it.addressOf(0), length = bytes.size.toULong()) }
    @Suppress("CAST_NEVER_SUCCEEDS")
    return NSString.create(data = data, encoding = encoding)?.let { it as String }
}
