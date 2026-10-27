import Foundation

/// 跨书全文搜索的一个命中（带书籍定位信息）
struct CrossBookSearchItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let bookId: UUID
    let bookTitle: String
    let chapterIndex: Int
    let chapterTitle: String
    let snippetBefore: String
    let keyword: String
    let snippetAfter: String

    var fullSnippet: String { "...\(snippetBefore)\(keyword)\(snippetAfter)..." }
}

/// 按书分组的结果（UI 依书折叠展示）
struct CrossBookSearchGroup: Identifiable, Sendable {
    let bookId: UUID
    let bookTitle: String
    let items: [CrossBookSearchItem]

    var id: UUID { bookId }
    var totalCount: Int { items.count }
}

/// 全书库段落级全文搜索：
/// 把书架每本书每章抽成纯文本并繁→简归一化（简体关键词也能命中繁体书），
/// 内存里 LRU 缓存最近用过的书，重复搜索毫秒级返回。
final class CrossBookSearchService: @unchecked Sendable {
    static let shared = CrossBookSearchService()

    private let cacheQueue = DispatchQueue(label: "com.dreader.crossbooksearch")
    /// bookId → [chapterIndex: 简体归一化后的纯文本]
    private var textualCache: [UUID: [Int: String]] = [:]
    private var accessOrder: [UUID] = []
    private let maxCachedBooks = 8

    // MARK: - Search

    /// 纯计算同步方法，调用方应放在后台 Task 里
    func searchOnce(
        query rawQuery: String,
        across books: [EPUBBook],
        maxMatchesPerBook: Int = 80,
        maxTotalMatches: Int = 500
    ) -> [CrossBookSearchGroup] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = ChineseScriptConverter.toSimplified(trimmed)

        var groups: [CrossBookSearchGroup] = []
        var totalMatches = 0

        for book in books {
            guard book.chapters.indices.contains(book.chapters.startIndex) else { continue }
            guard totalMatches < maxTotalMatches else { break }

            let texts = ensureTexts(for: book)
            var items: [CrossBookSearchItem] = []
            var capped = false

            for (chIdx, ch) in book.chapters.enumerated() {
                guard let plain = texts[chIdx] else { continue }
                var searchStart = plain.startIndex
                var found = true
                while found {
                    guard let hit = plain.range(of: needle, options: [.caseInsensitive], range: searchStart..<plain.endIndex) else {
                        found = false
                        break
                    }
                    let beforeStart = plain.index(hit.lowerBound, offsetBy: -30, limitedBy: plain.startIndex) ?? plain.startIndex
                    let afterEnd = plain.index(hit.upperBound, offsetBy: 34, limitedBy: plain.endIndex) ?? plain.endIndex

                    items.append(
                        CrossBookSearchItem(
                            id: UUID(),
                            bookId: book.id,
                            bookTitle: book.title,
                            chapterIndex: chIdx,
                            chapterTitle: ch.title,
                            snippetBefore: String(plain[beforeStart..<hit.lowerBound]).trimmingCharacters(in: .whitespaces),
                            keyword: String(plain[hit.lowerBound..<hit.upperBound]),
                            snippetAfter: String(plain[hit.upperBound..<afterEnd]).trimmingCharacters(in: .whitespaces)
                        )
                    )

                    if items.count >= maxMatchesPerBook {
                        capped = true
                        break
                    }
                    searchStart = hit.upperBound
                }
                if capped { break }
            }

            if !items.isEmpty {
                totalMatches += items.count
                groups.append(CrossBookSearchGroup(bookId: book.id, bookTitle: book.title, items: items))
            }
        }
        return groups
    }

    // MARK: - Text Cache (LRU)

    private func ensureTexts(for book: EPUBBook) -> [Int: String] {
        if let cached = touch(book.id) { return cached }

        var map: [Int: String] = [:]
        for (idx, ch) in book.chapters.enumerated() {
            guard let html = try? String(contentsOf: ch.fileURL, encoding: .utf8) else { continue }
            map[idx] = ChineseScriptConverter.toSimplified(stripHTMLTags(from: html))
        }
        cacheQueue.sync {
            textualCache[book.id] = map
            accessOrder.removeAll { $0 == book.id }
            accessOrder.append(book.id)
            if accessOrder.count > maxCachedBooks {
                let evict = accessOrder.prefix(accessOrder.count - maxCachedBooks)
                for id in evict { textualCache[id] = nil }
                accessOrder.removeFirst(accessOrder.count - maxCachedBooks)
            }
        }
        return map
    }

    /// 命中时刷新 LRU 次序
    private func touch(_ bookId: UUID) -> [Int: String]? {
        cacheQueue.sync {
            guard let cached = textualCache[bookId] else { return nil }
            accessOrder.removeAll { $0 == bookId }
            accessOrder.append(bookId)
            return cached
        }
    }
}
