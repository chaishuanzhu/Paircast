import Foundation

/// Local block list and report log for invite-only room chat (Guideline 1.2).
public struct ChatSafetyStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let blockPrefix = "tandem.chat.blocked."
    private let reportsKey = "tandem.chat.reports"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func blockedUserIds(ownerId: String) -> Set<String> {
        let raw = defaults.stringArray(forKey: blockKey(ownerId)) ?? []
        return Set(raw)
    }

    public func isBlocked(_ userId: String, ownerId: String) -> Bool {
        blockedUserIds(ownerId: ownerId).contains(userId)
    }

    public func block(_ userId: String, ownerId: String) {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ownerId else { return }
        var ids = blockedUserIds(ownerId: ownerId)
        ids.insert(trimmed)
        defaults.set(Array(ids).sorted(), forKey: blockKey(ownerId))
    }

    public func recordReport(targetUserId: String, ownerId: String, snippet: String) {
        var entries = defaults.stringArray(forKey: reportsKey) ?? []
        let line = "\(ISO8601DateFormatter().string(from: Date()))|\(ownerId)|\(targetUserId)|\(snippet.prefix(80))"
        entries.append(line)
        if entries.count > 50 {
            entries = Array(entries.suffix(50))
        }
        defaults.set(entries, forKey: reportsKey)
    }

    public func clear(ownerId: String) {
        defaults.removeObject(forKey: blockKey(ownerId))
    }

    public func visibleMessages(_ messages: [ChatMessage], ownerId: String) -> [ChatMessage] {
        messages.filter { message in
            if message.kind == .system { return true }
            guard let senderId = message.senderId else { return true }
            return !isBlocked(senderId, ownerId: ownerId)
        }
    }

    public static var reportURL: URL {
        var components = URLComponents(string: "https://github.com/chai-sz/Tandem/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "聊天内容举报"),
            URLQueryItem(
                name: "body",
                value: "请描述违规内容（房间为邀请制，仅处理你参与过的房间）。"
            ),
        ]
        return components.url ?? URL(string: "https://github.com/chai-sz/Tandem/issues")!
    }

    private func blockKey(_ ownerId: String) -> String {
        blockPrefix + ownerId
    }
}
