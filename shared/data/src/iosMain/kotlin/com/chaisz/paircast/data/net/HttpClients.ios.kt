package com.chaisz.paircast.data.net

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.darwin.Darwin

internal actual fun defaultHttpEngine(): HttpClientEngine = Darwin.create()

actual val platformName: String = "ios"
