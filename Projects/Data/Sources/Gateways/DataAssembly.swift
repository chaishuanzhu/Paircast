import Foundation
import Domain

public enum DataAssembly {
    private static let imClient = TencentIMClient.shared

    public static func makeConfigGateway() -> ConfigGateway {
        KeychainConfigStore()
    }

    public static func makeUserSigGateway() -> UserSigGateway {
        LocalUserSigGateway()
    }

    public static func makeAuthGateway(configGateway: ConfigGateway = makeConfigGateway()) -> AuthGateway {
        TencentIMAuthGateway(configGateway: configGateway, client: imClient)
    }

    public static func makeCatalogGateway() -> MovieCatalogGateway {
        QiniuMovieCatalogGateway()
    }

    public static func makeMetadataGateway() -> MetadataGateway {
        CascadingMetadataGateway()
    }

    public static func makeRoomGateway(configGateway: ConfigGateway = makeConfigGateway()) -> RoomGateway {
        IMSyncedRoomGateway(
            storage: QiniuRoomGateway(configGateway: configGateway),
            client: imClient
        )
    }

    public static func makeChatGateway() -> ChatGateway {
        TencentIMChatGateway(client: imClient)
    }

    public static func makeSyncGateway() -> PlaybackSyncGateway {
        TencentIMPlaybackSyncGateway(client: imClient)
    }

    public static func makeSubtitleGateway() -> SubtitleGateway {
        OpenSubtitlesGateway()
    }
}
