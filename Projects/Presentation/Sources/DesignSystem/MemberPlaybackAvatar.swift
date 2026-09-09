import SwiftUI
import Domain

/// Member avatar with an outer circular playback progress ring.
/// Track uses opacity 0.3; progress maps `position / duration` for that member.
///
/// Progress ticks via an internal `TimelineView` so the avatar `AsyncImage` is not
/// rebuilt every tick (rebuilding forced repeated avatar downloads).
public struct MemberPlaybackAvatar: View {
    public var userId: String
    public var displayName: String
    public var avatarURL: URL?
    public var isHost: Bool
    public var progress: () -> Double
    public var size: CGFloat = 40
    public var ringWidth: CGFloat = 2.5
    /// Clear gap between avatar edge and the center of the ring stroke.
    public var ringGap: CGFloat = 3

    public init(
        userId: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        isHost: Bool = false,
        progress: @escaping () -> Double,
        size: CGFloat = 40,
        ringWidth: CGFloat = 2.5,
        ringGap: CGFloat = 3
    ) {
        self.userId = userId
        self.displayName = displayName ?? userId
        self.avatarURL = avatarURL
        self.isHost = isHost
        self.progress = progress
        self.size = size
        self.ringWidth = ringWidth
        self.ringGap = ringGap
    }

    /// Diameter of the stroke path (stroke is centered on this circle).
    private var ringPathSize: CGFloat { size + ringGap * 2 }
    /// Layout size must include the half-stroke that extends outside the path (+ round line caps).
    private var layoutSize: CGFloat { ringPathSize + ringWidth + 1 }

    private var progressColor: Color {
        isHost
            ? Color(red: 1, green: 107 / 255, blue: 129 / 255)
            : TandemColors.systemBlue
    }

    public var body: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let value = min(1, max(0, progress()))
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.3), lineWidth: ringWidth)
                        .frame(width: ringPathSize, height: ringPathSize)

                    Circle()
                        .trim(from: 0, to: value)
                        .stroke(
                            progressColor,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                        )
                        .frame(width: ringPathSize, height: ringPathSize)
                        .rotationEffect(.degrees(-90))
                }
                .accessibilityHidden(true)
            }

            TandemAvatarView(
                userId: displayName.isEmpty ? userId : displayName,
                size: size,
                isHost: false,
                avatarURL: avatarURL
            )
        }
        .frame(width: layoutSize, height: layoutSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let pct = Int((min(1, max(0, progress())) * 100).rounded())
        if isHost {
            return "\(displayName)，房主，播放进度 \(pct)%"
        }
        return "\(displayName)，播放进度 \(pct)%"
    }
}
