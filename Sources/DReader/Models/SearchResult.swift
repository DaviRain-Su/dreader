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

/// Fast HTML tag stripper for in-memory plain text full-text indexation
func stripHTMLTags(from html: String) -> String {
    // 1. Remove style and script tags and their contents
    var sanitized = html.replacingOccurrences(
        of: "(?s)<(script|style)[^>]*>.*?</\\1>",
        with: " ",
        options: .regularExpression
    )
    // 2. Remove all HTML tags
    sanitized = sanitized.replacingOccurrences(
        of: "<[^>]+>",
        with: " ",
        options: .regularExpression
    )
    // 3. Decode standard XML/HTML entities
    sanitized = sanitized
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&mdash;", with: "—")
        .replacingOccurrences(of: "&ldquo;", with: "“")
        .replacingOccurrences(of: "&rdquo;", with: "”")
        .replacingOccurrences(of: "&lsquo;", with: "‘")
        .replacingOccurrences(of: "&rsquo;", with: "’")

    // 4. Normalize multiple whitespaces
    return sanitized.replacingOccurrences(
        of: "\\s+",
        with: " ",
        options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}
