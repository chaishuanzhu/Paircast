import XCTest
@testable import Presentation
import PaircastShared

@MainActor
final class WaterfallLayoutTests: XCTestCase {
    func test_columnCount_phonePortrait() {
        XCTAssertEqual(WaterfallLayout.columnCount(for: 361), 2) // 393 - 32 padding
    }

    func test_columnCount_scalesForIPadWidths() {
        XCTAssertEqual(WaterfallLayout.columnCount(for: 500), 2)
        XCTAssertEqual(WaterfallLayout.columnCount(for: 700), 3)
        XCTAssertEqual(WaterfallLayout.columnCount(for: 900), 5)
        XCTAssertEqual(WaterfallLayout.columnCount(for: 1200), 5)
    }

    func test_columnCount_respectsMaxColumns() {
        XCTAssertEqual(
            WaterfallLayout.columnCount(for: 2000, minColumnWidth: 168, maxColumns: 4),
            4
        )
    }
}

@MainActor
final class ThemeStoreTests: XCTestCase {
    func test_defaultsToSystem() {
        let suite = "tandem.theme.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.appearance, .system)
        XCTAssertNil(store.appearance.preferredColorScheme)
    }

    func test_persistsAppearance() {
        let suite = "tandem.theme.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ThemeStore(defaults: defaults)
        store.appearance = .dark
        XCTAssertEqual(store.appearance.preferredColorScheme, .dark)

        let reloaded = ThemeStore(defaults: defaults)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.appearance.title, "Dark")
    }
}

@MainActor
final class LanguageStoreTests: XCTestCase {
    func test_defaultsToSystem() {
        let suite = "tandem.language.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LanguageStore(defaults: defaults)
        XCTAssertEqual(store.language, .system)
    }

    func test_persistsLanguageAndUpdatesSharedLocale() {
        let suite = "tandem.language.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = LanguageStore(defaults: defaults)
        store.language = .chinese
        XCTAssertEqual(store.effectiveLocale.identifier, "zh-Hans")
        XCTAssertEqual(TandemL10n.locale.identifier, "zh-Hans")

        let reloaded = LanguageStore(defaults: defaults)
        XCTAssertEqual(reloaded.language, .chinese)

        store.language = .english
        XCTAssertEqual(store.effectiveLocale.identifier, "en")
        XCTAssertEqual(TandemL10n.locale.identifier, "en")
    }
}

@MainActor
final class InviteUseCasePresentationTests: XCTestCase {
    func test_inviteURLFormat() {
        let url = URL(string: InviteLinks.shared.inviteUrl(
            roomId: "abc",
            movieId: "film.mkv",
            hostUserId: "alice",
            inviterName: "小明",
            movieTitle: "流浪地球"
        ))!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "paircast.chaisz.com")
        XCTAssertEqual(url.path(percentEncoded: false), "/invite/")
        XCTAssertEqual(items.first(where: { $0.name == "roomId" })?.value, "abc")
        XCTAssertEqual(items.first(where: { $0.name == "movieId" })?.value, "film.mkv")
        XCTAssertEqual(items.first(where: { $0.name == "hostUserId" })?.value, "alice")
        XCTAssertEqual(items.first(where: { $0.name == "inviter" })?.value, "小明")
        XCTAssertEqual(items.first(where: { $0.name == "title" })?.value, "流浪地球")
    }
}

@MainActor
final class AppRouteDeepLinkTests: XCTestCase {
    override func setUp() async throws {
        AppSession.minimumSplashDuration = .milliseconds(0)
        TandemL10n.locale = Locale(identifier: "en")
    }

    override func tearDown() async throws {
        AppSession.minimumSplashDuration = .milliseconds(1_400)
        TandemL10n.locale = AppLanguage.system.resolvedLocale
    }

    func test_watchDeepLinkRequiresLoginAndKeepsPendingInvite() async {
        let session = makeSession()
        session.handleDeepLink(URL(string: "paircast://watch?roomId=r1&movieId=m1&hostUserId=host")!)
        XCTAssertEqual(session.route, .splash)
        XCTAssertEqual(session.pendingInvite?.roomId, "r1")
        XCTAssertEqual(session.pendingInvite?.movieId, "m1")
        XCTAssertEqual(session.pendingInvite?.hostUserId, "host")

        await session.bootstrap()
        XCTAssertEqual(session.route, .login)
        XCTAssertEqual(session.toast, "Sign in to join the room")
        XCTAssertEqual(session.pendingInvite?.roomId, "r1")
    }

    func test_watchDeepLinkOpensWatchWhenLoggedIn() async {
        let session = makeSession()
        session.currentUser = User(id: "bob", nickname: "bob", avatarUrl: nil, username: nil, email: nil)
        session.handleDeepLink(URL(string: "paircast://watch?roomId=r1&movieId=m1&hostUserId=host")!)
        XCTAssertEqual(session.route, .library)
        XCTAssertEqual(
            session.libraryPath,
            [.watch(roomId: "r1", movieId: "m1", hostUserId: "host")]
        )
        XCTAssertNil(session.pendingInvite)
    }

    func test_tandemWatchDeepLinkIsIgnored() {
        XCTAssertNil(RoomInvite(url: URL(string: "tandem://watch?roomId=r1&movieId=m1&hostUserId=host")!))
        let session = makeSession()
        session.handleDeepLink(URL(string: "tandem://watch?roomId=r1&movieId=m1&hostUserId=host")!)
        XCTAssertNil(session.pendingInvite)
        XCTAssertEqual(session.route, .splash)
        XCTAssertTrue(session.libraryPath.isEmpty)
    }

    func test_consumePendingInvitePushesLibraryWatch() {
        let session = makeSession()
        session.handleDeepLink(URL(string: "paircast://watch?roomId=r1&movieId=m1&hostUserId=host")!)
        session.currentUser = User(id: "bob", nickname: "bob", avatarUrl: nil, username: nil, email: nil)
        session.consumePendingInviteIfPossible()
        XCTAssertEqual(session.route, .library)
        XCTAssertEqual(
            session.libraryPath,
            [.watch(roomId: "r1", movieId: "m1", hostUserId: "host")]
        )
        XCTAssertNil(session.pendingInvite)
    }

    func test_configDeepLinkIsIgnored() async {
        let session = makeSession()
        session.handleDeepLink(URL(string: "paircast://config?args=abc")!)
        await session.bootstrap()
        XCTAssertEqual(session.route, .login)
        XCTAssertNil(session.toast)
    }

    func test_bootstrapLeavesSplashForLoginWhenUnauthenticated() async {
        let session = makeSession()
        XCTAssertEqual(session.route, .splash)
        await session.bootstrap()
        XCTAssertEqual(session.route, .login)
    }

    private func makeSession() -> AppSession {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("paircast-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let graph = PaircastGraph(
            secureStore: InMemorySecureStore(),
            keyValueStore: InMemoryKeyValueStore(),
            cacheDirectory: root.appendingPathComponent("cache").path,
            supportDirectory: root.appendingPathComponent("support").path,
            preferredLanguage: "en",
            appVersion: "test"
        )
        return AppSession(graph: graph)
    }
}

private extension AppCloudConfig {
    static func fixture() -> AppCloudConfig {
        AppCloudConfig(
            im: IMConfig(serverUrl: "https://im.example.com"),
            updatedAtMs: 0,
            configVersion: AppCloudConfig.companion.CURRENT_VERSION
        )
    }
}

@MainActor
final class SharedBridgeTests: XCTestCase {
    func test_kotlinAppErrorSurvivesSwiftThrow() async {
        let graph = PaircastGraph(
            secureStore: InMemorySecureStore(),
            keyValueStore: InMemoryKeyValueStore(),
            cacheDirectory: NSTemporaryDirectory(),
            supportDirectory: NSTemporaryDirectory(),
            preferredLanguage: "en",
            appVersion: "test"
        )
        do {
            _ = try await graph.login.invoke(account: "alice", password: "secret")
            XCTFail("expected NotConfigured")
        } catch {
            XCTAssertTrue(AppErrors.from(error) is AppError.NotConfigured)
        }
    }

    func test_keyValueStoreReadsLegacyIntOffsets() {
        let suite = "paircast.kv.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1500, forKey: "tandem.subtitle.offset.m1")
        let offsets = SubtitleOffsetStore(store: UserDefaultsKeyValueStore(defaults: defaults))
        XCTAssertEqual(offsets.load(movieId: "m1"), 1500)
    }
}
