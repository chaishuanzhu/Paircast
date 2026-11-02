package com.chaisz.paircast.data.secure

import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.core.model.ObjectStorageProvider
import com.chaisz.paircast.core.store.SecureStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private val storeJson = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

/** Cloud config in [SecureStore] (`paircast.cloud-config.v4`). */
class SecureConfigStore(private val store: SecureStore) : ConfigGateway {
    @Serializable
    private data class StoredConfig(
        val serverUrl: String = "",
        val provider: String = ObjectStorageProvider.QINIU.rawValue,
        val accessKey: String,
        val secretKey: String,
        val bucket: String,
        val endpoint: String,
        val region: String? = null,
        val prefix: String? = null,
        val useSSL: Boolean = true,
        val forcePathStyle: Boolean = true,
        val subtitleApiKey: String? = null,
        val tmdbAccessToken: String? = null,
        val updatedAtMs: Long = 0,
        val configVersion: Int = AppCloudConfig.CURRENT_VERSION,
    )

    override suspend fun load(): AppCloudConfig? {
        val raw = store.read(CONFIG_KEY) ?: return null
        val s = runCatching { storeJson.decodeFromString(StoredConfig.serializer(), raw) }.getOrNull() ?: return null
        return AppCloudConfig(
            im = IMConfig(s.serverUrl),
            storage = ObjectStorageConfig(
                provider = ObjectStorageProvider.fromRaw(s.provider) ?: ObjectStorageProvider.QINIU,
                accessKey = s.accessKey,
                secretKey = s.secretKey,
                bucket = s.bucket,
                endpoint = s.endpoint,
                region = s.region,
                prefix = s.prefix,
                useSSL = s.useSSL,
                forcePathStyle = s.forcePathStyle,
            ),
            subtitleApiKey = s.subtitleApiKey,
            tmdbAccessToken = s.tmdbAccessToken,
            updatedAtMs = s.updatedAtMs,
            configVersion = s.configVersion,
        )
    }

    override suspend fun save(config: AppCloudConfig) {
        val st = config.storage
        val stored = StoredConfig(
            serverUrl = config.im.serverUrl,
            provider = st.provider.rawValue,
            accessKey = st.accessKey,
            secretKey = st.secretKey,
            bucket = st.bucket,
            endpoint = st.endpoint,
            region = st.region,
            prefix = st.prefix,
            useSSL = st.useSSL,
            forcePathStyle = st.forcePathStyle,
            subtitleApiKey = config.subtitleApiKey,
            tmdbAccessToken = config.tmdbAccessToken,
            updatedAtMs = config.updatedAtMs,
            configVersion = config.configVersion,
        )
        store.write(CONFIG_KEY, storeJson.encodeToString(StoredConfig.serializer(), stored))
    }

    override suspend fun clearAll() {
        store.delete(CONFIG_KEY)
        store.delete(SessionStore.SESSION_KEY)
    }

    companion object {
        const val CONFIG_KEY = "paircast.cloud-config.v4"
    }
}

/** Persisted GO-IM login (`uid` + JWT) bound to the server it was issued by. */
@Serializable
data class GoImSession(val serverUrl: String, val uid: String, val token: String)

class SessionStore(private val store: SecureStore) {
    fun load(): GoImSession? =
        store.read(SESSION_KEY)?.let { runCatching { storeJson.decodeFromString(GoImSession.serializer(), it) }.getOrNull() }

    fun save(session: GoImSession) = store.write(SESSION_KEY, storeJson.encodeToString(GoImSession.serializer(), session))

    fun clear() = store.delete(SESSION_KEY)

    /** Stable per-install device id for GO-IM multi-device policy. */
    fun deviceId(generate: () -> String): String =
        store.read(DEVICE_KEY) ?: generate().also { store.write(DEVICE_KEY, it) }

    companion object {
        const val SESSION_KEY = "paircast.goim.session"
        const val DEVICE_KEY = "paircast.goim.device-id"
    }
}
