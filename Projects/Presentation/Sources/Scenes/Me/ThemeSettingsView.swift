import SwiftUI

public struct ThemeSettingsView: View {
    @ObservedObject var theme: ThemeStore
    @Environment(\.locale) private var locale

    public init(theme: ThemeStore) {
        self.theme = theme
    }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    themeSwatch(isDark: false)
                    themeSwatch(isDark: true)
                }
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .listRowBackground(TandemColors.secondaryGrouped)
                .accessibilityHidden(true)
            }

            Section {
                ForEach(AppAppearance.allCases) { option in
                    Button {
                        theme.appearance = option
                    } label: {
                        HStack {
                            Text(appearanceTitle(option))
                                .font(.system(size: 17))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if theme.appearance == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(TandemColors.systemBlue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(theme.appearance == option ? .isSelected : [])
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("When System is selected, Paircast follows your iOS appearance settings.")
            }
        }
        .id("\(theme.appearance.rawValue)-\(locale.identifier)")
        .scrollContentBackground(.hidden)
        .background(TandemColors.groupedBackground.ignoresSafeArea())
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(theme.appearance.preferredColorScheme)
        .onAppear { ThemeWindowApplier.apply(theme.appearance) }
        .onChange(of: theme.appearance) { _, appearance in
            ThemeWindowApplier.apply(appearance)
        }
    }

    private func appearanceTitle(_ option: AppAppearance) -> LocalizedStringKey {
        switch option {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private func themeSwatch(isDark: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                .frame(height: 18)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isDark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : Color.white)
                .padding(8)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(isDark ? Color.black : TandemColors.groupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
