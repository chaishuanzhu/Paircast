package com.chaisz.paircast.data.secure

import com.chaisz.paircast.core.gateway.ConfigGateway
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.store.SecureStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private val storeJson = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

/**
 * Cloud config in [SecureStore] (`paircast.cloud-config.v4` key kept for upgrades). Only the
 * GO-IM server URL is stored; storage keys left by pre-2.1 builds are purged on first load.
 */
class SecureConfigStore(private val store: SecureStore) : ConfigGateway {
    @Serializable
    private data class StoredConfig(
        val serverUrl: String = "",
        val updatedAtMs: Long = 0,
        val configVersion: Int = AppCloudConfig.CURRENT_VERSION,
    )

    override suspend fun load(): AppCloudConfig? {
        val raw = store.read(CONFIG_KEY) ?: return null
        val s = runCatching { storeJson.decodeFromString(StoredConfig.serializer(), raw) }.getOrNull() ?: return null
        val config = AppCloudConfig(
            im = IMConfig(s.serverUrl),
            updatedAtMs = s.updatedAtMs,
            configVersion = AppCloudConfig.CURRENT_VERSION,
        )
        if (LEGACY_SECRET_FIELDS.any { "\"$it\"" in raw } || s.configVersion < AppCloudConfig.CURRENT_VERSION) save(config)
        return config
    }

    override suspend fun save(config: AppCloudConfig) {
        val stored = StoredConfig(
            serverUrl = config.im.serverUrl,
            updatedAtMs = config.updatedAtMs,
            configVersion = AppCloudConfig.CURRENT_VERSION,
        )
        store.write(CONFIG_KEY, storeJson.encodeToString(StoredConfig.serializer(), stored))
    }

    override suspend fun clearAll() {
        store.delete(CONFIG_KEY)
        store.delete(SessionStore.SESSION_KEY)
    }

    companion object {
        const val CONFIG_KEY = "paircast.cloud-config.v4"
        private val LEGACY_SECRET_FIELDS = listOf("accessKey", "secretKey", "subtitleApiKey", "tmdbAccessToken")
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
