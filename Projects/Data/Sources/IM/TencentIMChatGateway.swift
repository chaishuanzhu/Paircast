import Foundation
import Domain

public final class TencentIMChatGateway: ChatGateway, @unchecked Sendable {
    private let client: TencentIMClient

    public init(client: TencentIMClient = .shared) {
        self.client = client
    }

    public func send(roomId: String, text: String, sender: User) async throws -> ChatMessage {
        try await client.sendText(
            roomId: roomId,
            text: text,
            asSystem: false,
            senderId: sender.id,
            senderNickname: sender.nickname
        )
    }

    public func messages(roomId: String) -> AsyncStream<ChatMessage> {
        client.textMessages(roomId: roomId)
    }

    public func postSystemMessage(roomId: String, text: String) async throws -> ChatMessage {
        try await client.sendSystemText(roomId: roomId, text: text)
    }
}
