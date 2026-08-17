import Foundation
import AVFoundation
import Domain

/// Legacy AVFoundation adapter kept for reference / unit tests.
/// Watch scene uses VLCKit (`VLCPlayerController`) which supports mkv/m4v/mp4.
@MainActor
public final class AVPlayerGateway: NSObject, PlayerGateway {
    private var player: AVPlayer?
    private var subtitleOffsetMs: Int = 0

    public override init() {
        super.init()
    }

    public func prepare(url: URL) async throws {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
    }

    public func play() async {
        player?.play()
    }

    public func pause() async {
        player?.pause()
    }

    public func seek(toMs positionMs: Int64) async {
        let time = CMTime(value: positionMs, timescale: 1000)
        await player?.seek(to: time)
    }

    public func currentPositionMs() async -> Int64 {
        guard let time = player?.currentTime(), time.isNumeric else { return 0 }
        return Int64(CMTimeGetSeconds(time) * 1000)
    }

    public func isPaused() async -> Bool {
        player?.rate == 0
    }

    public func setSubtitleURL(_ url: URL?, offsetMs: Int) async {
        subtitleOffsetMs = offsetMs
        _ = url
    }

    public var avPlayer: AVPlayer? { player }
}
