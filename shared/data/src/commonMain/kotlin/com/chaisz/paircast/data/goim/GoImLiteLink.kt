@file:OptIn(GoImSdkPreview::class)

package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.ConnectionState
import com.chaisz.paircast.core.gateway.SessionEvent
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.data.secure.GoImSession as PaircastImSession
import com.goim.kmp.common.PlatformContext
import com.goim.kmp.model.ConnectionState as LiteConnectionState
import com.goim.kmp.repository.SessionEndReason
import com.goim.sdk.lite.GoImClient
import com.goim.sdk.lite.GoImConfig
import com.goim.sdk.lite.GoImIdentity
import com.goim.sdk.lite.GoImSdkPreview
import com.goim.sdk.lite.GoImSession as LiteSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Realtime IM half used by auth / chat / signals; production impl is [GoImLiteLink]. */
interface GoImRealtimeLink {
    val state: StateFlow<ConnectionState>
    val events: SharedFlow<SessionEvent>
    var onSessionEnded: ((PaircastImSession) -> Unit)?
    var refreshSession: (suspend (PaircastImSession) -> PaircastImSession?)?
    val selfUid: String
    val liteSession: StateFlow<LiteSession?>
    fun requireLite(): LiteSession
    fun liteOrNull(): LiteSession?
    suspend fun connect(session: PaircastImSession)
    suspend fun disconnect()
    fun onForeground()
}

/**
 * Wraps [GoImClient] for Paircast's dual-token auth: Paircast owns [PaircastImSession] persistence;
 * this link opens/closes the Lite IM half with `persistCredentials = false`.
 */
@OptIn(GoImSdkPreview::class)
class GoImLiteLink(
    private val context: PlatformContext,
    private val scope: CoroutineScope,
    private val deviceId: String,
    private val platform: String,
    private val api: GoImApi,
) : GoImRealtimeLink {
    private val lock = Mutex()
    private var client: GoImClient? = null
    private var paircastSession: PaircastImSession? = null
    private var endedJob: Job? = null
    private var stateJob: Job? = null

    private val _lite = MutableStateFlow<LiteSession?>(null)
    override val liteSession: StateFlow<LiteSession?> = _lite.asStateFlow()

    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    override val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _events = MutableSharedFlow<SessionEvent>(extraBufferCapacity = 4)
    override val events: SharedFlow<SessionEvent> = _events.asSharedFlow()

    override var onSessionEnded: ((PaircastImSession) -> Unit)? = null
    override var refreshSession: (suspend (PaircastImSession) -> PaircastImSession?)? = null

    override val selfUid: String get() = paircastSession?.uid.orEmpty()

    /** Active Lite session, or null when disconnected. */
    override fun requireLite(): LiteSession = _lite.value ?: throw AppError.Network

    override fun liteOrNull(): LiteSession? = _lite.value

    override suspend fun connect(session: PaircastImSession) = lock.withLock {
        paircastSession = session
        val goim = clientOf(session.imBase)
        goim.setServerUrl(session.imBase)
        endedJob?.cancel()
        stateJob?.cancel()
        _state.value = ConnectionState.CONNECTING
        val opened = goim.openSession(
            GoImIdentity(uid = session.uid, token = session.token),
            persistCredentials = false,
        )
        _lite.value = opened
        stateJob = scope.launch {
            opened.connection.state.collect { _state.value = it.toPaircast() }
        }
        endedJob = scope.launch {
            goim.sessionEnded.collect { reason ->
                handleEnded(reason)
            }
        }
    }

    override suspend fun disconnect() = lock.withLock {
        endedJob?.cancel()
        stateJob?.cancel()
        endedJob = null
        stateJob = null
        runCatching { client?.closeSession(clearCredentials = false) }
        _lite.value = null
        paircastSession = null
        _state.value = ConnectionState.DISCONNECTED
    }

    /** Foreground probe: ensure the Lite link is up; refresh IM token when auth expired. */
    override fun onForeground() {
        val session = paircastSession ?: return
        scope.launch {
            val current = _lite.value
            if (current != null) {
                runCatching { current.onForeground() }
                return@launch
            }
            runCatching { connect(session) }
        }
    }

    private suspend fun handleEnded(reason: SessionEndReason) {
        val stale = paircastSession ?: return
        when (reason) {
            SessionEndReason.KICKED,
            SessionEndReason.ACCOUNT_DISABLED,
            SessionEndReason.ACCOUNT_DELETED,
            SessionEndReason.LOGOUT,
            -> {
                lock.withLock {
                    _lite.value = null
                    paircastSession = null
                    _state.value = ConnectionState.DISCONNECTED
                }
                onSessionEnded?.invoke(stale)
                _events.emit(SessionEvent.KickedOffline)
            }
            SessionEndReason.AUTH_EXPIRED -> {
                val refreshed = refreshSession?.invoke(stale)
                if (refreshed == null) {
                    lock.withLock {
                        _lite.value = null
                        paircastSession = null
                        _state.value = ConnectionState.DISCONNECTED
                    }
                    onSessionEnded?.invoke(stale)
                    _events.emit(SessionEvent.TokenExpired)
                } else if (refreshed.token != stale.token || refreshed.imBase != stale.imBase) {
                    runCatching { connect(refreshed) }
                } else if (api.validateToken(refreshed) == false) {
                    lock.withLock {
                        _lite.value = null
                        paircastSession = null
                        _state.value = ConnectionState.DISCONNECTED
                    }
                    onSessionEnded?.invoke(stale)
                    _events.emit(SessionEvent.TokenExpired)
                } else {
                    runCatching { connect(refreshed) }
                }
            }
        }
    }

    private fun clientOf(imBase: String): GoImClient {
        client?.let { return it }
        return GoImClient.create(
            GoImConfig(serverUrl = imBase, deviceId = deviceId, platform = platform),
            context,
        ).also { client = it }
    }

    private fun LiteConnectionState.toPaircast(): ConnectionState = when (this) {
        LiteConnectionState.DISCONNECTED -> ConnectionState.DISCONNECTED
        LiteConnectionState.CONNECTING -> ConnectionState.CONNECTING
        LiteConnectionState.CONNECTED -> ConnectionState.CONNECTED
        LiteConnectionState.RECONNECTING -> ConnectionState.RECONNECTING
        LiteConnectionState.AUTH_EXPIRED -> ConnectionState.DISCONNECTED
    }
}
