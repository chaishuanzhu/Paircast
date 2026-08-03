import SwiftUI

public struct RootView: View {
    @ObservedObject var session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public var body: some View {
        Group {
            switch session.route {
            case .login:
                LoginView(session: session)
            case .config(let fromLogin):
                ServiceConfigView(session: session, fromLogin: fromLogin)
            case .library:
                LibraryView(session: session)
            case .watch(let roomId, let movieId, let hostUserId):
                WatchView(session: session, roomId: roomId, movieId: movieId, hostUserId: hostUserId)
            }
        }
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
