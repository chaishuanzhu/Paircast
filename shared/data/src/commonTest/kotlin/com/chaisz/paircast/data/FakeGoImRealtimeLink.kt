@file:OptIn(com.goim.sdk.core.GoImSdkPreview::class)

package com.chaisz.paircast.data

import com.chaisz.paircast.core.gateway.ConnectionState
import com.chaisz.paircast.core.gateway.SessionEvent
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.data.goim.GoImRealtimeLink
import com.chaisz.paircast.data.secure.GoImSession as PaircastImSession
import com.goim.sdk.core.GoImSession as LiteSession
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

/** No-op link for HTTP-focused unit tests (does not open sdk-core). */
class FakeGoImRealtimeLink : GoImRealtimeLink {
    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    override val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _events = MutableSharedFlow<SessionEvent>(extraBufferCapacity = 4)
    override val events: SharedFlow<SessionEvent> = _events.asSharedFlow()

    override var onSessionEnded: ((PaircastImSession) -> Unit)? = null
    override var refreshSession: (suspend (PaircastImSession) -> PaircastImSession?)? = null

    private var session: PaircastImSession? = null
    private val _lite = MutableStateFlow<LiteSession?>(null)
    override val liteSession: StateFlow<LiteSession?> = _lite.asStateFlow()

    override val selfUid: String get() = session?.uid.orEmpty()

    override fun requireLite(): LiteSession = throw AppError.Network

    override fun liteOrNull(): LiteSession? = null

    override suspend fun connect(session: PaircastImSession) {
        this.session = session
        _state.value = ConnectionState.CONNECTED
    }

    override suspend fun disconnect() {
        session = null
        _lite.value = null
        _state.value = ConnectionState.DISCONNECTED
    }

    override fun onForeground() = Unit
}
