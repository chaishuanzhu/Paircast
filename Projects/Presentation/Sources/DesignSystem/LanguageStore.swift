import Foundation
import SwiftUI
import Domain

/// In-app language preference. Default follows the system (Chinese → zh-Hans, otherwise English).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case chinese

    public var id: String { rawValue }

    public var localizedTitle: LocalizedStringKey {
        switch self {
        case .system: "Match System"
        case .english: "English"
        case .chinese: "简体中文"
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

    private static let localizedBundles: [String: Bundle] = {
        ["en", "zh-Hans"].reduce(into: [:]) { result, identifier in
            guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return }
            result[identifier] = bundle
        }
    }()

    /// Lookup in the explicitly selected language bundle. `String(localized:locale:)`
    /// only uses `locale` for formatting and does not switch the bundle localization.
    public static func string(_ key: String) -> String {
        let identifier = locale.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
        let bundle = localizedBundles[identifier] ?? .main
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Localize a template key, then replace `{{name}}` placeholders.
    public static func format(_ key: String, _ args: [String: String] = [:]) -> String {
        StringTemplate.apply(string(key), args)
    }

    public static func format(_ error: AppError) -> String {
        if case .incompleteConfig(let missing) = error {
            let separator = locale.identifier.hasPrefix("zh") ? "、" : ", "
            return format(
                error.localizationKey,
                ["fields": missing.map(localizedConfigField).joined(separator: separator)]
            )
        }
        return format(error.localizationKey, error.localizationArguments)
    }

    private static func localizedConfigField(_ field: String) -> String {
        guard let separator = field.lastIndex(of: " ") else {
            return string(field)
        }
        let prefix = field[..<separator]
        let fieldKey = field[field.index(after: separator)...]
        return "\(prefix) \(string(String(fieldKey)))"
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
