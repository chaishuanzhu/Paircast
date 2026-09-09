import SwiftUI

public struct RootView: View {
    @ObservedObject var session: AppSession
    @ObservedObject var theme: ThemeStore
    @ObservedObject var language: LanguageStore

    public init(session: AppSession, theme: ThemeStore, language: LanguageStore) {
        self.session = session
        self.theme = theme
        self.language = language
    }

    public var body: some View {
        Group {
            switch session.route {
            case .splash:
                SplashView()
                    .transition(.opacity)
            case .login:
                LoginView(session: session)
                    .transition(.opacity)
            case .config(let fromLogin):
                ServiceConfigView(session: session, fromLogin: fromLogin)
                    .transition(.opacity)
            case .library:
                LibraryView(session: session, theme: theme, language: language)
                    .transition(.opacity)
            }
        }
        .environment(\.locale, language.effectiveLocale)
        // Do not `.id(locale)` here — it tears down presented sheets mid-language change.
        .preferredColorScheme(theme.appearance.preferredColorScheme)
        .onAppear { ThemeWindowApplier.apply(theme.appearance) }
        .onChange(of: theme.appearance) { _, appearance in
            ThemeWindowApplier.apply(appearance)
        }
        .animation(.easeInOut(duration: 0.35), value: session.route)
        .overlay(alignment: .bottom) {
            if let toast = session.toast {
                Text(LocalizedStringKey(toast))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if session.toast == toast {
                            session.toast = nil
                        }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: session.toast)
    }
}
