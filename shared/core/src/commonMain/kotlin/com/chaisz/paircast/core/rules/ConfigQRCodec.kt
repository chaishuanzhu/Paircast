package com.chaisz.paircast.core.rules

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.support.PaircastJson
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/**
 * Plaintext config payload (`v5`: `im.serverUrl` only). Older payloads still decode: `v4` keeps its
 * server address, `v2`/`v3` (Tencent IM) need one entered. Their object-storage / TMDB / subtitle
 * settings are ignored — the media library now lives on the server.
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
        /** Pre-v5 client-side object storage; decoded only to tell legacy payloads apart. */
        val storage: JsonElement? = null,
    )

    /** `serverUrl` (v4+). Legacy `sdkAppId` / `secretKey` are decoded and dropped. */
    @Serializable
    data class IMPayload(
        val serverUrl: String? = null,
        val sdkAppId: Long? = null,
        val secretKey: String? = null,
    )

    @Throws(Exception::class)
    fun encode(config: AppCloudConfig): String {
        val payload = Payload(im = IMPayload(serverUrl = config.im.serverUrl))
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
        val config = AppCloudConfig(im = IMConfig(payload.im.serverUrl.orEmpty()), configVersion = payload.v)
        if (payload.v >= 4 && !config.im.isComplete) throw AppError.InvalidConfigQR
        if (payload.v < 4 && payload.storage == null) throw AppError.InvalidConfigQR
        return config
    }

    /** True when the payload predates GO-IM and the user still needs to enter a server address. */
    fun needsServerUrl(config: AppCloudConfig): Boolean = !config.im.isComplete

    /** True for payloads from before v5, whose storage settings were dropped on import. */
    fun isLegacy(config: AppCloudConfig): Boolean = config.configVersion < AppCloudConfig.CURRENT_VERSION

    fun maskedPreview(config: AppCloudConfig): String = "IM Server ${truncate(config.im.maskedSummary, 32)}"

    fun truncate(value: String, max: Int): String =
        if (value.length <= max) value else value.take(max - 1) + "…"
}
