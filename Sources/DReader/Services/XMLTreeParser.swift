import Foundation

/// A lightweight XML Node for traversing EPUB manifest, spine, and navigation
final class XMLNode: @unchecked Sendable {
    let name: String
    var attributes: [String: String] = [:]
    var text: String = ""
    var children: [XMLNode] = []
    weak var parent: XMLNode?

    init(name: String, attributes: [String: String] = [:], parent: XMLNode? = nil) {
        self.name = name
        self.attributes = attributes
        self.parent = parent
    }

    func child(named name: String) -> XMLNode? {
        children.first { $0.name.lowercased() == name.lowercased() }
    }

    func allChildren(named name: String) -> [XMLNode] {
        children.filter { $0.name.lowercased() == name.lowercased() }
    }

    func descendant(named name: String) -> XMLNode? {
        if self.name.lowercased() == name.lowercased() { return self }
        for child in children {
            if let found = child.descendant(named: name) { return found }
        }
        return nil
    }

    func allDescendants(named name: String) -> [XMLNode] {
        var results: [XMLNode] = []
        if self.name.lowercased() == name.lowercased() {
            results.append(self)
        }
        for child in children {
            results.append(contentsOf: child.allDescendants(named: name))
        }
        return results
    }
}

/// Parses XML data into an XMLNode tree using Foundation's XMLParser with entity and encoding resilience
final class XMLTreeParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var rootNode: XMLNode?
    private var currentNode: XMLNode?

    static func parse(data: Data) -> XMLNode? {
        // 1. Direct parse attempt
        if let node = attemptParse(data: data) {
            return node
        }

        // 2. Fallback: sanitize entities and encodings
        let encodings: [String.Encoding] = [
            .utf8,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            .isoLatin1,
            .windowsCP1252
        ]

        for encoding in encodings {
            if let str = String(data: data, encoding: encoding) {
                let sanitized = sanitizeXMLEntities(str)
                if let sanitizedData = sanitized.data(using: .utf8),
                   let node = attemptParse(data: sanitizedData) {
                    return node
                }
            }
        }

        return nil
    }

    private static func attemptParse(data: Data) -> XMLNode? {
        let parser = XMLParser(data: data)
        let treeParser = XMLTreeParser()
        parser.delegate = treeParser
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        if parser.parse() {
            return treeParser.rootNode
        }
        return nil
    }

    /// Replaces common HTML/OPF entities with standard XML numeric references and escapes raw ampersands
    private static func sanitizeXMLEntities(_ xmlString: String) -> String {
        var s = xmlString

        let entityMap: [(String, String)] = [
            ("&nbsp;", "&#160;"),
            ("&mdash;", "&#8212;"),
            ("&ndash;", "&#8211;"),
            ("&ldquo;", "&#8220;"),
            ("&rdquo;", "&#8221;"),
            ("&lsquo;", "&#8216;"),
            ("&rsquo;", "&#8217;"),
            ("&hellip;", "&#8230;"),
            ("&copy;", "&#169;"),
            ("&reg;", "&#174;"),
            ("&trade;", "&#8482;"),
            ("&bull;", "&#8226;"),
            ("&prime;", "&#8242;"),
            ("&Prime;", "&#8243;"),
            ("&laquo;", "&#171;"),
            ("&raquo;", "&#187;"),
            ("&cent;", "&#162;"),
            ("&pound;", "&#163;"),
            ("&yen;", "&#165;"),
            ("&euro;", "&#8364;"),
            ("&sect;", "&#167;"),
            ("&para;", "&#182;"),
            ("&deg;", "&#176;"),
            ("&plusmn;", "&#177;"),
            ("&times;", "&#215;"),
            ("&divide;", "&#247;")
        ]

        for (named, numeric) in entityMap {
            s = s.replacingOccurrences(of: named, with: numeric)
        }

        // Replace raw unescaped '&' that is not part of a valid XML entity (&...;)
        let pattern = "&(?!(?:amp|lt|gt|quot|apos|#\\d+|#[xX][0-9a-fA-F]+);)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "&amp;")
        }

        return s
    }

    static func parse(string: String) -> XMLNode? {
        if let data = string.data(using: .utf8) {
            return parse(data: data)
        }
        return nil
    }

    // MARK: - XMLParserDelegate
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        // Strip namespace prefix if any (e.g. dc:title -> title)
        let cleanName = elementName.components(separatedBy: ":").last ?? elementName
        let node = XMLNode(name: cleanName, attributes: attributeDict, parent: currentNode)

        if let current = currentNode {
            current.children.append(node)
        } else {
            rootNode = node
        }
        currentNode = node
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentNode?.text.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        currentNode?.text = currentNode?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentNode = currentNode?.parent
    }
}
