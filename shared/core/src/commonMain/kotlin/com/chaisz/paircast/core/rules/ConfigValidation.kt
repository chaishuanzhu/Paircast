package com.chaisz.paircast.core.rules

import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.IMConfig
import com.chaisz.paircast.core.model.ObjectStorageConfig
import com.chaisz.paircast.core.model.ObjectStorageProvider

object ConfigValidation {
    fun missingFields(config: AppCloudConfig): List<String> = buildList {
        if (!config.im.isComplete) add("IM Server")
        val label = config.storage.provider.displayName
        if (config.storage.accessKey.isEmpty()) add("$label AccessKey")
        if (config.storage.secretKey.isEmpty()) add("$label SecretKey")
        if (config.storage.bucket.isEmpty()) add("$label Bucket")
        if (config.storage.endpoint.isEmpty()) add("$label Endpoint")
    }

    @Throws(Exception::class)
    fun validate(config: AppCloudConfig) {
        val missing = missingFields(config)
        if (missing.isNotEmpty()) throw AppError.IncompleteConfig(missing)
        normalizedStorage(config.storage)
    }

    @Throws(Exception::class)
    fun normalized(config: AppCloudConfig): AppCloudConfig {
        validate(config)
        return config.copy(
            im = IMConfig(normalizedServerUrl(config.im.serverUrl)!!),
            storage = normalizedStorage(config.storage),
            subtitleApiKey = config.subtitleApiKey?.trim()?.ifEmpty { null },
            tmdbAccessToken = config.tmdbAccessToken?.trim()?.ifEmpty { null },
        )
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

    @Throws(Exception::class)
    fun normalizedStorage(storage: ObjectStorageConfig): ObjectStorageConfig {
        val endpoint = validatedEndpoint(storage.endpoint, storage.provider)
        val region = storage.region?.trim()
        return ObjectStorageConfig(
            provider = storage.provider,
            accessKey = storage.accessKey.trim(),
            secretKey = storage.secretKey.trim(),
            bucket = storage.bucket.trim(),
            endpoint = endpoint,
            region = if (!region.isNullOrEmpty()) region else storage.provider.defaultRegion,
            prefix = storage.prefix?.trim()?.ifEmpty { null },
            useSSL = storage.useSSL,
            forcePathStyle = storage.forcePathStyle,
        )
    }

    /** Host (+ optional port): `https://s3.cn-south-1.qiniucs.com/path` → `s3.cn-south-1.qiniucs.com` */
    fun normalizedHost(raw: String): String {
        var s = raw.trim()
        if (s.startsWith("https://", ignoreCase = true)) s = s.substring(8)
        if (s.startsWith("http://", ignoreCase = true)) s = s.substring(7)
        return s.split('/').firstOrNull { it.isNotEmpty() } ?: ""
    }

    fun isAPIEndpointHost(host: String, provider: ObjectStorageProvider): Boolean {
        val h = normalizedHost(host).lowercase()
        return when (provider) {
            ObjectStorageProvider.QINIU -> "qiniucs.com" in h && (h.startsWith("s3.") || h.startsWith("s3-"))
            ObjectStorageProvider.ALIYUN_OSS -> "aliyuncs.com" in h && h.startsWith("oss-")
            ObjectStorageProvider.TENCENT_COS -> "myqcloud.com" in h && h.startsWith("cos.")
            ObjectStorageProvider.MINIO -> h.isNotEmpty()
        }
    }

    @Throws(Exception::class)
    fun validatedEndpoint(raw: String, provider: ObjectStorageProvider): String {
        val host = normalizedHost(raw)
        if (host.isEmpty()) throw AppError.IncompleteConfig(listOf("${provider.displayName} Endpoint"))
        if (!isAPIEndpointHost(host, provider)) {
            throw AppError.Validation(endpointHint(provider), mapOf("example" to provider.endpointPlaceholder))
        }
        return host
    }

    private fun endpointHint(provider: ObjectStorageProvider): String = when (provider) {
        ObjectStorageProvider.QINIU -> "Endpoint must be a Qiniu S3 host (e.g. {{example}})"
        ObjectStorageProvider.ALIYUN_OSS -> "Endpoint must be an Alibaba Cloud OSS host (e.g. {{example}})"
        ObjectStorageProvider.TENCENT_COS -> "Endpoint must be a Tencent Cloud COS host (e.g. {{example}})"
        ObjectStorageProvider.MINIO -> "Endpoint must be a MinIO host (e.g. {{example}})"
    }
}
