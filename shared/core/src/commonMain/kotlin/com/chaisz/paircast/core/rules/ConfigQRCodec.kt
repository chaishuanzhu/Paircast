package com.chaisz.paircast.core.rules

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.core.model.ObjectStorageProvider
import com.chaisz.paircast.core.support.PaircastJson
import kotlinx.serialization.Serializable

/**
 * Plaintext config payload (`v4`: `im.serverUrl`). Older `v2`/`v3` payloads (Tencent IM SDKAppID)
 * still import their storage / TMDB / subtitle settings; the IM server address is left empty.
 */
object ConfigQRCodec {
    const val PAYLOAD_TYPE = "paircast-config"
    /** Older share payloads used `tandem-config`. */
    val acceptedPayloadTypes = setOf("paircast-config", "tandem-config")
    const val MAX_ENCODED_UTF8_BYTES = 2_048

    @Serializable
    data class Payload(
        val v: Int = AppCloudConfig.CURRENT_VERSION,
        val type: String = PAYLOAD_TYPE,
        val im: IMPayload = IMPayload(),
        val storage: StoragePayload,
        val subtitleApiKey: String? = null,
        val tmdbAccessToken: String? = null,
    )

    /** `serverUrl` (v4). Legacy `sdkAppId` / `secretKey` are decoded and dropped. */
    @Serializable
    data class IMPayload(
        val serverUrl: String? = null,
        val sdkAppId: Long? = null,
        val secretKey: String? = null,
    )

    @Serializable
    data class StoragePayload(
        val provider: ObjectStorageProvider,
        val accessKey: String,
        val secretKey: String,
        val bucket: String,
        val endpoint: String,
        val region: String? = null,
        val prefix: String? = null,
        val useSSL: Boolean,
        val forcePathStyle: Boolean,
    )

    @Throws(Exception::class)
    fun encode(config: AppCloudConfig): String {
        val s = config.storage
        val payload = Payload(
            im = IMPayload(serverUrl = config.im.serverUrl),
            storage = StoragePayload(
                provider = s.provider,
                accessKey = s.accessKey,
                secretKey = s.secretKey,
                bucket = s.bucket,
                endpoint = s.endpoint,
                region = s.region,
                prefix = s.prefix,
                useSSL = s.useSSL,
                forcePathStyle = s.forcePathStyle,
            ),
            subtitleApiKey = config.subtitleApiKey,
            tmdbAccessToken = config.tmdbAccessToken,
        )
        val json = PaircastJson.default.encodeToString(Payload.serializer(), payload)
        if (json.encodeToByteArray().size > MAX_ENCODED_UTF8_BYTES) throw AppError.ConfigQRTooLarge
        return json
    }

    @Throws(Exception::class)
    fun decode(raw: String): AppCloudConfig {
        if (raw.encodeToByteArray().size > MAX_ENCODED_UTF8_BYTES) throw AppError.ConfigQRTooLarge
        val payload = try {
            PaircastJson.default.decodeFromString(Payload.serializer(), raw)
        } catch (_: Exception) {
            throw AppError.InvalidConfigQR
        }
        if (payload.type !in acceptedPayloadTypes || payload.v < 2) throw AppError.InvalidConfigQR
        val config = AppCloudConfig(
            im = IMConfig(payload.im.serverUrl.orEmpty()),
            storage = ObjectStorageConfig(
                provider = payload.storage.provider,
                accessKey = payload.storage.accessKey,
                secretKey = payload.storage.secretKey,
                bucket = payload.storage.bucket,
                endpoint = payload.storage.endpoint,
                region = payload.storage.region,
                prefix = payload.storage.prefix,
                useSSL = payload.storage.useSSL,
                forcePathStyle = payload.storage.forcePathStyle,
            ),
            subtitleApiKey = payload.subtitleApiKey,
            tmdbAccessToken = payload.tmdbAccessToken,
            configVersion = payload.v,
        )
        if (!config.storage.isComplete) throw AppError.InvalidConfigQR
        if (payload.v >= 4 && !config.im.isComplete) throw AppError.InvalidConfigQR
        return config
    }

    /** True when the payload predates GO-IM and the user still needs to enter a server address. */
    fun needsServerUrl(config: AppCloudConfig): Boolean = !config.im.isComplete

    fun maskedPreview(config: AppCloudConfig): String = listOf(
        "IM Server ${truncate(config.im.maskedSummary, 24)}",
        "Storage ${config.storage.provider.displayName}",
        "AccessKey ${maskedAccessKey(config.storage.accessKey)}",
        "Bucket ${config.storage.bucket}",
        "Endpoint ${truncate(config.storage.endpoint, 18)}",
    ).joinToString("\n")

    fun maskedAccessKey(value: String): String = maskMiddle(value, keepPrefix = 2, keepSuffix = 0)

    fun maskSecret(value: String): String = "•".repeat(value.length.coerceIn(8, 12))

    fun truncate(value: String, max: Int): String =
        if (value.length <= max) value else value.take(max - 1) + "…"

    private fun maskMiddle(value: String, keepPrefix: Int, keepSuffix: Int): String {
        if (value.length <= keepPrefix + keepSuffix) return "•".repeat(maxOf(4, value.length))
        val head = value.take(keepPrefix)
        val tail = if (keepSuffix > 0) value.takeLast(keepSuffix) else ""
        val hidden = maxOf(4, value.length - keepPrefix - keepSuffix)
        return head + "•".repeat(minOf(hidden, 8)) + tail
    }
}
