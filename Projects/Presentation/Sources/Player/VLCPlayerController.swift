import AVFoundation
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
    /// 0...1 while VLC is opening / buffering the stream.
    @Published public private(set) var loadProgress: Double = 0

    public override init() {
        _ = VLCLibrary.shared()
        Self.configureAudioSession()

        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        self.videoView = view
        // Prefer software decode for stability on high-bitrate MKV over HTTP —
        // VideoToolbox 花屏 is common with certain H.264/HEVC annex streams.
        self.mediaPlayer = VLCMediaPlayer(options: [
            "--avcodec-hw=none",
            "--clock-synchro=0",
            "--clock-jitter=0",
        ])
        super.init()
        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoView
        mediaPlayer.rate = 1.0
    }

    public func prepare(url: URL) async throws {
        lastError = nil
        isReady = false
        loadProgress = 0.05
        mediaPlayer.stop()
        mediaPlayer.rate = 1.0

        TandemLog.playback.info("prepare stream \(TandemLog.redactedURL(url), privacy: .public)")

        // Rebuild from absoluteString so Foundation keeps the exact SigV4 query encoding.
        let streamURL = URL(string: url.absoluteString) ?? url
        mediaPlayer.drawable = videoView
        let media = VLCMedia(url: streamURL)
        // VOD over HTTP — do NOT use :http-continuous (live clock → wrong speed / 花屏).
        media.addOption(":network-caching=8000")
        media.addOption(":file-caching=3000")
        media.addOption(":http-reconnect")
        media.addOption(":avcodec-hw=none")
        media.addOption(":clock-synchro=0")
        media.addOption(":clock-jitter=0")
        media.addOption(":no-drop-late-frames")
        media.addOption(":no-skip-frames")
        mediaPlayer.media = media
        isPaused = true
        isReady = true
        loadProgress = 1
        TandemLog.playback.info("prepare ready MobileVLCKit stream media set")
    }

    public func play() {
        guard isReady, mediaPlayer.media != nil else {
            TandemLog.playback.warning("play ignored isReady=\(self.isReady, privacy: .public) hasMedia=\(self.mediaPlayer.media != nil, privacy: .public)")
            return
        }
        Self.configureAudioSession()
        mediaPlayer.drawable = videoView
        mediaPlayer.rate = 1.0
        mediaPlayer.play()
        isPaused = false
        TandemLog.playback.info("play rate=\(self.mediaPlayer.rate, privacy: .public)")
    }

    public func pause() {
        mediaPlayer.pause()
        isPaused = true
        TandemLog.playback.info("pause positionMs=\(self.currentPositionMs, privacy: .public)")
    }

    public func stop() {
        TandemLog.playback.info("stop")
        mediaPlayer.pause()
        mediaPlayer.stop()
        mediaPlayer.rate = 1.0
        isReady = false
        isPaused = true
        loadProgress = 0
    }

    public func seek(toMs positionMs: Int64) {
        let clamped = max(0, min(positionMs, Int64(Int32.max)))
        mediaPlayer.time = VLCTime(int: Int32(clamped))
        mediaPlayer.rate = 1.0
    }

    public var currentPositionMs: Int64 {
        Int64(mediaPlayer.time.intValue)
    }

    private static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            TandemLog.playback.error(
                "audio session failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}

extension VLCPlayerController: VLCMediaPlayerDelegate {
    nonisolated public func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            // Keep 1x — sync/seek paths must not leave the player in FF/REW.
            if abs(mediaPlayer.rate - 1.0) > 0.01, mediaPlayer.state == .playing {
                mediaPlayer.rate = 1.0
            }
            switch mediaPlayer.state {
            case .error:
                TandemLog.playback.error("vlc state=error")
                lastError = AppError.playbackFailed.userMessage
                isPaused = true
            case .ended, .stopped:
                TandemLog.playback.info("vlc state=\(String(describing: self.mediaPlayer.state), privacy: .public)")
                isPaused = true
            case .paused:
                isPaused = true
            case .playing, .buffering:
                TandemLog.playback.debug(
                    "vlc state=\(String(describing: self.mediaPlayer.state), privacy: .public) rate=\(self.mediaPlayer.rate, privacy: .public)"
                )
                isPaused = !mediaPlayer.isPlaying
                if mediaPlayer.state == .buffering {
                    loadProgress = max(loadProgress, 0.3)
                } else if mediaPlayer.isPlaying {
                    loadProgress = 1
                }
            default:
                break
            }
        }
    }
}
