package com.chaisz.paircast.data.config

import com.chaisz.paircast.core.gateway.ConfigLinkCodec
import com.chaisz.paircast.core.model.AppCloudConfig
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.rules.ConfigQRCodec
import dev.whyoleg.cryptography.CryptographyProvider
import dev.whyoleg.cryptography.algorithms.AES
import dev.whyoleg.cryptography.algorithms.SHA256
import kotlin.io.encoding.Base64

/**
 * `paircast://config?args=<base64url(AES-GCM combined: nonce‖ciphertext‖tag)>`.
 * The app-embedded key is transport obfuscation only. v5 payloads carry just the server URL;
 * older links may still contain storage keys, which are decoded and discarded.
 */
object ConfigShareLink : ConfigLinkCodec {
    const val URL_SCHEME = "paircast"
    const val URL_HOST = "config"
    const val ARGS_QUERY_NAME = "args"
    const val MAX_ARGS_UTF8_BYTES = 3_500

    /** Historical key material — must stay stable so existing `args` still decrypt. */
    private val keyBytes by lazy { CryptographyProvider.Default.get(SHA256).hasher().hashBlocking("Tandem.iOS.ConfigShare.v1".encodeToByteArray()) }
    private val cipher by lazy {
        CryptographyProvider.Default.get(AES.GCM).keyDecoder()
            .decodeFromByteArrayBlocking(AES.Key.Format.RAW, keyBytes)
            .cipher()
    }
    private val base64Url = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT_OPTIONAL)

    override fun shareUrl(config: AppCloudConfig): String = "$URL_SCHEME://$URL_HOST?$ARGS_QUERY_NAME=${encodeArgs(config)}"

    fun encodeArgs(config: AppCloudConfig): String {
        val sealed = cipher.encryptBlocking(ConfigQRCodec.encode(config).encodeToByteArray())
        val args = base64Url.encode(sealed).trimEnd('=')
        if (args.encodeToByteArray().size > MAX_ARGS_UTF8_BYTES) throw AppError.ConfigQRTooLarge
        return args
    }

    override fun decode(input: String): AppCloudConfig {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) throw AppError.InvalidConfigQR
        extractArgs(trimmed)?.let { return decodeArgs(it) }
        if (trimmed.startsWith("{")) return ConfigQRCodec.decode(trimmed)
        return decodeArgs(trimmed)
    }

    fun isConfigShareUrl(url: String): Boolean = url.trim().lowercase().startsWith("$URL_SCHEME://$URL_HOST")

    fun decodeArgs(args: String): AppCloudConfig {
        if (args.encodeToByteArray().size > MAX_ARGS_UTF8_BYTES) throw AppError.ConfigQRTooLarge
        val data = runCatching { base64Url.decode(args) }.getOrNull() ?: throw AppError.InvalidConfigQR
        val plaintext = runCatching { cipher.decryptBlocking(data) }.getOrNull() ?: throw AppError.InvalidConfigQR
        return ConfigQRCodec.decode(plaintext.decodeToString())
    }

    /** `args` from a share URL, possibly embedded in pasted chat text. */
    private fun extractArgs(text: String): String? {
        val needle = "$URL_SCHEME://$URL_HOST"
        val start = text.indexOf(needle, ignoreCase = true)
        if (start < 0) return null
        val url = text.substring(start).takeWhile { !it.isWhitespace() && it != '"' }
        val query = url.substringAfter('?', "")
        val raw = query.split('&').firstOrNull { it.substringBefore('=') == ARGS_QUERY_NAME }?.substringAfter('=', "")
        if (raw.isNullOrEmpty()) throw AppError.InvalidConfigQR
        return percentDecode(raw)
    }

    private fun percentDecode(s: String): String {
        if ('%' !in s) return s
        val out = ArrayList<Byte>(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%' && i + 2 < s.length) {
                val v = s.substring(i + 1, i + 3).toIntOrNull(16)
                if (v != null) {
                    out += v.toByte()
                    i += 3
                    continue
                }
            }
            out += c.toString().encodeToByteArray().toList()
            i++
        }
        return out.toByteArray().decodeToString()
    }
}
