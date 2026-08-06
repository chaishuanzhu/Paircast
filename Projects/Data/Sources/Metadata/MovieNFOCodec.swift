import Foundation
import Domain

/// Minimal Kodi-compatible movie NFO (title / year / plot + local art filenames).
enum MovieNFOCodec {
    struct Payload: Equatable {
        var title: String
        var year: String?
        var overview: String?
        var posterFileName: String?
        var fanartFileName: String?
    }

    static func encode(_ payload: Payload) -> Data {
        func esc(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }

        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            "<movie>",
            "  <title>\(esc(payload.title))</title>",
        ]
        if let year = payload.year, !year.isEmpty {
            lines.append("  <year>\(esc(year))</year>")
        }
        if let overview = payload.overview, !overview.isEmpty {
            lines.append("  <plot>\(esc(overview))</plot>")
        }
        if let poster = payload.posterFileName, !poster.isEmpty {
            lines.append("  <thumb aspect=\"poster\">\(esc(poster))</thumb>")
        }
        if let fanart = payload.fanartFileName, !fanart.isEmpty {
            lines.append("  <fanart>")
            lines.append("    <thumb>\(esc(fanart))</thumb>")
            lines.append("  </fanart>")
        }
        lines.append("</movie>")
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func decode(_ data: Data) -> Payload? {
        let collector = NFOCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), let title = collector.title, !title.isEmpty else { return nil }
        return Payload(
            title: title,
            year: collector.year,
            overview: collector.plot,
            posterFileName: collector.posterFileName,
            fanartFileName: collector.fanartFileName
        )
    }
}

private final class NFOCollector: NSObject, XMLParserDelegate {
    var title: String?
    var year: String?
    var plot: String?
    var posterFileName: String?
    var fanartFileName: String?

    private var currentElement: String?
    private var textBuffer = ""
    private var insideFanart = false
    private var thumbAspect: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        textBuffer = ""
        if currentElement == "fanart" {
            insideFanart = true
        }
        if currentElement == "thumb" {
            thumbAspect = attributeDict["aspect"]?.lowercased()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let text = textBuffer
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title":
            if !text.isEmpty { title = text }
        case "year":
            if !text.isEmpty { year = text }
        case "plot":
            if !text.isEmpty { plot = text }
        case "thumb":
            if !text.isEmpty {
                if insideFanart {
                    if fanartFileName == nil { fanartFileName = text }
                } else if thumbAspect == "poster" || thumbAspect == nil {
                    if posterFileName == nil { posterFileName = text }
                }
            }
            thumbAspect = nil
        case "fanart":
            insideFanart = false
        default:
            break
        }
        currentElement = nil
        textBuffer = ""
    }
}
