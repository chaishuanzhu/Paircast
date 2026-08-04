import SwiftUI

public enum TandemColors {
    public static let systemBlue = Color(red: 0, green: 122 / 255, blue: 1)
    public static let groupedBackground = Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255)
    public static let secondaryGrouped = Color.white
    public static let watchBackground = Color.black
    public static let watchPanel = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
    public static let danger = Color(red: 1, green: 59 / 255, blue: 48 / 255)
    public static let secondaryLabel = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.6)
    public static let tertiaryLabel = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.3)
    public static let avatarAccent = Color(red: 91 / 255, green: 141 / 255, blue: 239 / 255)
}

public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(TandemColors.systemBlue)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TandemColors.systemBlue)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

public struct TandemWarningBanner: View {
    public var text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color(red: 179 / 255, green: 90 / 255, blue: 0))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

public struct TandemTextField: View {
    let title: String
    @Binding var text: String
    var isSecure: Bool = false
    @State private var reveal = false

    public init(_ title: String, text: Binding<String>, isSecure: Bool = false) {
        self.title = title
        self._text = text
        self.isSecure = isSecure
    }

    public var body: some View {
        HStack {
            Group {
                if isSecure && !reveal {
                    SecureField(title, text: $text)
                } else {
                    TextField(title, text: $text)
                }
            }
            .font(.system(size: 17))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if isSecure {
                Button(reveal ? "隐藏" : "显示") { reveal.toggle() }
                    .font(.footnote)
                    .foregroundStyle(TandemColors.systemBlue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(TandemColors.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Circular initial avatar matching design preview (blue pill / circle with letter).
public struct TandemAvatarView: View {
    public var initial: String
    public var size: CGFloat = 36
    public var color: Color = TandemColors.systemBlue
    public var isHost: Bool = false

    public init(initial: String, size: CGFloat = 36, color: Color = TandemColors.systemBlue, isHost: Bool = false) {
        self.initial = initial
        self.size = size
        self.color = color
        self.isHost = isHost
    }

    public init(userId: String, size: CGFloat = 36, color: Color? = nil, isHost: Bool = false) {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initial = trimmed.first.map { String($0).uppercased() } ?? "?"
        self.size = size
        self.color = color ?? TandemColors.avatarColor(for: trimmed)
        self.isHost = isHost
    }

    public var body: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color)
            .clipShape(Circle())
            .overlay {
                if isHost {
                    Circle()
                        .stroke(Color(red: 1, green: 107 / 255, blue: 129 / 255), lineWidth: 2)
                }
            }
    }
}

extension TandemColors {
    public static func avatarColor(for userId: String) -> Color {
        let palette: [Color] = [
            systemBlue,
            avatarAccent,
            Color(red: 88 / 255, green: 86 / 255, blue: 214 / 255),
            Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255),
            Color(red: 255 / 255, green: 149 / 255, blue: 0),
            Color(red: 175 / 255, green: 82 / 255, blue: 222 / 255),
        ]
        let hash = userId.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % palette.count }
        return palette[hash]
    }

    public static func formatPlaybackTime(_ ms: Int64) -> String {
        let total = max(0, Int(ms / 1000))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

