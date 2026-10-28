import Foundation

/// Whole-book paragraph index enabling the AI companion to actually read the book.
/// Builds a per-book in-memory index of sanitized paragraphs and serves
/// keyword retrieval (CJK bigram scoring, zero dependencies) for question answering.
final class BookIndexService: @unchecked Sendable {
    static let shared = BookIndexService()

    struct IndexedParagraph: Sendable {
        let chapterIndex: Int
        let chapterTitle: String
        let paragraphIndex: Int
        let text: String
    }

    private struct BookIndex {
        var paragraphs: [IndexedParagraph] = []
        var bigramTable: [String: [Int]] = [:] // bigram -> paragraph offsets into `paragraphs`
    }

    private var indexes: [UUID: BookIndex] = [:]
    private var buildingBookIds: Set<UUID> = []
    private let lock = NSLock()

    private init() {}

    // MARK: - Index Building

    /// Builds (or rebuilds) the index for a book. Cheap to call repeatedly:
    /// skips when a fresh index already exists or a build is already running.
    func ensureIndexBuilt(for book: EPUBBook, htmlProvider: @escaping @Sendable (URL) -> String?) {
        let bookId = book.id
        lock.lock()
        if indexes[bookId] != nil || buildingBookIds.contains(bookId) {
            lock.unlock()
            return
        }
        buildingBookIds.insert(bookId)
        lock.unlock()

        let chapters = book.chapters
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var index = BookIndex()
            for (ci, chapter) in chapters.enumerated() {
                let raw = htmlProvider(chapter.fileURL)
                    ?? (try? String(contentsOf: chapter.fileURL, encoding: .utf8))
                    ?? (try? String(contentsOf: chapter.fileURL, encoding: .isoLatin1))
                    ?? ""
                guard !raw.isEmpty else { continue }

                // Mirror the render pipeline exactly (extract body -> sanitize) so that
                // paragraph indices here match data-dreader-para tags in the WebView DOM.
                let resolved = raw
                let body = EPUBThemeInjector.extractBodyContent(from: resolved)
                let sanitized = EPUBThemeInjector.sanitizeAndElevateLayout(body)

                for paragraph in EPUBThemeExtractor.extractParagraphs(from: sanitized) {
                    guard paragraph.text.count >= 4 else { continue }
                    let offset = index.paragraphs.count
                    index.paragraphs.append(IndexedParagraph(
                        chapterIndex: ci,
                        chapterTitle: chapter.title,
                        paragraphIndex: paragraph.index,
                        text: paragraph.text
                    ))
                    for gram in Self.bigrams(in: paragraph.text) {
                        index.bigramTable[gram, default: []].append(offset)
                    }
                }
            }

            guard let self else { return }
            self.lock.lock()
            self.indexes[bookId] = index
            self.buildingBookIds.remove(bookId)
            self.lock.unlock()
            NSLog("DReader BookIndex: built index for \(book.title) — \(index.paragraphs.count) paragraphs")
        }
    }

    func invalidateIndex(for bookId: UUID) {
        lock.lock()
        indexes[bookId] = nil
        lock.unlock()
    }

    func isIndexReady(for bookId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexes[bookId] != nil
    }

    // MARK: - Retrieval

    /// 懒构建入口：AI 伴读检索时若索引未就绪，先异步建一次（下次提问即可用）。
    /// 开书时不再全量建索引——大合订本全书段落 bigram 会占数百 MB。
    func ensureIndexLazily(for book: EPUBBook, htmlProvider: @escaping @Sendable (URL) -> String?) {
        ensureIndexBuilt(for: book, htmlProvider: htmlProvider)
    }

    /// Retrieves the most relevant whole-book paragraphs for a question,
    /// preferring passages outside the current chapter (which is provided in full anyway).
    func retrieve(question: String, bookId: UUID, currentChapterIndex: Int, topK: Int = 6) -> [IndexedParagraph] {
        lock.lock()
        defer { lock.unlock() }
        guard let index = indexes[bookId], !index.paragraphs.isEmpty else { return [] }

        let queryGrams = Self.bigrams(in: question)
        guard !queryGrams.isEmpty else { return [] }

        var scores: [Int: Double] = [:]
        for gram in queryGrams {
            guard let candidates = index.bigramTable[gram] else { continue }
            for offset in candidates {
                scores[offset, default: 0] += 1.0
            }
        }
        guard !scores.isEmpty else { return [] }

        // Slight boost for full-query substring hits and longer passages
        let fullQuery = question.replacingOccurrences(of: " ", with: "")
        var ranked = scores.map { (offset, score) -> (Int, Double) in
            var s = score / Double(queryGrams.count)
            let text = index.paragraphs[offset].text
            if !fullQuery.isEmpty, text.contains(fullQuery) { s += 0.5 }
            return (offset, s)
        }
        ranked.sort { $0.1 > $1.1 }

        // Prefer other chapters (current chapter context is injected in full), keep best per chapter spread
        var other: [Int] = []
        var current: [Int] = []
        for (offset, _) in ranked.prefix(40) {
            if index.paragraphs[offset].chapterIndex == currentChapterIndex {
                current.append(offset)
            } else {
                other.append(offset)
            }
        }
        let picked = (other + current).prefix(topK)
        return picked.compactMap { $0 < index.paragraphs.count ? index.paragraphs[$0] : nil }
    }

    // MARK: - CJK Bigram Tokenization

    static func bigrams(in text: String) -> Set<String> {
        var grams: Set<String> = []
        let scalars = Array(text.lowercased())
        var latinBuffer = ""

        func flushLatin() {
            let word = latinBuffer.trimmingCharacters(in: .alphanumerics.inverted)
            if word.count >= 3 { grams.insert(word) }
            latinBuffer = ""
        }

        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if ch.isCJK {
                if i + 1 < scalars.count, scalars[i + 1].isCJK {
                    grams.insert(String(ch) + String(scalars[i + 1]))
                }
                i += 1
            } else if ch.isLetter || ch.isNumber {
                latinBuffer.append(ch)
                i += 1
            } else {
                flushLatin()
                i += 1
            }
        }
        flushLatin()
        return grams
    }
}

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
            return true
        default:
            return false
        }
    }
}

/// Extracts paragraphs from processed (sanitized) chapter bodies so that indices
/// stay in lockstep with the `data-dreader-para` tags injected into the DOM.
enum EPUBThemeExtractor {
    static func extractParagraphs(from sanitizedBody: String) -> [(index: Int, text: String)] {
        let pattern = "(?i)<p\\b[^>]*>([\\s\\S]*?)</p>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = sanitizedBody as NSString
        let matches = regex.matches(in: sanitizedBody, options: [], range: NSRange(location: 0, length: ns.length))

        var results: [(index: Int, text: String)] = []
        for (idx, m) in matches.enumerated() {
            guard m.numberOfRanges >= 2 else { continue }
            let inner = ns.substring(with: m.range(at: 1))
            let plain = inner
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard plain.count >= 4 else { continue }
            results.append((index: idx, text: plain))
        }
        return results
    }
}
