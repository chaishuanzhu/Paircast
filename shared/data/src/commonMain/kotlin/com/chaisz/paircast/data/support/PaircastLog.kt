package com.chaisz.paircast.data.support

/** Minimal logger; platforms install a [sink] (os_log / Logcat). Never log secrets or full presigned URLs. */
object PaircastLog {
    enum class Level { DEBUG, INFO, ERROR }

    var sink: ((Level, String, String) -> Unit)? = null

    fun debug(tag: String, message: String) = emit(Level.DEBUG, tag, message)
    fun info(tag: String, message: String) = emit(Level.INFO, tag, message)
    fun error(tag: String, message: String) = emit(Level.ERROR, tag, message)

    private fun emit(level: Level, tag: String, message: String) {
        sink?.invoke(level, tag, message) ?: println("[Paircast/$tag] ${level.name}: $message")
    }

    private val sensitiveQuery = setOf(
        "x-amz-signature", "x-amz-credential", "x-amz-security-token", "token", "args", "signature",
    )

    /** Keeps scheme/host/path; masks signing / token query values. */
    fun redactedUrl(url: String): String {
        val q = url.indexOf('?')
        if (q < 0) return url
        val base = url.substring(0, q)
        val query = url.substring(q + 1).split('&').joinToString("&") { pair ->
            val name = pair.substringBefore('=')
            if (name.lowercase() in sensitiveQuery) "$name=<redacted>" else pair
        }
        return "$base?$query"
    }
}
