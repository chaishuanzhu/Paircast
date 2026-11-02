import SwiftUI
import Presentation
import PaircastShared

@main
struct PaircastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = AppSession(graph: PaircastApp.makeGraph())
    @StateObject private var theme = ThemeStore()
    @StateObject private var language = LanguageStore()

    var body: some Scene {
        WindowGroup {
            RootView(session: session, theme: theme, language: language)
                .task { await session.bootstrap() }
                .onOpenURL { session.handleDeepLink($0) }
        }
    }

    private static func makeGraph() -> PaircastGraph {
        PaircastLog.installSharedSink()
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paircast", isDirectory: true)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paircast", isDirectory: true)
        for directory in [caches, support] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return PaircastGraph(
            secureStore: KeychainSecureStore(),
            keyValueStore: UserDefaultsKeyValueStore(),
            cacheDirectory: caches.path,
            supportDirectory: support.path,
            preferredLanguage: Locale.preferredLanguages.first ?? "en",
            appVersion: version
        )
    }
}
