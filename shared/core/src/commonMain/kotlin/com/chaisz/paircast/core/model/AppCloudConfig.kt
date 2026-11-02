package com.chaisz.paircast.core.model

import com.chaisz.paircast.core.rules.ConfigValidation
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

data class AppCloudConfig(
    val im: IMConfig,
    val storage: ObjectStorageConfig,
    val subtitleApiKey: String? = null,
    val tmdbAccessToken: String? = null,
    val updatedAtMs: Long = 0,
    val configVersion: Int = CURRENT_VERSION,
) {
    val isComplete: Boolean get() = im.isComplete && storage.isComplete

    companion object {
        const val CURRENT_VERSION = 4

        fun empty(): AppCloudConfig = AppCloudConfig(
            im = IMConfig(""),
            storage = ObjectStorageConfig(accessKey = "", secretKey = "", bucket = "", endpoint = ""),
        )
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

@Serializable
enum class ObjectStorageProvider(val rawValue: String) {
    @SerialName("qiniu") QINIU("qiniu"),
    @SerialName("aliyunOSS") ALIYUN_OSS("aliyunOSS"),
    @SerialName("tencentCOS") TENCENT_COS("tencentCOS"),
    @SerialName("minio") MINIO("minio"),
    ;

    val displayName: String
        get() = when (this) {
            QINIU -> "Qiniu"
            ALIYUN_OSS -> "Alibaba Cloud OSS"
            TENCENT_COS -> "Tencent Cloud COS"
            MINIO -> "MinIO"
        }

    val endpointPlaceholder: String
        get() = when (this) {
            QINIU -> "s3.cn-south-1.qiniucs.com"
            ALIYUN_OSS -> "oss-cn-hangzhou.aliyuncs.com"
            TENCENT_COS -> "cos.ap-guangzhou.myqcloud.com"
            MINIO -> "192.168.1.10:9000"
        }

    val regionPlaceholder: String
        get() = when (this) {
            QINIU -> "cn-south-1"
            ALIYUN_OSS -> "cn-hangzhou"
            TENCENT_COS -> "ap-guangzhou"
            MINIO -> "us-east-1"
        }

    val defaultUseSSL: Boolean get() = this != MINIO
    val defaultForcePathStyle: Boolean get() = true
    val defaultRegion: String? get() = if (this == MINIO) "us-east-1" else null

    companion object {
        fun fromRaw(raw: String?): ObjectStorageProvider? = entries.firstOrNull { it.rawValue == raw }
    }
}

data class ObjectStorageConfig(
    val provider: ObjectStorageProvider = ObjectStorageProvider.QINIU,
    val accessKey: String,
    val secretKey: String,
    val bucket: String,
    /** API host, optionally with port (`minio.local:9000`). No scheme/path. */
    val endpoint: String,
    val region: String? = null,
    val prefix: String? = null,
    val useSSL: Boolean = provider.defaultUseSSL,
    val forcePathStyle: Boolean = provider.defaultForcePathStyle,
) {
    val isComplete: Boolean
        get() = listOf(accessKey, secretKey, bucket, endpoint).all { it.isNotBlank() }

    /** Region used for AWS SigV4. Explicit config wins; otherwise infer from endpoint / provider. */
    val signingRegion: String
        get() = region?.trim()?.takeIf { it.isNotEmpty() } ?: inferredRegion(provider, endpoint)

    companion object {
        private val qiniuRegex = Regex("^s3[.-]([a-z0-9-]+)\\.")
        private val ossRegex = Regex("^oss-([a-z0-9-]+)\\.")
        private val cosRegex = Regex("^cos\\.([a-z0-9-]+)\\.")

        fun inferredRegion(provider: ObjectStorageProvider, endpoint: String): String {
            val host = ConfigValidation.normalizedHost(endpoint).lowercase()
            return when (provider) {
                ObjectStorageProvider.QINIU -> qiniuRegex.find(host)?.groupValues?.get(1) ?: "cn-east-1"
                ObjectStorageProvider.ALIYUN_OSS -> ossRegex.find(host)?.groupValues?.get(1) ?: "cn-hangzhou"
                ObjectStorageProvider.TENCENT_COS -> cosRegex.find(host)?.groupValues?.get(1) ?: "ap-guangzhou"
                ObjectStorageProvider.MINIO -> "us-east-1"
            }
        }
    }
}
