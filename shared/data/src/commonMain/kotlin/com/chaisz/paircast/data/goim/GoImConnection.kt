package com.chaisz.paircast.data.goim

import com.chaisz.paircast.core.gateway.ConnectionState
import com.chaisz.paircast.core.gateway.SessionEvent
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.data.secure.GoImSession
import im.Message
import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.http.URLBuilder
import io.ktor.http.URLProtocol
import io.ktor.http.Url
import io.ktor.http.path
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readBytes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.random.Random
import kotlin.time.Clock

/** GO-IM command numbers (`api/proto/message.go`). */
object Cmd {
    const val CHAT = 1
    const val ACK = 2
    const val OFFLINE = 5
    const val HEARTBEAT = 6
    const val KICK = 7
    const val GROUP_SIGNAL = 25
}

object ChatType {
    const val SINGLE = 1
    const val GROUP = 2
}

object MsgType {
    const val TEXT = 1
    const val STICKER = 6
}

/** Exponential backoff `1s → 2s → 4s … 30s` with ±20% jitter (same as GO-IM clients). */
object ReconnectPolicy {
    const val INITIAL_DELAY_MS = 1_000L
    const val MAX_DELAY_MS = 30_000L
    const val JITTER_FRACTION = 0.2

    fun delayMillis(attempt: Int, jitter: Double? = null): Long {
        val shift = min(max(0, attempt), 31)
        val base = min(INITIAL_DELAY_MS shl shift, MAX_DELAY_MS).let { if (it <= 0) MAX_DELAY_MS else it }
        val j = (jitter ?: Random.nextDouble(-JITTER_FRACTION, JITTER_FRACTION)).coerceIn(-JITTER_FRACTION, JITTER_FRACTION)
        return max(0L, (base * (1.0 + j)).roundToLong())
    }
}

/**
 * Single GO-IM WebSocket link: `ws(s)://host/ws?token=&device_id=&platform=`, one protobuf per
 * binary frame. Handles heartbeat (25s, 3 misses → reconnect), backoff reconnect, ack matching
 * by client `seq`, kick and token expiry.
 */
class GoImConnection(
    private val client: HttpClient,
    private val api: GoImApi,
    private val scope: CoroutineScope,
    private val deviceId: String,
    private val platform: String,
    private val heartbeatIntervalMs: Long = 25_000,
    private val probeTimeoutMs: Long = 5_000,
) {
    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _inbound = MutableSharedFlow<Message>(extraBufferCapacity = 256)
    /** CHAT / GROUP_SIGNAL frames (ACK / HEARTBEAT / KICK are consumed here). */
    val inbound: SharedFlow<Message> = _inbound.asSharedFlow()

    private val _events = MutableSharedFlow<SessionEvent>(extraBufferCapacity = 4)
    val events: SharedFlow<SessionEvent> = _events.asSharedFlow()

    /** Runs before a kick / expiry is emitted so the stored session is gone before any UI reacts. */
    internal var onSessionEnded: (suspend (GoImSession) -> Unit)? = null

    /** All mutable link state is confined to this serial dispatcher. */
    @OptIn(ExperimentalCoroutinesApi::class)
    private val serial = Dispatchers.Default.limitedParallelism(1)
    private val sendLock = Mutex()
    private val pendingAcks = mutableMapOf<Long, CompletableDeferred<Long>>()
    private var socket: DefaultClientWebSocketSession? = null
    private var loopJob: Job? = null
    private var seq = 0L
    private var pongReceived = true

    var session: GoImSession? = null
        private set

    val selfUid: String? get() = session?.uid

    fun connect(session: GoImSession) {
        scope.launch(serial) {
            this@GoImConnection.session = session
            loopJob?.cancel()
            loopJob = scope.launch(serial) { runLoop(session) }
        }
    }

    fun disconnect() {
        scope.launch(serial) {
            session = null
            loopJob?.cancel()
            loopJob = null
            val s = socket
            socket = null
            if (s != null) closeQuietly(s)
            failPendingAcks()
            _state.value = ConnectionState.DISCONNECTED
        }
    }

    /**
     * Call when the app returns to the foreground. Sockets die silently while the app is
     * suspended, and the regular heartbeat needs ~75s to notice; probe now and reconnect within
     * [probeTimeoutMs] instead. A pending backoff wait is skipped.
     */
    fun probe() {
        scope.launch(serial) {
            val current = session ?: return@launch
            when (_state.value) {
                ConnectionState.CONNECTED -> {
                    val ws = socket ?: return@launch
                    pongReceived = false
                    if (runCatching { sendFrame(Message(cmd = Cmd.HEARTBEAT, seq = nextSeq())) }.isFailure) {
                        ws.cancel()
                        return@launch
                    }
                    scope.launch(serial) {
                        delay(probeTimeoutMs)
                        if (socket === ws && !pongReceived) ws.cancel()
                    }
                }
                ConnectionState.RECONNECTING -> {
                    loopJob?.cancel()
                    loopJob = scope.launch(serial) { runLoop(current) }
                }
                else -> Unit
            }
        }
    }

    /**
     * Client seq. The gateway dedups chat by `uid/device_id + seq` for minutes, so a counter that
     * restarts at 1 after relaunch would get fresh messages acked but silently dropped.
     */
    fun nextSeq(): Long {
        seq = max(Clock.System.now().toEpochMilliseconds(), seq + 1)
        return seq
    }

    /** Sends a frame; throws [AppError.Network] when the link is down. */
    suspend fun send(message: Message): Unit = withContext(serial) { sendFrame(message) }

    private suspend fun sendFrame(message: Message) {
        val s = socket ?: throw AppError.Network
        sendLock.withLock {
            try {
                s.send(Frame.Binary(true, Message.ADAPTER.encode(message)))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                throw AppError.Network
            }
        }
    }

    /** Sends with `need_ack` and waits for the server `CmdAck`; returns the server `msg_id`. */
    suspend fun sendAwaitingAck(message: Message, timeoutMs: Long = 10_000): Long = withContext(serial) {
        val clientSeq = if (message.seq != 0L) message.seq else nextSeq()
        val deferred = CompletableDeferred<Long>()
        pendingAcks[clientSeq] = deferred
        try {
            sendFrame(message.copy(seq = clientSeq, need_ack = true))
            withTimeout(timeoutMs) { deferred.await() }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AppError.Network
        } finally {
            pendingAcks.remove(clientSeq)
        }
    }

    private suspend fun runLoop(session: GoImSession) {
        var attempt = 0
        while (scope.isActive && this.session == session) {
            _state.value = if (attempt == 0) ConnectionState.CONNECTING else ConnectionState.RECONNECTING
            var kicked = false
            try {
                val ws = client.webSocketSession(wsUrl(session))
                socket = ws
                pongReceived = true
                _state.value = ConnectionState.CONNECTED
                attempt = 0
                // Drain offline group chat so short disconnects don't lose room messages.
                runCatching { sendFrame(Message(cmd = Cmd.OFFLINE, seq = nextSeq())) }
                kicked = readUntilClosed(ws)
            } catch (e: CancellationException) {
                // Cancelling a dead socket (missed heartbeats / probe) surfaces here too; only our
                // own cancellation may end the loop.
                currentCoroutineContext().ensureActive()
            } catch (_: Exception) {
                // Handshake / link failure — decide below whether it was auth.
            } finally {
                socket = null
                failPendingAcks()
            }
            if (this.session != session) return
            if (kicked) {
                this.session = null
                _state.value = ConnectionState.DISCONNECTED
                onSessionEnded?.invoke(session)
                _events.emit(SessionEvent.KickedOffline)
                return
            }
            if (api.validateToken(session) == false) {
                this.session = null
                _state.value = ConnectionState.DISCONNECTED
                onSessionEnded?.invoke(session)
                _events.emit(SessionEvent.TokenExpired)
                return
            }
            _state.value = ConnectionState.RECONNECTING
            delay(ReconnectPolicy.delayMillis(attempt++))
        }
    }

    /** Returns true when the server kicked this device. */
    private suspend fun readUntilClosed(ws: DefaultClientWebSocketSession): Boolean = coroutineScope {
        var kicked = false
        val heartbeat = launch {
            var missed = 0
            while (isActive) {
                delay(heartbeatIntervalMs)
                if (pongReceived) {
                    missed = 0
                } else if (++missed >= MAX_MISSED_HEARTBEATS) {
                    ws.cancel()
                    break
                }
                pongReceived = false
                runCatching { sendFrame(Message(cmd = Cmd.HEARTBEAT, seq = nextSeq())) }
            }
        }
        try {
            for (frame in ws.incoming) {
                if (frame !is Frame.Binary) continue
                val message = runCatching { Message.ADAPTER.decode(frame.readBytes()) }.getOrNull() ?: continue
                when (message.cmd) {
                    Cmd.ACK -> pendingAcks.remove(message.seq)?.complete(message.msg_id)
                    Cmd.HEARTBEAT -> pongReceived = true
                    Cmd.KICK -> {
                        kicked = true
                        closeQuietly(ws)
                        break
                    }
                    else -> _inbound.emit(message)
                }
            }
        } finally {
            heartbeat.cancel()
        }
        kicked
    }

    private fun failPendingAcks() {
        pendingAcks.values.forEach { it.completeExceptionally(AppError.Network) }
        pendingAcks.clear()
    }

    private suspend fun closeQuietly(ws: DefaultClientWebSocketSession) {
        runCatching { withTimeoutOrNull(1_000) { ws.close() } }
        ws.cancel()
    }

    private fun wsUrl(session: GoImSession): String {
        val base = Url(session.serverUrl)
        return URLBuilder().apply {
            protocol = if (base.protocol == URLProtocol.HTTPS) URLProtocol.WSS else URLProtocol.WS
            host = base.host
            port = base.port
            path("ws")
            parameters.append("token", session.token)
            parameters.append("device_id", deviceId)
            parameters.append("platform", platform)
        }.buildString()
    }

    private companion object {
        const val MAX_MISSED_HEARTBEATS = 3
    }
}
