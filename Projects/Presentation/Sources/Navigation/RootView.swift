import SwiftUI

public struct RootView: View {
    @ObservedObject var session: AppSession
    @ObservedObject var theme: ThemeStore

    public init(session: AppSession, theme: ThemeStore) {
        self.session = session
        self.theme = theme
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
                LibraryView(session: session, theme: theme)
                    .transition(.opacity)
            case .watch(let roomId, let movieId, let hostUserId):
                WatchView(session: session, theme: theme, roomId: roomId, movieId: movieId, hostUserId: hostUserId)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(theme.appearance.preferredColorScheme)
        .onAppear { ThemeWindowApplier.apply(theme.appearance) }
        .onChange(of: theme.appearance) { _, appearance in
            ThemeWindowApplier.apply(appearance)
        }
        .animation(.easeInOut(duration: 0.35), value: session.route)
        .overlay(alignment: .bottom) {
            if let toast = session.toast {
                Text(toast)
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
