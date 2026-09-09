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
        TencentIMAuthGateway(
            configGateway: configGateway,
            avatarStorage: OSSAvatarStorage(),
            client: imClient
        )
    }

    public static func makeCatalogGateway() -> MovieCatalogGateway {
        OSSMovieCatalogGateway()
    }

    public static func makeMetadataGateway() -> MetadataGateway {
        CascadingMetadataGateway(storage: OSSMovieMetadataStorage())
    }

    public static func makeMovieMetadataStorage() -> MovieMetadataStorageGateway {
        OSSMovieMetadataStorage()
    }

    public static func makeRoomGateway(configGateway: ConfigGateway = makeConfigGateway()) -> RoomGateway {
        IMSyncedRoomGateway(
            storage: OSSRoomGateway(configGateway: configGateway),
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

    public static func makeSharedSubtitleStorage() -> SharedSubtitleStorageGateway {
        OSSSharedSubtitleStorage()
    }
}
