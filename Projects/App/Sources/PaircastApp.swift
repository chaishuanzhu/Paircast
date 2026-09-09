import SwiftUI
import Presentation
import Data
import Domain

@main
struct PaircastApp: App {
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
    @StateObject private var theme = ThemeStore()
    @StateObject private var language = LanguageStore()

    var body: some Scene {
        WindowGroup {
            RootView(session: session, theme: theme, language: language)
                .task { await session.bootstrap() }
                .onOpenURL { session.handleDeepLink($0) }
        }
    }
}
