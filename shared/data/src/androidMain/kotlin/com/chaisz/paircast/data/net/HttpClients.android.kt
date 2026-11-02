package com.chaisz.paircast.data.net

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp

internal actual fun defaultHttpEngine(): HttpClientEngine = OkHttp.create()

actual val platformName: String = "android"
