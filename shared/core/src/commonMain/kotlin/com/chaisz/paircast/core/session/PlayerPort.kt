package com.chaisz.paircast.core.session

import com.chaisz.paircast.core.model.SubtitleTrack
import com.chaisz.paircast.core.model.VideoFormat

/**
 * Native player bridge (VLCKit on iOS, libVLC on Android). All calls happen on the main thread.
 * Kept callback-based (no `suspend`) so Swift can implement it directly.
 */
interface PlayerPort {
    val isPaused: Boolean
    val hasStartedPlayback: Boolean
    val currentPositionMs: Long
    val durationMs: Long
    val lastError: String?

    /** Loads [url]; [completion] receives an error message, or null on success. */
    fun prepare(url: String, format: VideoFormat, completion: (String?) -> Unit)
    fun play()
    fun pause()
    fun seek(positionMs: Long)
    fun stop()

    /** App left the foreground (already paused): release the render surface. */
    fun enterBackground()
    /** App is back: rebind the render surface. */
    fun enterForeground()

    fun embeddedSubtitleTracks(): List<SubtitleTrack>
    fun selectEmbeddedSubtitle(index: Int)
    /** Adds a local subtitle file as the active track. */
    fun loadExternalSubtitle(filePath: String): Boolean
    fun disableSubtitles()
    fun applySubtitleOffsetMs(offsetMs: Int)
}
