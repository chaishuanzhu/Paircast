import Foundation

/// Detects common subtitle encodings and rewrites bytes as UTF-8 for VLC.
enum SubtitleEncodingNormalizer {
    /// Returns UTF-8 data suitable for VLC (may include BOM when written via `writeUTF8File`).
    static func utf8Data(from raw: Data) -> Data {
        if raw.isEmpty { return raw }

        var candidates: [(encoding: String.Encoding, label: String)] = [
            (.utf8, "utf8"),
        ]
        if let gb18030 = encoding(CFStringEncodings.GB_18030_2000) {
            candidates.append((gb18030, "gb18030"))
        }
        if let gbk = encoding(CFStringEncodings.GBK_95) {
            candidates.append((gbk, "gbk"))
        }
        if let gb2312 = encoding(CFStringEncodings.GB_2312_80) {
            candidates.append((gb2312, "gb2312"))
        }
        if let big5 = encoding(CFStringEncodings.big5) {
            candidates.append((big5, "big5"))
        }
        candidates.append(contentsOf: [
            (.utf16LittleEndian, "utf16le"),
            (.utf16BigEndian, "utf16be"),
            (.isoLatin1, "latin1"),
            (.windowsCP1252, "cp1252"),
        ])

        var best: (score: Int, text: String)?
        for (encoding, _) in candidates {
            guard let text = String(data: raw, encoding: encoding) else { continue }
            let score = scoreDecodedText(text)
            if best == nil || score > best!.score {
                best = (score, text)
            }
        }

        if let best, let utf8 = best.text.data(using: .utf8) {
            return stripUTF8BOM(utf8)
        }
        return stripUTF8BOM(Data(String(decoding: raw, as: UTF8.self).utf8))
    }

    /// Writes normalized UTF-8 subtitle with BOM (helps VLC subtitle decoder pick UTF-8).
    static func writeUTF8File(raw: Data, to url: URL) throws {
        let utf8 = utf8Data(from: raw)
        let bom = Data([0xEF, 0xBB, 0xBF])
        let payload = utf8.starts(with: bom) ? utf8 : bom + utf8
        try payload.write(to: url, options: .atomic)
    }

    private static func encoding(_ cf: CFStringEncodings) -> String.Encoding? {
        let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
        if ns == kCFStringEncodingInvalidId { return nil }
        return String.Encoding(rawValue: ns)
    }

    private static func stripUTF8BOM(_ data: Data) -> Data {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return Data(data.dropFirst(3))
        }
        return data
    }

    /// Higher is better. Favors CJK + SRT structure, penalizes replacement / control junk.
    private static func scoreDecodedText(_ text: String) -> Int {
        var score = 0
        var cjk = 0
        var replacement = 0
        var weird = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0xF900...0xFAFF).contains(v) {
                cjk += 1
            } else if v == 0xFFFD {
                replacement += 1
            } else if v < 0x20 && v != 0x0A && v != 0x0D && v != 0x09 {
                weird += 1
            } else if (0x80...0x9F).contains(v) {
                weird += 1
            }
        }
        score += min(cjk * 3, 600)
        score -= replacement * 8
        score -= weird * 3
        if text.contains("-->") { score += 20 }
        if text.contains("[Script Info]") || text.contains("Dialogue:") { score += 20 }
        // Prefer encodings that produce readable length without runaway NUL padding.
        if text.contains("\0") { score -= 50 }
        return score
    }
}
