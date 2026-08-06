import SwiftUI
import Presentation
import Data
import Domain

@main
struct TandemApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = AppSession(
        configGateway: DataAssembly.makeConfigGateway(),
        authGateway: DataAssembly.makeAuthGateway(),
        userSigGateway: DataAssembly.makeUserSigGateway(),
        catalogGateway: DataAssembly.makeCatalogGateway(),
        metadataGateway: DataAssembly.makeMetadataGateway(),
        roomGateway: DataAssembly.makeRoomGateway(),
        chatGateway: DataAssembly.makeChatGateway(),
        syncGateway: DataAssembly.makeSyncGateway(),
        subtitleGateway: DataAssembly.makeSubtitleGateway(),
        sharedSubtitleStorage: DataAssembly.makeSharedSubtitleStorage()
    )

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task { await session.bootstrap() }
                .onOpenURL { session.handleDeepLink($0) }
        }
    }
}
