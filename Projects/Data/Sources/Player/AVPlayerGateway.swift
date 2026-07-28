import Foundation
import AVFoundation
import Domain

/// AVFoundation-backed player. MKV may fail → maps to `.unsupportedContainer`.
/// VLCKit can replace this adapter behind the same `PlayerGateway` once linked.
@MainActor
public final class AVPlayerGateway: NSObject, PlayerGateway {
    private var player: AVPlayer?
    private var subtitleOffsetMs: Int = 0

    public override init() {
        super.init()
    }

    public func prepare(url: URL) async throws {
        if url.pathExtension.lowercased() == "mkv" {
            throw AppError.unsupportedContainer
        }
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Brief wait for item readiness; failures surface on play.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                cont.resume()
            }
        }
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
        // External subtitle rendering is handled in Presentation overlay using offsetMs.
        _ = url
    }

    public var avPlayer: AVPlayer? { player }
}
