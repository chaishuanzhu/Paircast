import Foundation

/// Twemoji helpers — wire format remains Unicode; display prefers bundled PNGs, then CDN.
/// Assets: App `Resources/Twemoji/{codepoints}.png` (picker set) +
/// CDN `https://raw.githubusercontent.com/jdecked/twemoji/v15.1.0/assets/72x72/{codepoints}.png`
public enum Twemoji {
    public static let version = "15.1.0"
    public static let sizeFolder = "72x72"
    public static let cdnBase =
        "https://raw.githubusercontent.com/jdecked/twemoji/v\(version)/assets/"

    /// Curated picker list (Unicode inserted into the draft).
    public static let pickerEmojis: [String] = [
        "😀", "😂", "🥰", "😍", "🤔", "😎", "😭", "😡",
        "👍", "👎", "👏", "🙏", "🔥", "✨", "🎉", "❤️",
        "😊", "🤗", "😴", "🤝", "💪", "🌟", "💯", "😅",
        "🤣", "😘", "😜", "🥺", "😱", "🙄", "😇", "🤩",
        "😢", "😤", "🥳", "😋", "😏", "😌", "😳", "🤭",
        "👋", "✌️", "🤞", "👀", "💬", "🎵", "🍿", "🎬",
    ]

    public static func imageURL(forEmoji emoji: String) -> URL? {
        let code = codepoints(for: emoji)
        guard !code.isEmpty else { return nil }
        return URL(string: "\(cdnBase)\(sizeFolder)/\(code).png")
    }

    /// Bundle resource name without extension (`2764`, `1f600`, …).
    public static func resourceName(forEmoji emoji: String) -> String {
        codepoints(for: emoji)
    }

    /// Converts a single emoji grapheme to Twemoji's hyphenated hex codepoint path.
    /// Matches twemoji `grabTheRightIcon`: strip U+FE0F only when the glyph has no ZWJ.
    public static func codepoints(for emoji: String) -> String {
        let hasZWJ = emoji.unicodeScalars.contains { $0.value == 0x200D }
        var scalars: [UInt32] = []
        for scalar in emoji.unicodeScalars {
            let v = scalar.value
            if !hasZWJ, v == 0xFE0F { continue }
            scalars.append(v)
        }
        if scalars.isEmpty {
            scalars = emoji.unicodeScalars.map(\.value)
        }
        return scalars.map { String($0, radix: 16) }.joined(separator: "-")
    }

    /// Splits text into plain / emoji runs for inline Twemoji rendering.
    public static func runs(in text: String) -> [TwemojiRun] {
        var result: [TwemojiRun] = []
        var plain = ""
        for ch in text {
            if ch.isTwemojiCandidate {
                let glyph = String(ch)
                if !plain.isEmpty {
                    result.append(.text(plain))
                    plain = ""
                }
                result.append(.emoji(glyph, imageURL(forEmoji: glyph)))
            } else {
                plain.append(ch)
            }
        }
        if !plain.isEmpty {
            result.append(.text(plain))
        }
        return result
    }
}

public enum TwemojiRun: Equatable, Sendable {
    case text(String)
    /// CDN URL may be nil when codepoints are empty; UI still has the glyph for fallback.
    case emoji(String, URL?)
}

extension Character {
    /// Heuristic: treat as emoji if it has emoji presentation or sits in common emoji blocks.
    public var isTwemojiCandidate: Bool {
        guard unicodeScalars.first != nil else { return false }
        if unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
            return true
        }
        if unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0xFF }) {
            return true
        }
        if unicodeScalars.count >= 2,
           unicodeScalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
            return true
        }
        return false
    }
}
