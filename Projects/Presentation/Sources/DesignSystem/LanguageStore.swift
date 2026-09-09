import Foundation
import SwiftUI
import Domain

/// In-app language preference. Default follows the system (Chinese → zh-Hans, otherwise English).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case chinese

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system:
            return String(localized: "Match System", table: "Localizable", bundle: .main, locale: TandemL10n.locale)
        case .english:
            return "English"
        case .chinese:
            return "简体中文"
        }
    }

    /// Resolved locale used for string lookup and SwiftUI environment.
    public var resolvedLocale: Locale {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("zh") {
                return Locale(identifier: "zh-Hans")
            }
            return Locale(identifier: "en")
        case .english:
            return Locale(identifier: "en")
        case .chinese:
            return Locale(identifier: "zh-Hans")
        }
    }
}

/// Shared locale for ViewModels / non-SwiftUI string lookup. Kept in sync by `LanguageStore`.
///
/// Keys live in the App target `Localizable.xcstrings` and are looked up at runtime via
/// `Bundle.main`. Xcode cannot extract those references across Presentation/Domain, so catalog
/// entries are marked `extractionState: manual` (not stale).
public enum TandemL10n {
    nonisolated(unsafe) public static var locale: Locale = AppLanguage.system.resolvedLocale

    /// Lookup in the app bundle String Catalog. Keys are the English source strings.
    public static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Localizable", bundle: .main, locale: locale)
    }

    public static func string(_ key: String) -> String {
        string(String.LocalizationValue(stringLiteral: key))
    }

    /// Localize a template key, then replace `{{name}}` placeholders.
    public static func format(_ key: String, _ args: [String: String] = [:]) -> String {
        StringTemplate.apply(string(key), args)
    }

    public static func format(_ error: AppError) -> String {
        format(error.localizationKey, error.localizationArguments)
    }
}

@MainActor
public final class LanguageStore: ObservableObject {
    private static let defaultsKey = "tandem.language"

    private let defaults: UserDefaults

    @Published public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    public var effectiveLocale: Locale { language.resolvedLocale }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.defaultsKey),
           let value = AppLanguage(rawValue: raw) {
            language = value
        } else {
            language = .system
        }
        apply()
    }

    private func apply() {
        TandemL10n.locale = language.resolvedLocale
    }
}
