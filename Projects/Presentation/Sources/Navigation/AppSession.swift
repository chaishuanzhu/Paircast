import Foundation
import Domain

@MainActor
public final class AppSession: ObservableObject {
    @Published public var route: AppRoute
    /// In-library NavigationStack path (Watch / Config). Replaced, not stacked, for deep links.
    @Published public var libraryPath: [LibraryRoute] = []
    @Published public var config: AppCloudConfig?
    @Published public var currentUser: User?
    @Published public var toast: String?

    public let configGateway: ConfigGateway
    public let authGateway: AuthGateway
    public let userSigGateway: UserSigGateway
    public let catalogGateway: MovieCatalogGateway
    public let metadataGateway: MetadataGateway
    public let roomGateway: RoomGateway
    public let chatGateway: ChatGateway
    public let syncGateway: PlaybackSyncGateway
    public let subtitleGateway: SubtitleGateway
    public let sharedSubtitleStorage: SharedSubtitleStorageGateway

    /// Deep-link invite kept until the user finishes login.
    private(set) var pendingInvite: RoomInvite?
    /// Config share link (`paircast://config?args=…`) awaiting confirm-import on the config screen.
    private(set) var pendingConfigImportRaw: String?

    public init(
        configGateway: ConfigGateway,
        authGateway: AuthGateway,
        userSigGateway: UserSigGateway,
        catalogGateway: MovieCatalogGateway,
        metadataGateway: MetadataGateway,
        roomGateway: RoomGateway,
        chatGateway: ChatGateway,
        syncGateway: PlaybackSyncGateway,
        subtitleGateway: SubtitleGateway,
        sharedSubtitleStorage: SharedSubtitleStorageGateway
    ) {
        self.configGateway = configGateway
        self.authGateway = authGateway
        self.userSigGateway = userSigGateway
        self.catalogGateway = catalogGateway
        self.metadataGateway = metadataGateway
        self.roomGateway = roomGateway
        self.chatGateway = chatGateway
        self.syncGateway = syncGateway
        self.subtitleGateway = subtitleGateway
        self.sharedSubtitleStorage = sharedSubtitleStorage
        self.route = .splash
        installIMSessionObservers()
    }

    public func bootstrap() async {
        let started = ContinuousClock.now
        config = try? await configGateway.load()

        var next: AppRoute = .login
        var nextLibraryPath: [LibraryRoute] = []
        if let userId = try? await configGateway.loadSessionUserId(),
           let config,
           config.isComplete {
            do {
                let sig = try userSigGateway.generateUserSig(userId: userId, config: config)
                try await authGateway.login(userId: userId, userSig: sig)
                currentUser = try await authGateway.fetchProfile()
                next = .library
            } catch {
                next = .login
            }
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
            showToast("Sign in to join the room")
        }
        if pendingConfigImportRaw != nil {
            showToast("Configuration link detected. Confirm to import")
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

    public func handleDeepLink(_ url: URL) {
        if ConfigShareLink.isConfigShareURL(url) {
            pendingConfigImportRaw = url.absoluteString
            if route != .splash {
                openConfig(fromLogin: currentUser == nil)
                showToast("Configuration link detected. Confirm to import")
            }
            return
        }
        guard let invite = RoomInvite(url: url) else { return }
        if currentUser == nil {
            pendingInvite = invite
            if route != .splash {
                resetToLogin()
                showToast("Sign in to join the room")
            }
        } else {
            pendingInvite = nil
            openWatch(roomId: invite.roomId, movieId: invite.movieId, hostUserId: invite.hostUserId)
        }
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

    /// After a successful config import: keep Keychain payload, drop IM session, return to login.
    public func applyImportedCloudConfig(_ config: AppCloudConfig) async {
        self.config = config
        if currentUser != nil {
            try? await authGateway.logout()
            currentUser = nil
        }
        try? await configGateway.clearSessionUserId()
        pendingInvite = nil
        resetToLogin()
        showToast(TandemL10n.string("Configuration imported. Please sign in again"))
    }

    public func installIMSessionObservers() {
        NotificationCenter.default.addObserver(
            forName: .paircastIMKickedOffline,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleForcedLogout(message: TandemL10n.format(AppError.kickedOffline))
            }
        }
        NotificationCenter.default.addObserver(
            forName: .paircastIMUserSigExpired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleForcedLogout(message: TandemL10n.format(AppError.userSigExpired))
            }
        }
    }

    private func handleForcedLogout(message: String) {
        currentUser = nil
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
