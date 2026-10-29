import Foundation

/// Represents a single search match across an EPUB book
struct SearchResultItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let chapterIndex: Int
    let chapterTitle: String
    let snippetBefore: String
    let keyword: String
    let snippetAfter: String
    let matchIndexInChapter: Int

    var fullSnippet: String {
        "...\(snippetBefore)[\(keyword)]\(snippetAfter)..."
    }

    init(
        id: UUID = UUID(),
        chapterIndex: Int,
        chapterTitle: String,
        snippetBefore: String,
        keyword: String,
        snippetAfter: String,
        matchIndexInChapter: Int
    ) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.snippetBefore = snippetBefore
        self.keyword = keyword
        self.snippetAfter = snippetAfter
        self.matchIndexInChapter = matchIndexInChapter
    }
}

/// 搜索使用的正文文本：保留 inline 标签两侧的原字距，在块边界规范化空白。
func stripHTMLTags(from html: String) -> String {
    var sanitized = html.replacingOccurrences(
        of: "(?is)<(script|style|noscript)\\b[^>]*>.*?</\\1>",
        with: " ",
        options: .regularExpression
    )
    sanitized = sanitized.replacingOccurrences(
        of: "(?is)<(rt|rp)\\b[^>]*>.*?</\\1>",
        with: "",
        options: .regularExpression
    )
    sanitized = sanitized.replacingOccurrences(
        of: "(?i)</?(?:p|div|h[1-6]|li|dt|dd|td|th|tr|table|ul|ol|dl|blockquote|pre|aside|section|article|nav|figure|figcaption|br)\\b[^>]*>",
        with: " ",
        options: .regularExpression
    )
    sanitized = sanitized.replacingOccurrences(
        of: "<[^>]+>", with: "", options: .regularExpression
    )
    return decodeHTMLEntities(in: sanitized).replacingOccurrences(
        of: "\\s+", with: " ", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeHTMLEntities(in text: String) -> String {
    guard text.contains("&"),
          let regex = try? NSRegularExpression(pattern: "&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);") else { return text }
    let named = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "mdash": "—", "ndash": "–", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "hellip": "…", "laquo": "«", "raquo": "»",
        "copy": "©", "reg": "®", "deg": "°", "plusmn": "±", "times": "×",
        "divide": "÷", "frac12": "½", "shy": ""
    ]
    let ns = text as NSString
    var result = text
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
        let entity = ns.substring(with: match.range)
        let body = String(entity.dropFirst().dropLast())
        let replacement: String?
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
        } else if body.hasPrefix("#") {
            replacement = UInt32(body.dropFirst(), radix: 10).flatMap(UnicodeScalar.init).map(String.init)
        } else {
            replacement = named[body]
        }
        guard let replacement else { continue }
        result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
    }
    return result
}
