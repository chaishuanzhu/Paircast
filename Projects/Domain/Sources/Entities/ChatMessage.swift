import Foundation

public struct ChatMessage: Equatable, Sendable, Identifiable {
    public var id: String
    public var roomId: String
    public var senderId: String?
    public var senderNickname: String
    public var text: String
    public var kind: ChatMessageKind
    public var createdAt: Date

    public init(
        id: String,
        roomId: String,
        senderId: String? = nil,
        senderNickname: String,
        text: String,
        kind: ChatMessageKind = .user,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.roomId = roomId
        self.senderId = senderId
        self.senderNickname = senderNickname
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
    }
}

public enum ChatMessageKind: String, Equatable, Sendable {
    case user
    case system
}
