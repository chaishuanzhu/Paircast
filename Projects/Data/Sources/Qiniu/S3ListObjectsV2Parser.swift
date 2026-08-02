import Foundation

/// ListObjectsV2 page result.
public struct S3ListObjectsV2Page: Equatable, Sendable {
    public var keys: [String]
    public var isTruncated: Bool
    public var nextContinuationToken: String?

    public init(keys: [String], isTruncated: Bool, nextContinuationToken: String? = nil) {
        self.keys = keys
        self.isTruncated = isTruncated
        self.nextContinuationToken = nextContinuationToken
    }
}

/// Minimal ListObjectsV2 XML parser (`Contents/Key`, truncation, continuation).
public enum S3ListObjectsV2Parser {
    public static func parseObjectKeys(from xmlData: Data) throws -> [String] {
        try parsePage(from: xmlData).keys
    }

    public static func parsePage(from xmlData: Data) throws -> S3ListObjectsV2Page {
        let collector = ListCollector()
        let xmlParser = XMLParser(data: xmlData)
        xmlParser.delegate = collector
        guard xmlParser.parse() else {
            throw ParseError.invalidXML
        }
        if let error = collector.error {
            throw error
        }
        return S3ListObjectsV2Page(
            keys: collector.keys,
            isTruncated: collector.isTruncated,
            nextContinuationToken: collector.nextContinuationToken
        )
    }

    public enum ParseError: Error, Equatable {
        case invalidXML
        case errorResponse(code: String, message: String)
    }
}

private final class ListCollector: NSObject, XMLParserDelegate {
    private(set) var keys: [String] = []
    private(set) var isTruncated = false
    private(set) var nextContinuationToken: String?
    private(set) var error: S3ListObjectsV2Parser.ParseError?

    private var textBuffer = ""
    private var insideContents = false
    private var insideError = false
    private var errorCode = ""
    private var errorMessage = ""

    private func localName(_ elementName: String) -> String {
        if let idx = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: idx)...])
        }
        return elementName
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        textBuffer = ""
        switch localName(elementName) {
        case "Contents":
            insideContents = true
        case "Error":
            insideError = true
        default:
            break
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
        let name = localName(elementName)
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { textBuffer = "" }

        if insideError {
            switch name {
            case "Code":
                errorCode = text
            case "Message":
                errorMessage = text
            case "Error":
                error = .errorResponse(code: errorCode, message: errorMessage)
                insideError = false
            default:
                break
            }
            return
        }

        switch name {
        case "Key" where insideContents && !text.isEmpty:
            keys.append(text)
        case "Contents":
            insideContents = false
        case "IsTruncated":
            isTruncated = text.lowercased() == "true" || text == "1"
        case "NextContinuationToken" where !text.isEmpty:
            nextContinuationToken = text
        default:
            break
        }
    }
}
