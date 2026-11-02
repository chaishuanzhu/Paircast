package com.chaisz.paircast.android.player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.chaisz.paircast.android.app.L10n
import com.chaisz.paircast.core.model.AppError
import com.chaisz.paircast.core.model.SubtitleSource
import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.VideoFormat
import com.chaisz.paircast.core.session.PlayerPort
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.VLCVideoLayout
import java.io.File

/** libVLC player for the watch screen — streams the presigned URL directly, mirrors the iOS VLCKit controller. */
class VlcPlayer(context: Context) : PlayerPort {
    private val libVlc = LibVLC(
        context.applicationContext,
        arrayListOf(
            "--clock-synchro=0",
            "--clock-jitter=0",
            "--subsdec-encoding=UTF-8",
            "--freetype-rel-fontsize=16",
            "--audio-time-stretch",
        ),
    )
    private val player = MediaPlayer(libVlc)
    private val main = Handler(Looper.getMainLooper())

    private val _paused = MutableStateFlow(true)
    private val _position = MutableStateFlow(0L)
    private val _duration = MutableStateFlow(0L)
    private val _ready = MutableStateFlow(false)
    private val _buffering = MutableStateFlow(false)
    val paused: StateFlow<Boolean> = _paused.asStateFlow()
    val position: StateFlow<Long> = _position.asStateFlow()
    val duration: StateFlow<Long> = _duration.asStateFlow()
    val ready: StateFlow<Boolean> = _ready.asStateFlow()
    val buffering: StateFlow<Boolean> = _buffering.asStateFlow()

    private var playRequested = false
    private var isPrebuffering = false
    private var prebufferGeneration = 0
    private var pausedSeekTargetMs: Long? = null
    private var attachedLayout: VLCVideoLayout? = null
    private var released = false

    override val isPaused: Boolean get() = _paused.value
    override var hasStartedPlayback: Boolean = false
        private set
    override val currentPositionMs: Long get() = if (released) 0 else player.time.coerceAtLeast(0)
    override val durationMs: Long get() = _duration.value
    override var lastError: String? = null
        private set

    init {
        player.setEventListener { event -> handle(event) }
    }

    fun attach(layout: VLCVideoLayout) {
        if (released || attachedLayout === layout) return
        if (attachedLayout != null) player.detachViews()
        player.attachViews(layout, null, true, false)
        attachedLayout = layout
    }

    fun detach(layout: VLCVideoLayout) {
        if (released || attachedLayout !== layout) return
        player.detachViews()
        attachedLayout = null
    }

    override fun prepare(url: String, format: VideoFormat, completion: (String?) -> Unit) {
        if (released) return completion(L10n.format(AppError.PlaybackFailed))
        lastError = null
        hasStartedPlayback = false
        playRequested = false
        isPrebuffering = false
        prebufferGeneration += 1
        pausedSeekTargetMs = null
        player.stop()
        Log.i(TAG, "prepare stream format=${format.rawValue}")

        val media = Media(libVlc, Uri.parse(url)).apply {
            addOption(":network-caching=2000")
            addOption(":file-caching=1000")
            addOption(":http-reconnect")
            if (format == VideoFormat.MKV) setHWDecoderEnabled(false, false)
            addOption(":clock-synchro=0")
            addOption(":clock-jitter=0")
            addOption(":no-drop-late-frames")
            addOption(":no-skip-frames")
        }
        player.media = media
        media.release()
        _paused.value = true
        _ready.value = true
        _position.value = 0
        _duration.value = 0
        prebuffer()
        completion(lastError)
    }

    /** Fills VLC's input/decoder buffers muted, then parks on the first frame (room stays paused). */
    private fun prebuffer() {
        if (!_ready.value || isPrebuffering || playRequested) return
        isPrebuffering = true
        prebufferGeneration += 1
        player.volume = 0
        player.play()
    }

    override fun play() {
        if (released || !_ready.value) return
        isPrebuffering = false
        playRequested = true
        pausedSeekTargetMs?.let { pinned ->
            player.time = pinned
            _position.value = pinned
            pausedSeekTargetMs = null
        }
        player.volume = 100
        if (!player.isPlaying) player.play()
        hasStartedPlayback = true
        _paused.value = false
    }

    override fun pause() {
        if (released) return
        isPrebuffering = false
        playRequested = false
        player.volume = 100
        player.pause()
        _paused.value = true
    }

    override fun seek(positionMs: Long) {
        if (released) return
        val clamped = positionMs.coerceAtLeast(0)
        _position.value = clamped
        if (_paused.value || !playRequested) {
            pausedSeekTargetMs = clamped
            player.volume = 0
            player.time = clamped
            if (player.isPlaying) player.pause()
            _paused.value = true
            return
        }
        pausedSeekTargetMs = null
        player.time = clamped
    }

    override fun stop() {
        if (released) return
        player.stop()
        player.volume = 100
        isPrebuffering = false
        prebufferGeneration += 1
        playRequested = false
        pausedSeekTargetMs = null
        hasStartedPlayback = false
        _ready.value = false
        _paused.value = true
        _position.value = 0
        _duration.value = 0
    }

    fun release() {
        if (released) return
        stop()
        attachedLayout?.let { player.detachViews() }
        attachedLayout = null
        player.setEventListener(null)
        player.release()
        libVlc.release()
        released = true
    }

    override fun embeddedSubtitleTracks(): List<SubtitleTrack> {
        if (released) return emptyList()
        return player.spuTracks.orEmpty()
            .filter { it.id >= 0 }
            .map { desc ->
                val lower = desc.name.orEmpty().lowercase()
                val zh = "zh" in lower || "chi" in lower || "中文" in lower || "简" in lower
                SubtitleTrack(
                    id = "embedded-${desc.id}",
                    label = desc.name?.ifBlank { null } ?: "Track ${desc.id}",
                    language = if (zh) "zh" else null,
                    source = SubtitleSource.EMBEDDED,
                    embeddedIndex = desc.id,
                    languageBadge = if (zh) "ZH" else null,
                )
            }
    }

    override fun selectEmbeddedSubtitle(index: Int) {
        if (!released) player.spuTrack = index
    }

    override fun loadExternalSubtitle(filePath: String): Boolean {
        if (released) return false
        val file = File(filePath)
        if (!file.exists()) return false
        return player.addSlave(IMedia.Slave.Type.Subtitle, Uri.fromFile(file), true)
    }

    override fun disableSubtitles() {
        if (!released) player.spuTrack = -1
    }

    override fun applySubtitleOffsetMs(offsetMs: Int) {
        if (!released) player.spuDelay = offsetMs * 1_000L
    }

    private fun handle(event: MediaPlayer.Event) {
        when (event.type) {
            MediaPlayer.Event.TimeChanged -> refreshTiming()
            MediaPlayer.Event.LengthChanged -> _duration.value = player.length.coerceAtLeast(0)
            MediaPlayer.Event.Buffering -> _buffering.value = event.buffering < 100f
            MediaPlayer.Event.EncounteredError -> {
                Log.e(TAG, "vlc error")
                lastError = L10n.format(AppError.PlaybackFailed)
                isPrebuffering = false
                playRequested = false
                player.volume = 100
                _paused.value = true
            }
            MediaPlayer.Event.EndReached, MediaPlayer.Event.Stopped -> {
                isPrebuffering = false
                playRequested = false
                _paused.value = true
            }
            MediaPlayer.Event.Paused -> _paused.value = !playRequested
            MediaPlayer.Event.Playing -> onPlaying()
        }
    }

    private fun onPlaying() {
        refreshTiming()
        if (isPrebuffering) {
            isPrebuffering = false
            val generation = prebufferGeneration
            player.pause()
            playRequested = false
            _paused.value = true
            main.postDelayed({
                if (released || generation != prebufferGeneration || playRequested) return@postDelayed
                if (player.isPlaying) player.pause()
            }, 120)
            return
        }
        if (playRequested) {
            _paused.value = false
        } else {
            player.pause()
            player.volume = 0
            _paused.value = true
        }
    }

    private fun refreshTiming() {
        val live = player.time
        val pinned = pausedSeekTargetMs
        if (pinned != null && (_paused.value || !playRequested)) {
            _position.value = pinned
            if (kotlin.math.abs(live - pinned) <= 800) {
                pausedSeekTargetMs = null
                _position.value = live
            }
        } else {
            _position.value = live.coerceAtLeast(0)
        }
        val length = player.length
        if (length > 0) _duration.value = length
    }

    private companion object {
        const val TAG = "Paircast.playback"
    }
}
