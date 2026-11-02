package com.chaisz.paircast.core.support

import kotlinx.serialization.json.Json

object PaircastJson {
    /** Omits nulls (matches Swift `JSONEncoder` for optionals), tolerates unknown keys. */
    val default: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
        coerceInputValues = true
    }
}
