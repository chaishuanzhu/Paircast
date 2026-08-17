import SwiftUI
import UIKit

/// SwiftUI wrapper around the VLC render surface owned by `VLCPlayerController`.
public struct VLCPlayerView: UIViewRepresentable {
    public let videoView: UIView
    /// Called when the drawable had to move to a new container — VLC needs its vout rebound.
    public var onReattach: () -> Void

    public init(videoView: UIView, onReattach: @escaping () -> Void = {}) {
        self.videoView = videoView
        self.onReattach = onReattach
    }

    public func makeUIView(context: Context) -> UIView {
        let container = LayoutContainer()
        container.backgroundColor = .black
        attach(videoView, to: container)
        return container
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        if attach(videoView, to: uiView) {
            onReattach()
        }
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    /// Returns true when the drawable was moved into a different container.
    @discardableResult
    private func attach(_ videoView: UIView, to container: UIView) -> Bool {
        guard videoView.superview !== container else { return false }
        let hadSuperview = videoView.superview != nil
        videoView.removeFromSuperview()
        // Autoresizing (not constraints): VLC resizes its vout from the drawable's
        // frame, and constraint-driven layout can leave it at zero size for a beat.
        videoView.translatesAutoresizingMaskIntoConstraints = true
        videoView.frame = container.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.backgroundColor = .black
        container.addSubview(videoView)
        return hadSuperview
    }
}

/// Ensures VLC's drawable gets a non-zero bounds before the first frame (avoids corrupt first paint).
private final class LayoutContainer: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews where sub.frame != bounds {
            sub.frame = bounds
        }
    }
}
