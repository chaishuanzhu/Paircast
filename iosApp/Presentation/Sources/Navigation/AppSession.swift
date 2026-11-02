import Foundation
import PaircastShared

@MainActor
public final class AppSession: ObservableObject {
    @Published public var route: AppRoute
    /// In-library NavigationStack path (Watch / Config). Replaced, not stacked, for deep links.
    @Published public var libraryPath: [LibraryRoute] = []
    @Published public var config: AppCloudConfig?
    @Published public var currentUser: User?
    @Published public var toast: String?
    /// Set after a login that requires a password change before entering the library.
    @Published public var mustChangePassword = false

    public let graph: PaircastGraph
    public var configGateway: ConfigGateway { graph.configGateway }
    public var authGateway: AuthGateway { graph.authGateway }
    public var catalogGateway: MovieCatalogGateway { graph.catalogGateway }
    public var roomGateway: RoomGateway { graph.roomGateway }
    public var subtitleGateway: SubtitleGateway { graph.subtitleGateway }
    public var stickerCatalog: StickerCatalogGateway { graph.stickerCatalog }

    /// Deep-link invite kept until the user finishes login.
    private(set) var pendingInvite: RoomInvite?
    /// Config share link (`paircast://config?args=…`) awaiting confirm-import on the config screen.
    private(set) var pendingConfigImportRaw: String?
    private var sessionEventsTask: Task<Void, Never>?

    public init(graph: PaircastGraph) {
        self.graph = graph
        self.route = .splash
        observeSessionEvents()
    }

    deinit {
        sessionEventsTask?.cancel()
    }

    public func bootstrap() async {
        let started = ContinuousClock.now
        await LegacyConfigMigration.migrateIfNeeded(into: configGateway)
        config = try? await configGateway.load()

        var next: AppRoute = .login
        var nextLibraryPath: [LibraryRoute] = []
        if config?.isComplete == true, let user = try? await authGateway.restoreSession() {
            currentUser = user
            next = .library
        }

        // Deep links received during splash win over the default destination.
        if pendingConfigImportRaw != nil {
            if currentUser == nil {
                next = .config(fromLogin: true)
            } else {
                next = .library
                nextLibraryPath = [.config]
            }
        } else if currentUser != nil, let invite = pendingInvite {
            pendingInvite = nil
            next = .library
            nextLibraryPath = [
                .watch(roomId: invite.roomId, movieId: invite.movieId, hostUserId: invite.hostUserId)
            ]
        }

        await Self.waitMinimumSplash(since: started)

        // A logged-in watch deep link may already have left splash.
        guard route == .splash else { return }
        route = next
        libraryPath = nextLibraryPath
        if case .login = next, pendingInvite != nil {
            showToast(TandemL10n.string("Sign in to join the room"))
        }
        if pendingConfigImportRaw != nil {
            showToast(TandemL10n.string("Configuration link detected. Confirm to import"))
        }
    }

    /// Overridable for tests (default ~1.4s brand beat).
    public static var minimumSplashDuration: Duration = .milliseconds(1_400)

    private static func waitMinimumSplash(since started: ContinuousClock.Instant) async {
        let minimum = minimumSplashDuration
        let elapsed = started.duration(to: .now)
        if elapsed < minimum {
            try? await Task.sleep(for: minimum - elapsed)
        }
    }

    public func showToast(_ message: String) {
        toast = message
    }

    /// Password login. Routes into the library unless the server requires a password change first.
    public func login(account: String, password: String) async throws {
        let result = try await graph.login.invoke(account: account, password: password)
        currentUser = result.user
        if result.mustChangePassword {
            mustChangePassword = true
            return
        }
        finishLogin()
    }

    public func changePassword(old: String, new: String, confirm: String) async throws {
        try await graph.changePassword.invoke(oldPassword: old, newPassword: new, confirm: confirm)
        if mustChangePassword {
            mustChangePassword = false
            finishLogin()
        } else {
            showToast(TandemL10n.string("Password updated"))
        }
    }

    /// Abandons a forced password change and returns to the sign-in form.
    public func cancelForcedPasswordChange() async {
        mustChangePassword = false
        await logout()
    }

    public func logout() async {
        try? await authGateway.logout()
        currentUser = nil
        pendingInvite = nil
        resetToLogin()
    }

    private func finishLogin() {
        route = .library
        libraryPath = []
        consumePendingInviteIfPossible()
    }

    public func handleDeepLink(_ url: URL) {
        if Self.isConfigShareURL(url) {
            pendingConfigImportRaw = url.absoluteString
            if route != .splash {
                openConfig(fromLogin: currentUser == nil)
                showToast(TandemL10n.string("Configuration link detected. Confirm to import"))
            }
            return
        }
        guard let invite = RoomInvite(url: url) else { return }
        if currentUser == nil {
            pendingInvite = invite
            if route != .splash {
                resetToLogin()
                showToast(TandemL10n.string("Sign in to join the room"))
            }
        } else {
            pendingInvite = nil
            openWatch(roomId: invite.roomId, movieId: invite.movieId, hostUserId: invite.hostUserId)
        }
    }

    static func isConfigShareURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "paircast" && url.host?.lowercased() == "config"
    }

    /// Consumes a pending config share once the config screen is ready to preview it.
    public func consumePendingConfigImport() -> String? {
        defer { pendingConfigImportRaw = nil }
        return pendingConfigImportRaw
    }

    /// Call after a successful login so a queued invite can open the watch scene.
    public func consumePendingInviteIfPossible() {
        guard currentUser != nil, let invite = pendingInvite else { return }
        pendingInvite = nil
        openWatch(roomId: invite.roomId, movieId: invite.movieId, hostUserId: invite.hostUserId)
    }

    public func openWatch(roomId: String?, movieId: String?, hostUserId: String?) {
        route = .library
        libraryPath = [.watch(roomId: roomId, movieId: movieId, hostUserId: hostUserId)]
    }

    public func openLibraryConfig() {
        route = .library
        libraryPath = [.config]
    }

    public func popLibraryToRoot() {
        libraryPath = []
    }

    /// Config from login stays a root scene; logged-in config is a library push.
    public func openConfig(fromLogin: Bool) {
        if fromLogin {
            libraryPath = []
            route = .config(fromLogin: true)
        } else {
            openLibraryConfig()
        }
    }

    public func resetToLogin() {
        libraryPath = []
        route = .login
    }

    /// After a config import / server change: keep the new config, drop the IM session, return to login.
    public func applyImportedCloudConfig(_ config: AppCloudConfig) async {
        self.config = config
        if currentUser != nil {
            try? await authGateway.logout()
            currentUser = nil
        }
        pendingInvite = nil
        try? await graph.clearMetadataCache()
        resetToLogin()
        showToast(TandemL10n.string("Configuration imported. Please sign in again"))
    }

    private func observeSessionEvents() {
        let events = authGateway.events
        sessionEventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch onEnum(of: event) {
                case .kickedOffline:
                    self.handleForcedLogout(message: TandemL10n.format(AppError.kickedOffline))
                case .tokenExpired:
                    self.handleForcedLogout(message: TandemL10n.format(AppError.sessionExpired))
                }
            }
        }
    }

    private func handleForcedLogout(message: String) {
        guard currentUser != nil else { return }
        currentUser = nil
        mustChangePassword = false
        pendingInvite = nil
        resetToLogin()
        showToast(message)
    }
}

public struct RoomInvite: Equatable, Sendable {
    public var roomId: String
    public var movieId: String?
    public var hostUserId: String?

    public init(roomId: String, movieId: String? = nil, hostUserId: String? = nil) {
        self.roomId = roomId
        self.movieId = movieId
        self.hostUserId = hostUserId
    }

    public init?(url: URL) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "paircast", url.host == "watch" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let roomId = items.first(where: { $0.name == "roomId" })?.value,
              !roomId.isEmpty else { return nil }
        self.roomId = roomId
        self.movieId = items.first(where: { $0.name == "movieId" })?.value
        self.hostUserId = items.first(where: { $0.name == "hostUserId" })?.value
    }
}

public enum AppRoute: Equatable, Hashable {
    case splash
    case login
    case config(fromLogin: Bool)
    case library
}

public enum LibraryRoute: Hashable {
    case config
    case watch(roomId: String?, movieId: String?, hostUserId: String?)
}
