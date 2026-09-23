import XCTest
@testable import Domain

final class StickersObjectKeyTests: XCTestCase {
    func test_catalogWithoutPrefix() {
        XCTAssertEqual(
            StickersObjectKey.catalogKey(storagePrefix: nil),
            "stickers/catalog.json"
        )
    }

    func test_catalogWithPrefix() {
        XCTAssertEqual(
            StickersObjectKey.catalogKey(storagePrefix: "movies"),
            "movies/stickers/catalog.json"
        )
        XCTAssertEqual(
            StickersObjectKey.catalogKey(storagePrefix: "movies/"),
            "movies/stickers/catalog.json"
        )
    }

    func test_packAndAssetKeys() {
        XCTAssertEqual(
            StickersObjectKey.packManifestKey(packId: "doge", storagePrefix: nil),
            "stickers/doge/pack.json"
        )
        XCTAssertEqual(
            StickersObjectKey.assetKey(packId: "doge", fileName: "001.png", storagePrefix: "media/"),
            "media/stickers/doge/001.png"
        )
    }
}

final class ChatStickerCodecTests: XCTestCase {
    func test_roundTrip() throws {
        let ref = StickerRef(
            packId: "doge",
            stickerId: "001",
            format: "png",
            width: 240,
            height: 240,
            file: "001.png"
        )
        let encoded = try ChatStickerCodec.encode(ref)
        XCTAssertTrue(encoded.hasPrefix(ChatStickerCodec.prefix))
        let decoded = ChatStickerCodec.decode(encoded)
        XCTAssertEqual(decoded, ref)
    }

    func test_rejectsPlainText() {
        XCTAssertNil(ChatStickerCodec.decode("hello"))
        XCTAssertNil(ChatStickerCodec.decode("[sys]hi"))
        XCTAssertFalse(ChatStickerCodec.isStickerPayload("hello"))
    }
}

final class TwemojiCodepointsTests: XCTestCase {
    func test_simpleEmoji() {
        // 😀 = U+1F600
        XCTAssertEqual(Twemoji.codepoints(for: "😀"), "1f600")
        XCTAssertNotNil(Twemoji.imageURL(forEmoji: "😀"))
    }

    func test_heartWithVariationSelector() {
        // ❤️ = U+2764 U+FE0F → twemoji strips FE0F → 2764
        XCTAssertEqual(Twemoji.codepoints(for: "❤️"), "2764")
    }

    func test_flagSequence() {
        // 🇨🇳 = regional indicators
        let code = Twemoji.codepoints(for: "🇨🇳")
        XCTAssertEqual(code, "1f1e8-1f1f3")
    }

    func test_runsSplitTextAndEmoji() {
        let runs = Twemoji.runs(in: "hi😀!")
        XCTAssertEqual(runs.count, 3)
        guard case .text("hi") = runs[0] else { return XCTFail("plain prefix") }
        guard case .emoji("😀", _) = runs[1] else { return XCTFail("emoji") }
        guard case .text("!") = runs[2] else { return XCTFail("plain suffix") }
    }

    func test_cdnUsesJdeckedHost() {
        let url = Twemoji.imageURL(forEmoji: "😀")
        XCTAssertEqual(url?.host, "raw.githubusercontent.com")
        XCTAssertTrue(url?.path.contains("1f600.png") == true)
    }
}
