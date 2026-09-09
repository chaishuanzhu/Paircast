import Foundation
import SwiftUI
import UIKit

/// User-facing appearance preference (designtoken.md Theme Settings).
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system:
            return TandemL10n.string("Match System")
        case .light:
            return TandemL10n.string("Light")
        case .dark:
            return TandemL10n.string("Dark")
        }
    }

    /// `nil` means defer to the OS.
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Sheets host their own windows; SwiftUI `preferredColorScheme` on the root
/// often does not update an already-presented sheet. Override every window.
@MainActor
public enum ThemeWindowApplier {
    public static func apply(_ appearance: AppAppearance) {
        applyNow(appearance)
        // Sheet windows can appear a runloop later than the preference change.
        Task { @MainActor in
            await Task.yield()
            applyNow(appearance)
        }
    }

    private static func applyNow(_ appearance: AppAppearance) {
        let style = appearance.userInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if window.overrideUserInterfaceStyle != style {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}

@MainActor
public final class ThemeStore: ObservableObject {
    private static let defaultsKey = "tandem.appearance"

    private let defaults: UserDefaults

    @Published public var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.defaultsKey)
            ThemeWindowApplier.apply(appearance)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.defaultsKey),
           let value = AppAppearance(rawValue: raw) {
            appearance = value
        } else {
            appearance = .system
        }
    }
}
