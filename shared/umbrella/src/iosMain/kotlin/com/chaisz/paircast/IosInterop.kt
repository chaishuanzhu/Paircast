package com.chaisz.paircast

import com.chaisz.paircast.data.support.PaircastLog
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.Foundation.create
import platform.posix.memcpy

/** Swift ↔ Kotlin byte bridging and logging hooks. */
object IosInterop {
    @OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
    fun toByteArray(data: NSData): ByteArray {
        val size = data.length.toInt()
        val bytes = ByteArray(size)
        if (size > 0) bytes.usePinned { memcpy(it.addressOf(0), data.bytes, data.length) }
        return bytes
    }

    @OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
    fun toData(bytes: ByteArray): NSData {
        if (bytes.isEmpty()) return NSData()
        return bytes.usePinned { NSData.create(bytes = it.addressOf(0), length = bytes.size.toULong()) }
    }

    /** Routes shared-module logs to os_log; level is `debug` / `info` / `error`. */
    fun installLogSink(sink: (level: String, tag: String, message: String) -> Unit) {
        PaircastLog.sink = { level, tag, message -> sink(level.name.lowercase(), tag, message) }
    }
}
