import Foundation
import Domain

@MainActor
public final class AppSession: ObservableObject {
    @Published public var route: AppRoute
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

    public init(
        configGateway: ConfigGateway,
        authGateway: AuthGateway,
        userSigGateway: UserSigGateway,
        catalogGateway: MovieCatalogGateway,
        metadataGateway: MetadataGateway,
        roomGateway: RoomGateway,
        chatGateway: ChatGateway,
        syncGateway: PlaybackSyncGateway,
        subtitleGateway: SubtitleGateway
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
        self.route = .login
    }

    public func bootstrap() async {
        config = try? await configGateway.load()
        if let userId = try? await configGateway.loadSessionUserId(),
           let config,
           config.isComplete {
            do {
                let sig = try userSigGateway.generateUserSig(userId: userId, config: config)
                try await authGateway.login(userId: userId, userSig: sig)
                currentUser = try await authGateway.fetchProfile()
                route = .library
            } catch {
                route = .login
            }
        } else {
            route = .login
        }
    }

    public func showToast(_ message: String) {
        toast = message
    }

    public func handleDeepLink(_ url: URL) {
        guard url.scheme == "tandem" else { return }
        if url.host == "watch",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let roomId = components.queryItems?.first(where: { $0.name == "roomId" })?.value {
            if currentUser == nil {
                route = .login
                showToast("请先登录再加入房间")
            } else {
                route = .watch(roomId: roomId, movieId: nil)
            }
        }
    }
}

public enum AppRoute: Equatable, Hashable {
    case login
    case config(fromLogin: Bool)
    case library
    case watch(roomId: String?, movieId: String?)
}
