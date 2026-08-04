import Foundation

public struct User: Equatable, Sendable, Identifiable {
    public var id: String
    public var nickname: String
    /// Qiniu object key stored in IM `faceURL` (e.g. `_tandem/avatars/{userId}/{uuid}.jpg`).
    public var avatarKey: String?
    /// Short-lived signed HTTPS URL for UI, resolved from `avatarKey` + Endpoint.
    public var avatarURL: URL?

    public init(id: String, nickname: String, avatarKey: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.nickname = nickname
        self.avatarKey = avatarKey
        self.avatarURL = avatarURL
    }
}
