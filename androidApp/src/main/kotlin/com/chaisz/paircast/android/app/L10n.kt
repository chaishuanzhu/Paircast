package com.chaisz.paircast.android.app

import android.content.Context
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.UiText
import org.json.JSONObject
import java.util.Locale

/**
 * String lookup backed by the iOS `Localizable.xcstrings` catalog (copied into assets at build
 * time). Keys are English templates with `{{name}}` placeholders, shared with Kotlin `UiText`.
 */
object L10n {
    @Volatile private var zh: Map<String, String> = emptyMap()
    @Volatile var useChinese: Boolean = Locale.getDefault().language == "zh"

    fun load(context: Context) {
        val json = runCatching {
            context.assets.open("Localizable.xcstrings").bufferedReader().use { it.readText() }
        }.getOrNull() ?: return
        val strings = JSONObject(json).optJSONObject("strings") ?: return
        val map = HashMap<String, String>(strings.length())
        for (key in strings.keys()) {
            val value = strings.optJSONObject(key)
                ?.optJSONObject("localizations")
                ?.optJSONObject("zh-Hans")
                ?.optJSONObject("stringUnit")
                ?.optString("value")
            if (!value.isNullOrEmpty()) map[key] = value
        }
        zh = map
    }

    fun string(key: String): String = if (useChinese) zh[key] ?: key else key

    fun format(key: String, args: Map<String, String> = emptyMap()): String =
        args.entries.fold(string(key)) { acc, (name, value) -> acc.replace("{{$name}}", value) }

    fun format(text: UiText): String = format(text.key, text.args)

    fun format(error: AppError): String {
        if (error is AppError.IncompleteConfig) {
            val separator = if (useChinese) "、" else ", "
            return format(error.localizationKey, mapOf("fields" to error.missing.joinToString(separator, transform = ::configField)))
        }
        return format(error.localizationKey, error.localizationArguments)
    }

    fun message(error: Throwable, fallback: AppError = AppError.Network): String =
        format(AppError.from(error, fallback))

    private fun configField(field: String): String {
        string(field).let { if (it != field) return it }
        val space = field.lastIndexOf(' ')
        if (space < 0) return string(field)
        return field.substring(0, space) + " " + string(field.substring(space + 1))
    }
}

/** Shorthand for UI code. */
fun t(key: String, vararg args: Pair<String, String>): String = L10n.format(key, args.toMap())
