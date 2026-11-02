package com.chaisz.paircast.core.model

import com.chaisz.paircast.core.rules.ConfigValidation

/**
 * Client config (`v5`): only the GO-IM gateway address. The media library (video sources, TMDB,
 * OpenSubtitles keys) is configured on the server and reached through `/media/…`.
 */
data class AppCloudConfig(
    val im: IMConfig,
    val updatedAtMs: Long = 0,
    val configVersion: Int = CURRENT_VERSION,
) {
    val isComplete: Boolean get() = im.isComplete

    companion object {
        const val CURRENT_VERSION = 5

        fun empty(): AppCloudConfig = AppCloudConfig(im = IMConfig(""))
    }
}

/** Self-hosted GO-IM gateway. Accounts are provisioned by the server admin. */
data class IMConfig(val serverUrl: String) {
    val isComplete: Boolean get() = ConfigValidation.normalizedServerUrl(serverUrl) != null

    val maskedSummary: String
        get() = ConfigValidation.normalizedServerUrl(serverUrl)
            ?.substringAfter("://")
            ?: "—"
}
