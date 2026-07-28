import SwiftUI

public enum TandemColors {
    public static let systemBlue = Color(red: 0, green: 122 / 255, blue: 1)
    public static let groupedBackground = Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255)
    public static let secondaryGrouped = Color.white
    public static let watchBackground = Color.black
    public static let danger = Color(red: 1, green: 59 / 255, blue: 48 / 255)
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
