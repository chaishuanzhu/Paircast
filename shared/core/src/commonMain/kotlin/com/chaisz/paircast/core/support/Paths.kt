package com.chaisz.paircast.core.support

/** `NSString` path helpers (`pathExtension`, `deletingPathExtension`, `lastPathComponent`). */
object Paths {
    fun lastPathComponent(path: String): String {
        val trimmed = path.trimEnd('/')
        if (trimmed.isEmpty()) return if (path.startsWith("/")) "/" else ""
        return trimmed.substringAfterLast('/')
    }

    fun pathExtension(path: String): String {
        val last = lastPathComponent(path)
        val dot = last.lastIndexOf('.')
        if (dot <= 0 || dot == last.length - 1) return ""
        return last.substring(dot + 1)
    }

    fun deletingPathExtension(path: String): String {
        val ext = pathExtension(path)
        val trimmed = path.trimEnd('/')
        if (ext.isEmpty()) return trimmed
        return trimmed.dropLast(ext.length + 1)
    }
}
