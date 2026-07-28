import Foundation
import Domain

public enum DataAssembly {
    public static func makeConfigGateway() -> ConfigGateway {
        KeychainConfigStore()
    }

    public static func makeUserSigGateway() -> UserSigGateway {
        LocalUserSigGateway()
    }

    public static func makeAuthGateway() -> AuthGateway {
        InMemoryAuthGateway()
    }

    public static func makeCatalogGateway() -> MovieCatalogGateway {
        QiniuMovieCatalogGateway()
    }

    public static func makeMetadataGateway() -> MetadataGateway {
        CascadingMetadataGateway()
    }

    public static func makeRoomGateway() -> RoomGateway {
        InMemoryRoomGateway()
    }

    public static func makeChatGateway() -> ChatGateway {
        InMemoryChatGateway()
    }

    public static func makeSyncGateway() -> PlaybackSyncGateway {
        InMemoryPlaybackSyncGateway()
    }

    public static func makeSubtitleGateway() -> SubtitleGateway {
        OpenSubtitlesGateway()
    }
}
