import Foundation

/// 每章划线数（用于复盘分布条）
struct FinishChapterCount: Equatable {
    let title: String
    let count: Int
}

/// 读完复盘快照：本书全部沉淀数据的一次性聚合（纯值类型，弹窗直接渲染）。
/// 数据源全部现成：LibraryDatabase（划线/想法/生词/书签）+ ReadingStatsManager（时长）。
struct FinishSnapshot: Identifiable, Equatable {
    let id: UUID
    let bookTitle: String
    let author: String
    let chapterCount: Int
    /// 本书划线（不含生词）
    let highlights: [Highlight]
    /// 带想法的划线（note 非空）
    let thoughtHighlights: [Highlight]
    /// 本书生词数
    let vocabularyCount: Int
    /// 本书书签数
    let bookmarkCount: Int
    /// 每章划线分布（章节名 → 数量），取最多前 5 章
    let topChapters: [FinishChapterCount]
    /// 最早与最晚一条印记的时间跨度（天）；无印记为 nil
    let spanDays: Int?
    let finishedAt: Date

    var highlightCount: Int { highlights.count }
    var thoughtCount: Int { thoughtHighlights.count }

    /// 主打引文：最长的想法（无则最长的划线）；复盘卡的灵魂
    var featuredQuote: Highlight? {
        let pool = thoughtHighlights.isEmpty ? highlights : thoughtHighlights
        return pool.max { $0.text.count < $1.text.count }
    }

    static func build(book: EPUBBook) -> FinishSnapshot? {
        let db = LibraryDatabase.shared
        let all = db.loadHighlights()
        let mine = all.filter { $0.bookTitle == book.title || $0.bookId == book.id }
        let bookmarks = db.loadBookmarks().filter { $0.bookTitle == book.title || $0.bookId == book.id }
        let thoughts = mine.filter { ($0.note ?? "").isEmpty == false }
        let vocab = mine.filter { $0.source == "vocabulary" }
        let marks = mine.filter { $0.source != "vocabulary" }

        // 每章划线分布（生词不算章节印记）
        var chapterCounts: [String: Int] = [:]
        for h in marks where !h.chapterTitle.isEmpty {
            chapterCounts[h.chapterTitle, default: 0] += 1
        }
        let top = chapterCounts.sorted { $0.value > $1.value }.prefix(5).map { FinishChapterCount(title: $0.key, count: $0.value) }

        var span: Int? = nil
        if let first = marks.map(\.createdAt).min(), let last = marks.map(\.createdAt).max() {
            let days = Int(last.timeIntervalSince(first) / 86_400)
            span = max(0, days)
        }

        return FinishSnapshot(
            id: UUID(),
            bookTitle: book.title,
            author: book.author,
            chapterCount: book.chapters.count,
            highlights: marks,
            thoughtHighlights: thoughts,
            vocabularyCount: vocab.count,
            bookmarkCount: bookmarks.count,
            topChapters: top,
            spanDays: span,
            finishedAt: Date()
        )
    }
}
