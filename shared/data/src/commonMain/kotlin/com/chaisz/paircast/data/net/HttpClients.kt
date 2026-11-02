package com.chaisz.paircast.data.net

import io.ktor.client.HttpClient
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json

internal val apiJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
}

/** OkHttp (Android) or Darwin (iOS). */
internal expect fun defaultHttpEngine(): HttpClientEngine

/** `ios` / `android` — sent to GO-IM as the WebSocket `platform` parameter. */
expect val platformName: String

/** One shared client for REST + WebSocket + object storage. Per-request timeouts are set by callers. */
fun createHttpClient(engine: HttpClientEngine = defaultHttpEngine()): HttpClient = HttpClient(engine) {
    expectSuccess = false
    install(ContentNegotiation) { json(apiJson) }
    install(WebSockets)
    install(HttpTimeout) {
        connectTimeoutMillis = 15_000
        requestTimeoutMillis = 60_000
        socketTimeoutMillis = 60_000
    }
}
