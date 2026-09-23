import Foundation

/// Encodes sticker messages as group text: `[stk]` + JSON `StickerRef`.
public enum ChatStickerCodec {
    public static let prefix = "[stk]"
    public static let fallbackText = "[Sticker]"

    public static func encode(_ ref: StickerRef) throws -> String {
        let data = try JSONEncoder().encode(ref)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AppError.validation("Sticker encode failed")
        }
        return prefix + json
    }

    public static func decode(_ text: String) -> StickerRef? {
        guard text.hasPrefix(prefix) else { return nil }
        let json = String(text.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StickerRef.self, from: data)
    }

    public static func isStickerPayload(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }
}
