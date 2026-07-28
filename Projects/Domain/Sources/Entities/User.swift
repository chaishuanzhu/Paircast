import Foundation

public struct User: Equatable, Sendable, Identifiable {
    public var id: String
    public var nickname: String
    public var avatarURL: URL?

    public init(id: String, nickname: String, avatarURL: URL? = nil) {
        self.id = id
        self.nickname = nickname
        self.avatarURL = avatarURL
    }
}
