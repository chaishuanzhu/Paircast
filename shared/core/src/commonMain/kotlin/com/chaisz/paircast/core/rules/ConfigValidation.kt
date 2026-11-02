package com.chaisz.paircast.core.rules

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig

object ConfigValidation {
    fun missingFields(config: AppCloudConfig): List<String> = buildList {
        if (!config.im.isComplete) add("IM Server")
    }

    @Throws(Exception::class)
    fun validate(config: AppCloudConfig) {
        val missing = missingFields(config)
        if (missing.isNotEmpty()) throw AppError.IncompleteConfig(missing)
    }

    @Throws(Exception::class)
    fun normalized(config: AppCloudConfig): AppCloudConfig {
        validate(config)
        return config.copy(im = IMConfig(normalizedServerUrl(config.im.serverUrl)!!))
    }

    /**
     * `im.example.com` → `https://im.example.com`; keeps explicit `http://` (LAN) and port.
     * Strips path / query / trailing slash. Returns null when no host is present.
     */
    fun normalizedServerUrl(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val lower = trimmed.lowercase()
        val scheme = when {
            lower.startsWith("https://") -> "https"
            lower.startsWith("http://") -> "http"
            lower.startsWith("wss://") -> "https"
            lower.startsWith("ws://") -> "http"
            "://" in lower -> return null
            else -> "https"
        }
        val rest = trimmed.substringAfter("://", trimmed)
        val host = rest.substringBefore('/').substringBefore('?').substringBefore('#').trim()
        if (host.isEmpty() || host.any { it.isWhitespace() }) return null
        return "$scheme://$host"
    }
}
