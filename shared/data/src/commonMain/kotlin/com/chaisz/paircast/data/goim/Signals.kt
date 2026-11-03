package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.support.PaircastJson
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/** Paircast signal types carried by GO-IM `CmdSignal`. */
object PaircastSignal {
    /** Client → room members: play / pause / seek / rate, host transfer, subtitle switch. */
    const val PLAYBACK = "paircast.playback"

    /** Paircast server → room members: room snapshot (`data` = `{"group_id","room"}`). */
    const val ROOM_UPDATED = "paircast.room_updated"
}

/** GO-IM `CmdSignal` content: `{"type":"<ns>.<name>","data":{...}}`; the gateway drops untyped signals. */
@Serializable
internal data class SignalEnvelope(val type: String, val data: JsonElement? = null)

internal object SignalCodec {
    fun <T> encode(type: String, serializer: KSerializer<T>, data: T): String =
        PaircastJson.default.encodeToString(
            SignalEnvelope.serializer(),
            SignalEnvelope(type, PaircastJson.default.encodeToJsonElement(serializer, data)),
        )

    /** Decodes [content] when its type is [type]; null for other types or malformed payloads. */
    fun <T> decode(content: String, type: String, serializer: KSerializer<T>): T? {
        val envelope = runCatching { PaircastJson.default.decodeFromString(SignalEnvelope.serializer(), content) }.getOrNull()
        if (envelope?.type != type) return null
        val data = envelope.data ?: return null
        return runCatching { PaircastJson.default.decodeFromJsonElement(serializer, data) }.getOrNull()
    }
}
