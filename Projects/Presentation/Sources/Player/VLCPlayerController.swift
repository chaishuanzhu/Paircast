import AVFoundation
import CoreText
import Foundation
import UIKit
import VLCKitSPM // re-exports MobileVLCKit
import Domain

/// MobileVLCKit player for the watch scene — streams a remote URL directly (no local download/proxy).
@MainActor
public final class VLCPlayerController: NSObject, ObservableObject {
    public let videoView: UIView
    public let mediaPlayer: VLCMediaPlayer

    @Published public private(set) var isPaused: Bool = true
    @Published public private(set) var lastError: String?
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var hasStartedPlayback: Bool = false
    /// 0...1 while VLC is opening / buffering the stream.
    @Published public private(set) var loadProgress: Double = 0
    @Published public private(set) var positionMs: Int64 = 0
    @Published public private(set) var durationMs: Int64 = 0

    private let subtitleFontName: String
    private let subtitleFontPath: String?
    /// User intent, kept separate from VLC's transient opening/buffering states.
    private var playRequested = false
    /// VLC must briefly run to fill its input/decoder buffers before the user presses play.
    private var isPrebuffering = false
    /// Generation token so delayed prebuffer re-pause ignores stale tasks after stop/prepare.
    private var prebufferGeneration = 0
    /// Keep the scrubber on the host's target until VLC reports a matching clock (or play resumes).
    private var pausedSeekTargetMs: Int64?

    public override init() {
        _ = VLCLibrary.shared()
        VLCOpenGLESMainThreadGuard.installIfNeeded()
        Self.configureAudioSession()

        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        self.videoView = view

        let font = Self.resolveCJKSubtitleFont()
        self.subtitleFontName = font.name
        self.subtitleFontPath = font.path

        var options = [
            "--clock-synchro=0",
            "--clock-jitter=0",
            // External files are normalized to UTF-8 before addPlaybackSlave.
            "--subsdec-encoding=UTF-8",
            // FreeType relative size: smaller divisor => larger glyphs (16 ≈ VLC "Larger").
            "--freetype-rel-fontsize=16",
        ]
        // FreeType needs an explicit CJK-capable font on iOS 18+ (otherwise □□□).
        if let path = font.path {
            options.append("--freetype-font=\(path)")
            PaircastLog.playback.info("subtitle freetype-font=\(path, privacy: .public)")
        } else {
            PaircastLog.playback.warning(
                "subtitle font path unresolved name=\(font.name, privacy: .public); relying on setTextRendererFont"
            )
        }

        self.mediaPlayer = VLCMediaPlayer(options: options)
        super.init()
        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoView
        mediaPlayer.rate = 1.0
        applySubtitleTextRendererFont()
    }

    public func prepare(url: URL, format: VideoFormat) async throws {
        lastError = nil
        isReady = false
        hasStartedPlayback = false
        playRequested = false
        isPrebuffering = false
        prebufferGeneration += 1
        pausedSeekTargetMs = nil
        loadProgress = 0.05
        mediaPlayer.stop()
        mediaPlayer.rate = 1.0

        PaircastLog.playback.info("prepare stream \(PaircastLog.redactedURL(url), privacy: .public)")

        // Rebuild from absoluteString so Foundation keeps the exact SigV4 query encoding.
        let streamURL = URL(string: url.absoluteString) ?? url
        mediaPlayer.drawable = videoView
        let media = VLCMedia(url: streamURL)
        // VOD over HTTP — do NOT use :http-continuous (live clock → wrong speed / 花屏).
        // Two seconds is enough for object-storage VOD without imposing an 8s startup delay.
        media.addOption(":network-caching=2000")
        media.addOption(":file-caching=1000")
        media.addOption(":http-reconnect")
        // VideoToolbox starts MP4/M4V faster. Keep software decode for MKV,
        // where some H.264/HEVC annex streams produce corrupt hardware frames.
        if format == .mkv {
            media.addOption(":avcodec-hw=none")
        }
        media.addOption(":clock-synchro=0")
        media.addOption(":clock-jitter=0")
        media.addOption(":no-drop-late-frames")
        media.addOption(":no-skip-frames")
        mediaPlayer.media = media
        isPaused = true
        isReady = true
        loadProgress = 1
        positionMs = 0
        durationMs = Int64(media.length.intValue)
        applySubtitleTextRendererFont()
        PaircastLog.playback.info("prepare ready MobileVLCKit stream media set")
    }

    public func play() {
        guard isReady, mediaPlayer.media != nil else {
            PaircastLog.playback.warning("play ignored isReady=\(self.isReady, privacy: .public) hasMedia=\(self.mediaPlayer.media != nil, privacy: .public)")
            return
        }
        Self.configureAudioSession()
        mediaPlayer.drawable = videoView
        mediaPlayer.rate = 1.0
        applySubtitleTextRendererFont()
        isPrebuffering = false
        playRequested = true
        // Apply any scrub done while paused — VLC often ignores setTime until playing.
        if let pinned = pausedSeekTargetMs {
            mediaPlayer.time = VLCTime(int: Int32(pinned))
            if durationMs > 0 {
                mediaPlayer.position = Float(Double(pinned) / Double(durationMs))
            }
            positionMs = pinned
            pausedSeekTargetMs = nil
        }
        mediaPlayer.audio?.isMuted = false
        if !mediaPlayer.isPlaying {
            mediaPlayer.play()
        }
        hasStartedPlayback = true
        isPaused = false
        PaircastLog.playback.info("play rate=\(self.mediaPlayer.rate, privacy: .public)")
    }

    /// Rebind the render surface after the drawable moved in the view hierarchy.
    /// VLC tears down its vout when the drawable leaves the window and won't rebuild it
    /// on a plain `drawable` assignment — the symptom is video audio with a black frame.
    public func refreshDrawable() {
        mediaPlayer.drawable = videoView
        // Never pause→play unless the user actually requested playback. Doing so during
        // prebuffer / muted seek nudges restarts the stream ("auto play" on enter).
        guard mediaPlayer.media != nil, playRequested, mediaPlayer.isPlaying else { return }
        mediaPlayer.pause()
        mediaPlayer.play()
        PaircastLog.playback.info("drawable reattached positionMs=\(self.currentPositionMs, privacy: .public)")
    }

    public func pause() {
        isPrebuffering = false
        playRequested = false
        mediaPlayer.audio?.isMuted = false
        mediaPlayer.pause()
        isPaused = true
        PaircastLog.playback.info("pause positionMs=\(self.currentPositionMs, privacy: .public)")
    }

    public func stop() {
        PaircastLog.playback.info("stop")
        mediaPlayer.pause()
        mediaPlayer.stop()
        mediaPlayer.rate = 1.0
        mediaPlayer.audio?.isMuted = false
        isPrebuffering = false
        prebufferGeneration += 1
        playRequested = false
        pausedSeekTargetMs = nil
        isReady = false
        hasStartedPlayback = false
        isPaused = true
        loadProgress = 0
        positionMs = 0
        durationMs = 0
    }

    /// Opens the stream and fills VLC's input/decoder buffers without changing
    /// the room's paused state. The first decoded frame is immediately paused at 0.
    public func prebuffer() {
        guard isReady, isPaused, mediaPlayer.media != nil, !isPrebuffering, !playRequested else { return }
        isPrebuffering = true
        prebufferGeneration += 1
        let generation = prebufferGeneration
        playRequested = false
        mediaPlayer.audio?.isMuted = true
        mediaPlayer.drawable = videoView
        mediaPlayer.play()
        PaircastLog.playback.info("prebuffer started gen=\(generation, privacy: .public)")
    }

    public func seek(toMs positionMs: Int64) {
        let clamped = max(0, min(positionMs, Int64(Int32.max)))
        self.positionMs = clamped
        mediaPlayer.rate = 1.0

        // Paused scrub: only pin UI + best-effort setTime. Do NOT play→pause nudge —
        // rapid nudges leave MobileVLCKit unable to resume later.
        if isPaused || !playRequested {
            pausedSeekTargetMs = clamped
            mediaPlayer.audio?.isMuted = true
            mediaPlayer.time = VLCTime(int: Int32(clamped))
            if durationMs > 0 {
                mediaPlayer.position = Float(Double(clamped) / Double(durationMs))
            }
            // If a previous prebuffer left VLC running, stop it from advancing.
            if mediaPlayer.isPlaying {
                mediaPlayer.pause()
            }
            isPaused = true
            PaircastLog.playback.info("seek while paused toMs=\(clamped, privacy: .public)")
            return
        }

        pausedSeekTargetMs = nil
        mediaPlayer.time = VLCTime(int: Int32(clamped))
        if durationMs > 0 {
            mediaPlayer.position = Float(Double(clamped) / Double(durationMs))
        }
        PaircastLog.playback.info("seek toMs=\(clamped, privacy: .public)")
    }

    public var currentPositionMs: Int64 {
        Int64(mediaPlayer.time.intValue)
    }

    // MARK: - Subtitles (VLC)

    /// Embedded subtitle tracks discovered after media is parsed.
    public func embeddedSubtitleTracks() -> [SubtitleTrack] {
        let names = mediaPlayer.videoSubTitlesNames
        let indexes = mediaPlayer.videoSubTitlesIndexes
        var tracks: [SubtitleTrack] = []
        let count = min(names.count, indexes.count)
        for i in 0..<count {
            let rawIndex = (indexes[i] as? NSNumber)?.intValue ?? (indexes[i] as? Int) ?? -1
            if rawIndex < 0 { continue }
            let rawName = (names[i] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = rawName.isEmpty ? "Embedded track \(rawIndex)" : rawName
            let lang = Self.guessLanguage(from: label)
            tracks.append(
                SubtitleTrack(
                    id: "embedded:\(rawIndex)",
                    label: label,
                    language: lang.code,
                    source: .embedded,
                    embeddedIndex: rawIndex,
                    languageBadge: lang.badge
                )
            )
        }
        return tracks
    }

    public func disableSubtitles() {
        mediaPlayer.currentVideoSubTitleIndex = -1
        mediaPlayer.currentVideoSubTitleDelay = 0
    }

    public func selectEmbeddedSubtitle(index: Int) {
        mediaPlayer.currentVideoSubTitleIndex = Int32(index)
        applySubtitleTextRendererFont()
    }

    /// Load an external subtitle file (local file URL preferred) and select it.
    @discardableResult
    public func loadExternalSubtitle(fileURL: URL) -> Bool {
        let result = mediaPlayer.addPlaybackSlave(
            fileURL,
            type: .subtitle,
            enforce: true
        )
        applySubtitleTextRendererFont()
        return result >= 0
    }

    /// VLC delay is in microseconds. Positive = subtitles delayed (shown later).
    public func applySubtitleOffsetMs(_ offsetMs: Int) {
        let clamped = SubtitleState.clamped(offsetMs)
        mediaPlayer.currentVideoSubTitleDelay = clamped * 1000
    }

    /// Point VLC's text renderer at a CJK-capable font (fixes □□□ on iOS 18+).
    private func applySubtitleTextRendererFont() {
        let sel = NSSelectorFromString("setTextRendererFont:")
        if mediaPlayer.responds(to: sel) {
            _ = mediaPlayer.perform(sel, with: subtitleFontName)
        }
        let sizeSel = NSSelectorFromString("setTextRendererFontSize:")
        if mediaPlayer.responds(to: sizeSel) {
            // Same scale as freetype-rel-fontsize: smaller number => bigger text.
            _ = mediaPlayer.perform(sizeSel, with: NSNumber(value: 16))
        }
    }

    /// Resolve a CJK font FreeType can actually open.
    /// iOS 26 sim only ships PingFangUI in PrivateFrameworks — FreeType often fails on it (blank subs).
    private static func resolveCJKSubtitleFont() -> (name: String, path: String?) {
        if let bundled = bundledNotoSansSCPath() {
            registerFontIfNeeded(atPath: bundled)
            return ("NotoSansSC-Regular", bundled)
        }

        // Prefer classic public font files FreeType handles; never PingFangUI PrivateFrameworks.
        let safePaths: [(name: String, path: String)] = [
            ("STHeitiSC-Medium", "/System/Library/Fonts/STHeiti Medium.ttc"),
            ("STHeitiSC-Light", "/System/Library/Fonts/STHeiti Light.ttc"),
            ("HiraginoSansGB-W3", "/System/Library/Fonts/Hiragino Sans GB.ttc"),
            ("Arial Unicode MS", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
        ]
        for item in safePaths where FileManager.default.isReadableFile(atPath: item.path) {
            return item
        }

        // CoreText lookup — reject PrivateFrameworks / PingFangUI (known FreeType blank-subtitle path).
        let preferredNames = [
            "PingFangSC-Regular",
            "PingFangSC-Medium",
            "STHeitiSC-Medium",
            "HiraginoSansGB-W3",
            "Arial Unicode MS",
        ]
        for name in preferredNames {
            guard UIFont(name: name, size: 16) != nil else { continue }
            if let path = fontFilePath(named: name),
               FileManager.default.isReadableFile(atPath: path),
               isFreeTypeFriendlyFontPath(path) {
                return (name, path)
            }
            return (name, nil)
        }
        return ("NotoSansSC-Regular", nil)
    }

    private static func bundledNotoSansSCPath() -> String? {
        let bundle = Bundle.main
        if let path = bundle.path(forResource: "NotoSansSC-Regular", ofType: "otf", inDirectory: "Fonts") {
            return path
        }
        return bundle.path(forResource: "NotoSansSC-Regular", ofType: "otf")
    }

    private static func registerFontIfNeeded(atPath path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        CTFontManagerRegisterFontsForURL(url, .process, nil)
    }

    private static func isFreeTypeFriendlyFontPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        if lowered.contains("privateframeworks") { return false }
        if lowered.contains("pingfangui") { return false }
        if lowered.contains("lastresort") { return false }
        return true
    }

    private static func fontFilePath(named name: String) -> String? {
        let font = CTFontCreateWithName(name as CFString, 16, nil)
        let descriptor = CTFontCopyFontDescriptor(font)
        guard let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL else {
            return nil
        }
        return url.path
    }

    private static func guessLanguage(from name: String) -> (code: String?, badge: String) {
        let lower = name.lowercased()
        if lower.contains("zh") || lower.contains("chi") || lower.contains("中文") || lower.contains("简") {
            return ("zh", "ZH")
        }
        if lower.contains("繁") {
            return ("zh-tw", "ZH-TW")
        }
        if lower.contains("en") || lower.contains("eng") || lower.contains("english") {
            return ("en", "English")
        }
        return (nil, "")
    }

    private static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            PaircastLog.playback.error(
                "audio session failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}

extension VLCPlayerController: VLCMediaPlayerDelegate {
    nonisolated public func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep 1x — sync/seek paths must not leave the player in FF/REW.
            if abs(mediaPlayer.rate - 1.0) > 0.01, mediaPlayer.state == .playing {
                mediaPlayer.rate = 1.0
            }
            refreshTiming()
            switch mediaPlayer.state {
            case .error:
                PaircastLog.playback.error("vlc state=error")
                lastError = TandemL10n.format(AppError.playbackFailed)
                isPrebuffering = false
                mediaPlayer.audio?.isMuted = false
                playRequested = false
                isPaused = true
            case .ended, .stopped:
                PaircastLog.playback.info("vlc state=\(String(describing: self.mediaPlayer.state), privacy: .public)")
                isPrebuffering = false
                mediaPlayer.audio?.isMuted = false
                playRequested = false
                isPaused = true
            case .paused:
                // Drawable reattachment uses pause→play internally; keep the intended icon.
                isPaused = !playRequested
            case .buffering:
                // VLC resets text renderer when opening media — re-apply CJK font.
                applySubtitleTextRendererFont()
                PaircastLog.playback.debug(
                    "vlc state=\(String(describing: self.mediaPlayer.state), privacy: .public) rate=\(self.mediaPlayer.rate, privacy: .public)"
                )
                // `isPlaying` is often false while buffering. Keep the pause icon
                // because playback is still what the user requested.
                isPaused = !playRequested
                loadProgress = max(loadProgress, 0.3)
            case .playing:
                applySubtitleTextRendererFont()
                if isPrebuffering {
                    // First frame + input buffer are ready. Return to a true paused
                    // state without seeking, because seeking would flush the buffer
                    // we just filled. At most a fraction of a second has advanced.
                    isPrebuffering = false
                    let generation = prebufferGeneration
                    mediaPlayer.pause()
                    mediaPlayer.audio?.isMuted = true
                    playRequested = false
                    isPaused = true
                    loadProgress = 1
                    PaircastLog.playback.info("prebuffer ready gen=\(generation, privacy: .public)")
                    // VLC sometimes ignores the first pause; re-assert shortly.
                    // Outer Task already resolved `self` strongly for this hop.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard self.prebufferGeneration == generation else { return }
                        guard !self.playRequested, self.isPaused else { return }
                        if self.mediaPlayer.isPlaying {
                            self.mediaPlayer.pause()
                            self.mediaPlayer.audio?.isMuted = true
                            PaircastLog.playback.warning("prebuffer re-pause after sticky play")
                        }
                    }
                    return
                }
                if playRequested {
                    isPaused = false
                    loadProgress = 1
                } else {
                    // Spurious .playing after prebuffer / layout reattach.
                    PaircastLog.playback.warning("vlc playing without playRequested; forcing pause")
                    mediaPlayer.pause()
                    mediaPlayer.audio?.isMuted = true
                    isPaused = true
                }
            default:
                // opening / esadding etc.
                applySubtitleTextRendererFont()
            }
        }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            self?.refreshTiming()
        }
    }

    @MainActor
    private func refreshTiming() {
        let live = Int64(mediaPlayer.time.intValue)
        if let pinned = pausedSeekTargetMs, isPaused || !playRequested {
            // Keep scrubber on the seek target; live clock often stays stale while paused.
            positionMs = pinned
            if abs(live - pinned) <= 800 {
                pausedSeekTargetMs = nil
                positionMs = live
            }
        } else {
            positionMs = live
        }
        let length = Int64(mediaPlayer.media?.length.intValue ?? 0)
        if length > 0 {
            durationMs = length
        }
    }
}
