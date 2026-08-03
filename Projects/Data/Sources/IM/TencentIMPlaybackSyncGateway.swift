import Foundation
import Domain

public final class TencentIMPlaybackSyncGateway: PlaybackSyncGateway, @unchecked Sendable {
    private let client: TencentIMClient

    public init(client: TencentIMClient = .shared) {
        self.client = client
    }

    public func send(roomId: String, signal: PlaybackSyncSignal) async throws {
        try await client.sendSignal(roomId: roomId, signal: signal)
    }

    public func signals(roomId: String) -> AsyncStream<PlaybackSyncSignal> {
        client.signals(roomId: roomId)
    }
}
