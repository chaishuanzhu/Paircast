import SwiftUI
import UIKit

/// SwiftUI wrapper around the VLC render surface owned by `VLCPlayerController`.
public struct VLCPlayerView: UIViewRepresentable {
    public let videoView: UIView

    public init(videoView: UIView) {
        self.videoView = videoView
    }

    public func makeUIView(context: Context) -> UIView {
        let container = LayoutContainer()
        container.backgroundColor = .black
        attach(videoView, to: container)
        return container
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        attach(videoView, to: uiView)
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
        videoView.setNeedsLayout()
        videoView.layoutIfNeeded()
    }

    private func attach(_ videoView: UIView, to container: UIView) {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.backgroundColor = .black
        if videoView.superview !== container {
            videoView.removeFromSuperview()
            container.addSubview(videoView)
            NSLayoutConstraint.activate([
                videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                videoView.topAnchor.constraint(equalTo: container.topAnchor),
                videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }
}

/// Ensures VLC's drawable gets a non-zero bounds before the first frame (avoids corrupt first paint).
private final class LayoutContainer: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews {
            sub.frame = bounds
        }
    }
}
