import Foundation

/// The `iXML` chunk. The raw bytes are kept exactly as read; nothing re-serialises them.
public struct IXML: Sendable, Equatable {
    /// The chunk payload exactly as stored in the file.
    public let rawBytes: [UInt8]

    /// Wraps an existing payload.
    public init(rawBytes: [UInt8]) {
        self.rawBytes = rawBytes
    }

    /// Builds a payload from XML text: UTF-8, padded with one space to an even byte count
    /// as the iXML specification asks. The text itself is stored unchanged.
    public init(xmlText: String) {
        var bytes = Array(xmlText.utf8)
        if bytes.count % 2 == 1 {
            bytes.append(0x20)
        }
        rawBytes = bytes
    }

    /// The XML text: the payload decoded as UTF-8 with trailing spaces and NUL bytes removed,
    /// as the Python reference does. `nil` when the payload is not valid UTF-8.
    public var text: String? {
        guard let decoded = String(data: Data(rawBytes), encoding: .utf8) else { return nil }
        var scalars = Array(decoded.unicodeScalars)
        while let last = scalars.last, last == " " || last == "\u{0}" {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Flattens the document into `PATH/TAG[n]` keys with the same rules as the reference's
    /// `flatten_ixml`: repeated siblings get a 1-based index, attributes become `@name`,
    /// text of an element that also has children becomes `#text`, leaf text is stripped.
    public func flattened() throws -> [String: String] {
        guard let text else { throw WaveError.invalidUTF8("iXML chunk") }
        let root = try XMLTree.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var out: [String: String] = [:]
        var budget = WaveLimits.maxFlattenedXMLBytes
        for (name, value) in root.attributes.sorted(by: { $0.key < $1.key }) {
            try XMLTree.emit("@\(name)", value, into: &out, budget: &budget)
        }
        try XMLTree.walk(root, prefix: "", depth: 0, into: &out, budget: &budget)
        return out
    }
}

/// A minimal element tree built with `XMLParser`, holding what ElementTree exposes:
/// tag, attributes, the text before the first child, and the children.
final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

enum XMLTree {
    static func parse(_ text: String) throws -> XMLNode {
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let builder = TreeBuilder()
        parser.delegate = builder
        let ok = parser.parse()
        if builder.depthExceeded {
            throw WaveError.sizeLimitExceeded("iXML nesting deeper than \(WaveLimits.maxXMLDepth) levels")
        }
        if builder.elementsExceeded {
            throw WaveError.sizeLimitExceeded("iXML with more than \(WaveLimits.maxXMLElements) elements")
        }
        guard ok, let root = builder.root else {
            let reason = parser.parserError.map { $0.localizedDescription } ?? "no root element"
            throw WaveError.malformedXML(reason)
        }
        return root
    }

    /// Stores one flattened key, charging its bytes against the output budget, so a small
    /// document with long names or many elements cannot produce gigabytes of keys.
    static func emit(_ key: String, _ value: String, into out: inout [String: String], budget: inout Int) throws {
        budget -= key.utf8.count + value.utf8.count
        guard budget >= 0 else {
            throw WaveError.sizeLimitExceeded("flattened iXML larger than \(WaveLimits.maxFlattenedXMLBytes) bytes")
        }
        out[key] = value
    }

    static func walk(
        _ element: XMLNode, prefix: String, depth: Int, into out: inout [String: String], budget: inout Int
    ) throws {
        guard depth < WaveLimits.maxXMLDepth else {
            throw WaveError.sizeLimitExceeded("iXML nesting deeper than \(WaveLimits.maxXMLDepth) levels")
        }
        var totals: [String: Int] = [:]
        for child in element.children {
            totals[child.name, default: 0] += 1
        }
        var counts: [String: Int] = [:]
        for child in element.children {
            counts[child.name, default: 0] += 1
            let n = counts[child.name] ?? 1
            var key = prefix + child.name
            if n > 1 || (totals[child.name] ?? 0) > 1 {
                key += "[\(n)]"
            }
            for (name, value) in child.attributes.sorted(by: { $0.key < $1.key }) {
                try emit("\(key)@\(name)", value, into: &out, budget: &budget)
            }
            let stripped = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if child.children.isEmpty {
                try emit(key, stripped, into: &out, budget: &budget)
            } else {
                if !stripped.isEmpty {
                    try emit("\(key)#text", stripped, into: &out, budget: &budget)
                }
                try walk(child, prefix: key + "/", depth: depth + 1, into: &out, budget: &budget)
            }
        }
    }
}

/// Collects elements from `XMLParser` callbacks. Used synchronously on one thread.
final class TreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: XMLNode?
    private var stack: [XMLNode] = []
    private(set) var depthExceeded = false
    private(set) var elementsExceeded = false
    private var elementCount = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard stack.count < WaveLimits.maxXMLDepth else {
            depthExceeded = true
            parser.abortParsing()
            return
        }
        elementCount += 1
        guard elementCount <= WaveLimits.maxXMLElements else {
            elementsExceeded = true
            parser.abortParsing()
            return
        }
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // ElementTree's `text` is the character data before the first child element.
        if let current = stack.last, current.children.isEmpty {
            current.text += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let current = stack.last, current.children.isEmpty,
           let string = String(data: CDATABlock, encoding: .utf8) {
            current.text += string
        }
    }
}
