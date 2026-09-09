import SwiftUI

public struct LanguageSettingsView: View {
    @ObservedObject var language: LanguageStore

    public init(language: LanguageStore) {
        self.language = language
    }

    public var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { option in
                    Button {
                        language.language = option
                    } label: {
                        HStack {
                            Text(option.title)
                                .font(.system(size: 17))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if language.language == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(TandemColors.systemBlue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(language.language == option ? .isSelected : [])
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Choose Match System to follow iOS language settings. English and 简体中文 override the system.")
            }
        }
        .id(language.effectiveLocale.identifier)
        .scrollContentBackground(.hidden)
        .background(TandemColors.groupedBackground.ignoresSafeArea())
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}
