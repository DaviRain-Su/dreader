import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// 前情回顾邀请：隔了多天重新翻开一本有阅读印记的书时，阅读区浮现的可关闭小条
struct RecapHint: Equatable, Identifiable {
    let bookTitle: String
    let lastChapterIndex: Int
    let lastChapterTitle: String
    let daysAway: Int
    var id: String { "\(bookTitle)-\(lastChapterIndex)" }
}

@Observable
final class ReaderViewModel: @unchecked Sendable {
    var books: [EPUBBook] = []
    var currentBook: EPUBBook?
    var highlights: [Highlight] = []
    var settings = ReaderSettings()
    var selectionManager = ReaderSelectionManager()
    var agentService = AIAgentService()

    var isViewingBookshelf: Bool = true // Default to showing Bookshelf on launch
    var sidebarTab: SidebarTab = .toc
    var isSidebarVisible: Bool = false
    var isAIPanelVisible: Bool = false
    var showReadingInsights: Bool = false
    var showOnlineBookHub: Bool = false
    var showWeChatSyncModal: Bool = false
    var showGlobalNotebooksModal: Bool = false
    var showReviewSessionModal: Bool = false
    var isLoadingBook: Bool = false
    var errorMessage: String?
    var chapterRenderID: UUID = UUID()
    var pendingRecap: RecapHint? = nil

    /// 前情回顾的延迟浮现任务（换书时取消旧的），以及本会话内已关闭提示的书
    private var recapTask: Task<Void, Never>?
    private var recapDismissedBookTitles: Set<String> = []

    var readingStats: ReadingStats {
        ReadingStatsManager.shared.stats
    }

    init() {
        loadPersistedHighlights()
        loadPersistedBookmarks()
        Task {
            await initializeLibrary()
        }
        // 微信读书云端书架下载完一本书后，重扫本地书架把新书补进来
        NotificationCenter.default.addObserver(
            forName: Notification.Name("DReaderReloadShelf"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadLibraryFromDisk()
            }
        }
    }

    /// 重新扫描持久化书架目录，补入新增 EPUB（按文件名去重）
    @MainActor
    func reloadLibraryFromDisk() {
        for url in Self.persistedLibraryEPUBs() {
            guard !books.contains(where: { url.lastPathComponent == $0.fileURL.lastPathComponent }) else { continue }
            Task {
                if let book = try? await EPUBParser.shared.parse(fileURL: url) {
                    if !books.contains(where: { $0.title == book.title }) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            books.append(book)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Library Initialization
    @MainActor
    func initializeLibrary() async {
        isLoadingBook = true

        // 1. Restore persisted shelf EPUBs (manually imported books are copied here so
        //    they survive app restarts and Caches purges)
        for url in Self.persistedLibraryEPUBs() {
            if let book = try? await EPUBParser.shared.parse(fileURL: url) {
                if books.contains(where: { $0.title == book.title }) { continue }
                books.append(book)
            }
        }

        // 内置 demo 书（Walden/Little_Prince/LuXun）已按用户要求停用：书架只保留真实藏书。
        // SampleBookGenerator 保留在代码库中，需要时手动调用。

        isLoadingBook = false
        // Keep isViewingBookshelf = true so the user starts at the bookshelf!
    }

    /// Canonical shelf directory: Application Support/DReader (legacy samples) + DownloadedBooks/
    static func persistedLibraryEPUBs() -> [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("DReader", isDirectory: true)
        var urls: [URL] = []
        let fm = FileManager.default
        for dir in [base, base.appendingPathComponent("DownloadedBooks")] {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                urls.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "epub" })
            }
        }
        // Order: file modification (newest first) to keep the shelf fresh-feeling on restore
        return urls.sorted { a, b in
            let da = (try? fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
            return da > db
        }
    }

    /// Copies a newly imported EPUB into the persistent shelf dir (idempotent: overwrites by name).
    private func persistShelfCopy(for fileURL: URL) {
        guard fileURL.pathExtension.lowercased() == "epub" else { return }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let shelfDir = appSupport.appendingPathComponent("DReader/DownloadedBooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true)
        let destination = shelfDir.appendingPathComponent(fileURL.lastPathComponent)
        // Same name + already present: skip (parser's bookId is filename-derived, so highlights stay bound)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: fileURL, to: destination)
    }

    func returnToBookshelf() {
        ReadingStatsManager.shared.pauseSession()
        readAloud.stop()
        withAnimation(.easeInOut(duration: 0.25)) {
            isViewingBookshelf = true
            selectionManager.clear()
        }
    }

    func selectBookForReading(_ book: EPUBBook) {
        ReadingStatsManager.shared.startSession()
        withAnimation(.easeInOut(duration: 0.25)) {
            currentBook = book
            isViewingBookshelf = false
            isSidebarVisible = false
            selectionManager.clear()
        }
        scheduleRecapIfAwayLong(for: book)
        // 竖排偏好：已设置按书记忆 → 恢复；未设置 → 古籍默认竖排（仅首开时写入偏好）
        if settings.storedVertical(for: book.id) {
            settings.isVertical = true
        } else if !UserDefaults.standard.bool(forKey: "dreader.vertical.seen.\(book.id.uuidString)") {
            UserDefaults.standard.set(true, forKey: "dreader.vertical.seen.\(book.id.uuidString)")
            if ReaderSettings.looksLikeClassicalChinese(title: book.title, author: book.author) {
                settings.isVertical = true
                var prefs = UserDefaults.standard.string(forKey: "dreader.vertical_by_book").flatMap {
                    $0.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                } ?? [:]
                prefs[book.id.uuidString] = "1"
                if let data = try? JSONEncoder().encode(prefs) {
                    UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "dreader.vertical_by_book")
                }
            }
        }
        updateSubsequentChaptersTotalChars()
        preloadAllChapters(for: book)
    }

    // MARK: - 前情回顾（Kindle Recaps 范式）

    /// 开书后判定是否值得给出前情回顾：本书最近印记 ≥ 3 天前、位置不在第一章，且本会话未关过提示。
    /// 邀请条延迟 1.4s 浮现，避免与开书动效抢注意力。
    private func scheduleRecapIfAwayLong(for book: EPUBBook) {
        recapTask?.cancel()
        pendingRecap = nil
        guard !recapDismissedBookTitles.contains(book.title), book.currentChapterIndex == 0 else { return }
        guard let activity = LibraryDatabase.shared.latestActivity(bookTitle: book.title) else { return }
        let days = max(1, Int(Date().timeIntervalSince(activity.date) / 86_400))
        guard days >= 3, activity.chapterIndex > 0 else { return }
        recapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled, currentBook?.title == book.title else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                pendingRecap = RecapHint(
                    bookTitle: book.title,
                    lastChapterIndex: activity.chapterIndex,
                    lastChapterTitle: activity.chapterTitle,
                    daysAway: days
                )
            }
        }
    }

    func dismissRecap() {
        if let hint = pendingRecap {
            recapDismissedBookTitles.insert(hint.bookTitle)
        }
        withAnimation(.easeOut(duration: 0.2)) {
            pendingRecap = nil
        }
    }

    // MARK: - Open EPUB
    @MainActor
    func openEPUB(url: URL) async {
        isLoadingBook = true
        errorMessage = nil

        do {
            let book = try await EPUBParser.shared.parse(fileURL: url)
            persistShelfCopy(for: url)
            if let existingIndex = books.firstIndex(where: { $0.title == book.title }) {
                books[existingIndex] = book
                selectBookForReading(book)
            } else {
                books.insert(book, at: 0)
                selectBookForReading(book)
            }
            self.isLoadingBook = false
            preloadAllChapters(for: book)
        } catch {
            self.isLoadingBook = false
            let fileName = url.deletingPathExtension().lastPathComponent
            self.errorMessage = "《\(fileName)》导入失败 — \(error.localizedDescription)"
        }
    }

    @discardableResult
    @MainActor
    func importBookToLibrary(url: URL) async -> EPUBBook? {
        do {
            let book = try await EPUBParser.shared.parse(fileURL: url)
            if let existingIndex = books.firstIndex(where: { $0.title == book.title }) {
                books[existingIndex] = book
                preloadAllChapters(for: book)
                return book
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    books.append(book)
                }
                preloadAllChapters(for: book)
                return book
            }
        } catch {
            self.errorMessage = "置入书斋失败: \(error.localizedDescription)"
            return nil
        }
    }

    @MainActor
    func importClassicDirectly(_ classic: ChineseClassicsRegistry.ClassicBook) async {
        do {
            // Remove previous messy Gutenberg version of this classic if already in library
            let oldMatchingIds = books.filter {
                $0.title.contains(classic.title) || classic.title.contains($0.title) || $0.title.contains(classic.traditionalTitle)
            }.map { $0.id }
            for id in oldMatchingIds {
                removeBook(id: id)
            }

            let onlineItem = classic.toOnlineBookItem(source: .gutenberg)
            let localURL = try await OnlineBookService.shared.downloadEPUB(item: onlineItem)
            if let newBook = await importBookToLibrary(url: localURL) {
                if currentBook == nil || oldMatchingIds.contains(where: { $0 == currentBook?.id }) {
                    currentBook = newBook
                }
            }
        } catch {
            self.errorMessage = "置入《\(classic.title)》失败: \(error.localizedDescription)"
        }
    }

    var chapterScrollProgress: Double = 0.0
    var scrollPageAction: ((Int) -> Void)?
    var applyHighlightAction: ((String, String, String?) -> Void)?
    var updateHighlightColorAction: ((String, String) -> Void)?
    var updateHighlightThoughtAction: ((String, String?) -> Void)?
    var removeHighlightAction: ((String) -> Void)?
    var scrollToHighlightAction: ((String) -> Void)?
    var lastChosenHighlightColor: String = "#FFE066"

    // MARK: - Chapter & Page Navigation
    var hasNextChapter: Bool {
        guard let book = currentBook else { return false }
        return book.currentChapterIndex < book.chapters.count - 1
    }

    var hasPrevChapter: Bool {
        guard let book = currentBook else { return false }
        return book.currentChapterIndex > 0
    }

    var nextChapterTitle: String? {
        guard let book = currentBook,
              book.currentChapterIndex < book.chapters.count - 1 else { return nil }
        return book.chapters[book.currentChapterIndex + 1].title
    }

    var overallBookProgress: Double {
        guard let book = currentBook, !book.chapters.isEmpty else { return 0 }
        let chapterFraction = chapterScrollProgress
        let total = (Double(book.currentChapterIndex) + chapterFraction) / Double(book.chapters.count)
        return min(1.0, max(0.0, total))
    }

    // In-memory HTML cache for instant 0ms chapter transitions
    private var htmlContentCache: [URL: String] = [:]

    func getCachedHTML(for url: URL) -> String? {
        htmlContentCache[url]
    }

    func cacheHTML(_ html: String, for url: URL) {
        htmlContentCache[url] = html
    }

    /// Asynchronously preloads all chapters of a book into memory for zero-latency instant transitions
    func preloadAllChapters(for book: EPUBBook) {
        let chapters = book.chapters
        Task.detached(priority: .userInitiated) { [weak self] in
            var preloaded: [URL: String] = [:]
            var counts: [URL: Int] = [:]
            for ch in chapters {
                if let content = try? String(contentsOf: ch.fileURL, encoding: .utf8) {
                    preloaded[ch.fileURL] = content
                    counts[ch.fileURL] = stripHTMLTags(from: content).count
                }
            }
            if let self = self {
                await self.storePreloadedChapters(preloaded, counts: counts)
            }
            // Whole-book AI index piggybacks on the same preload pass
            let preloadedSnapshot = preloaded
            BookIndexService.shared.ensureIndexBuilt(for: book) { url in
                preloadedSnapshot[url]
            }
        }
    }

    @MainActor
    private func storePreloadedChapters(_ preloaded: [URL: String], counts: [URL: Int]) {
        for (url, content) in preloaded {
            self.htmlContentCache[url] = content
        }
        for (url, count) in counts {
            self.chapterCharCountCache[url] = count
        }
        updateSubsequentChaptersTotalChars()
    }

    func scrollPage(direction: Int) {
        if let action = scrollPageAction {
            action(direction)
        } else {
            if direction > 0 {
                nextChapter()
            } else {
                prevChapter()
            }
        }
    }

    func nextChapter() {
        guard var book = currentBook, book.currentChapterIndex < book.chapters.count - 1 else { return }
        readAloud.stop()
        book.currentChapterIndex += 1
        currentBook = book
        updateBookInLibrary(book)
        updateSubsequentChaptersTotalChars()
        chapterScrollProgress = 0.0
        selectionManager.clear()
    }

    func prevChapter() {
        guard var book = currentBook, book.currentChapterIndex > 0 else { return }
        readAloud.stop()
        book.currentChapterIndex -= 1
        currentBook = book
        updateBookInLibrary(book)
        updateSubsequentChaptersTotalChars()
        chapterScrollProgress = 0.0
        selectionManager.clear()
    }

    func jumpToChapter(_ index: Int) {
        guard var book = currentBook, book.chapters.indices.contains(index) else { return }
        if book.currentChapterIndex == index {
            // Smoothly scroll to the beginning of the current chapter
            scrollPageAction?(0)
            return
        }
        readAloud.stop()
        book.currentChapterIndex = index
        currentBook = book
        updateBookInLibrary(book)
        updateSubsequentChaptersTotalChars()
        chapterScrollProgress = 0.0
        selectionManager.clear()
    }

    private func updateBookInLibrary(_ book: EPUBBook) {
        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx] = book
        }
    }

    // MARK: - Highlighting & Thoughts (WeChat Read style)
    // MARK: - Highlighting & Thoughts (WeChat Read style)
    func currentBookHighlights() -> [Highlight] {
        guard let book = currentBook else { return [] }
        return highlights.filter { $0.bookTitle == book.title || $0.bookId == book.id }
    }

    /// Sanitized plain-text of the current chapter for AI context injection.
    func currentChapterBodyText(maxLength: Int = 14000) -> String {
        guard let book = currentBook, let chapter = book.currentChapter else { return "" }
        let raw = getCachedHTML(for: chapter.fileURL)
            ?? (try? String(contentsOf: chapter.fileURL, encoding: .utf8)) ?? ""
        guard !raw.isEmpty else { return "" }
        let body = EPUBThemeInjector.extractBodyContent(from: raw)
        let sanitized = EPUBThemeInjector.sanitizeAndElevateLayout(body)
        let paragraphs = EPUBThemeExtractor.extractParagraphs(from: sanitized).map { $0.text }
        var text = paragraphs.joined(separator: "\n\n")
        if text.count > maxLength {
            text = String(text.prefix(maxLength)) + "\n【…（本章内容过长，已截断展示前半部分，可结合具体段落提问获取后文）】"
        }
        return text
    }

    func currentChapterHighlights() -> [Highlight] {
        guard let book = currentBook else { return [] }
        return highlights.filter {
            ($0.bookTitle == book.title || $0.bookId == book.id) && $0.chapterIndex == book.currentChapterIndex
        }
    }

    func jumpToHighlight(_ highlight: Highlight) {
        guard let book = currentBook else { return }
        if book.currentChapterIndex == highlight.chapterIndex {
            scrollToHighlightAction?(highlight.id.uuidString)
        } else {
            jumpToChapter(highlight.chapterIndex)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.scrollToHighlightAction?(highlight.id.uuidString)
            }
        }
    }

    @discardableResult
    func applyHighlight(colorHex: String, note: String? = nil) -> Highlight? {
        guard let book = currentBook,
              let selection = selectionManager.activeSelection,
              let chapter = book.currentChapter else { return nil }

        lastChosenHighlightColor = colorHex

        let highlight = Highlight(
            bookId: book.id,
            bookTitle: book.title,
            chapterIndex: book.currentChapterIndex,
            chapterTitle: chapter.title,
            text: selection.text,
            colorHex: colorHex,
            createdAt: Date(),
            note: note
        )

        highlights.insert(highlight, at: 0)
        savePersistedHighlights()

        // 1. Instantly apply in active WKWebView DOM without reloading or jumping
        applyHighlightAction?(colorHex, highlight.id.uuidString, note)

        // 2. Clear active selection
        selectionManager.clear()
        return highlight
    }

    func updateHighlight(id: UUID, colorHex: String? = nil, note: String? = nil) {
        if let idx = highlights.firstIndex(where: { $0.id == id }) {
            var h = highlights[idx]
            if let c = colorHex {
                h.colorHex = c
                lastChosenHighlightColor = c
                updateHighlightColorAction?(id.uuidString, c)
            }
            if let n = note {
                let trimmed = n.trimmingCharacters(in: .whitespacesAndNewlines)
                h.note = trimmed.isEmpty ? nil : trimmed
                updateHighlightThoughtAction?(id.uuidString, h.note)
            }
            h.updatedAt = Date()
            highlights[idx] = h
            savePersistedHighlights()
        }
    }

    func deleteHighlight(_ id: UUID) {
        highlights.removeAll { $0.id == id }
        LibraryDatabase.shared.deleteHighlight(id: id)
        LibraryDatabase.shared.deleteReviewSchedule(highlightId: id)
        selectionManager.activeHighlightCard = nil
        removeHighlightAction?(id.uuidString)
    }

    func persistHighlightsDirectly() {
        savePersistedHighlights()
    }

    private func savePersistedHighlights() {
        LibraryDatabase.shared.upsertHighlights(highlights)
        // Legacy UserDefaults copy retired from active use; SQLite (LibraryDatabase) is now
        // the source of truth. The old UserDefaults blob stays as a historical backup.
    }

    private func loadPersistedHighlights() {
        let stored = LibraryDatabase.shared.loadHighlights()
        if !stored.isEmpty {
            self.highlights = stored
        } else if let data = UserDefaults.standard.data(forKey: "dreader.highlights"),
                  let decoded = try? JSONDecoder().decode([Highlight].self, from: data) {
            // Fallback for the rare case migration was skipped (Database handled it internally too)
            self.highlights = decoded
        }
    }

    // MARK: - In-Book Full-Text Search (Apple Books style)
    var isSearchPresented: Bool = false
    var searchQuery: String = ""
    var searchResults: [SearchResultItem] = []
    var currentSearchIndex: Int = 0
    var isSearching: Bool = false
    var scrollToSearchMatchAction: ((String, Int) -> Void)?
    private var searchTask: Task<Void, Never>?

    func performSearch(query: String) {
        searchQuery = query
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let book = currentBook else {
            searchResults = []
            currentSearchIndex = 0
            isSearching = false
            return
        }

        isSearching = true
        let chapters = book.chapters
        let cache = self.htmlContentCache

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms debounce
            if Task.isCancelled { return }

            let results = await Task.detached(priority: .userInitiated) { () -> [SearchResultItem] in
                var items: [SearchResultItem] = []
                let lowerQuery = trimmed.lowercased()

                for (chIdx, ch) in chapters.enumerated() {
                    let html: String
                    if let cached = cache[ch.fileURL] {
                        html = cached
                    } else if let disk = try? String(contentsOf: ch.fileURL, encoding: .utf8) {
                        html = disk
                    } else {
                        continue
                    }

                    let plainText = stripHTMLTags(from: html)
                    let lowerText = plainText.lowercased()
                    var searchStart = lowerText.startIndex
                    var matchIdxInChapter = 0

                    while let range = lowerText.range(of: lowerQuery, range: searchStart..<lowerText.endIndex) {
                        let matchStart = range.lowerBound
                        let matchEnd = range.upperBound

                        let beforeStart = lowerText.index(matchStart, offsetBy: -30, limitedBy: lowerText.startIndex) ?? lowerText.startIndex
                        let afterEnd = lowerText.index(matchEnd, offsetBy: 34, limitedBy: lowerText.endIndex) ?? lowerText.endIndex

                        let beforeStr = String(plainText[beforeStart..<matchStart])
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespaces)

                        let kwStr = String(plainText[matchStart..<matchEnd])

                        let afterStr = String(plainText[matchEnd..<afterEnd])
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespaces)

                        items.append(
                            SearchResultItem(
                                chapterIndex: chIdx,
                                chapterTitle: ch.title,
                                snippetBefore: beforeStr,
                                keyword: kwStr,
                                snippetAfter: afterStr,
                                matchIndexInChapter: matchIdxInChapter
                            )
                        )

                        matchIdxInChapter += 1
                        searchStart = matchEnd
                    }
                }
                return items
            }.value

            if !Task.isCancelled {
                self.searchResults = results
                self.isSearching = false
                self.currentSearchIndex = 0
                if let first = results.first {
                    self.jumpToSearchResult(first)
                }
            }
        }
    }

    func jumpToSearchResult(_ item: SearchResultItem) {
        guard let book = currentBook else { return }
        if let idx = searchResults.firstIndex(where: { $0.id == item.id }) {
            currentSearchIndex = idx
        }

        if book.currentChapterIndex != item.chapterIndex {
            jumpToChapter(item.chapterIndex)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.scrollToSearchMatchAction?(item.keyword, item.matchIndexInChapter)
            }
        } else {
            scrollToSearchMatchAction?(item.keyword, item.matchIndexInChapter)
        }
    }

    // MARK: - AI 伴读笔记落库

    /// 把一条 AI 解读存为书内笔记：挂在当前章，source 标记 ai_companion，
    /// 进入 SQLite 划线库 → iCloud 备份 → MCP 全链路。
    @MainActor
    func saveAIMessageAsNote(_ content: String) {
        guard let book = currentBook, let chapter = book.currentChapter else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = Highlight(
            bookId: book.id,
            bookTitle: book.title,
            chapterIndex: book.currentChapterIndex,
            chapterTitle: chapter.title,
            text: "【AI 伴读解读】\(ChineseScriptConverter.convert(chapter.title, mode: settings.chineseScriptMode))",
            colorHex: "#A5D8FF",
            note: trimmed,
            source: "ai_companion"
        )
        LibraryDatabase.shared.upsertHighlights([note])
        highlights.append(note)
    }

    /// Kindle 生词本闭环：查词动作把词自动收进生词库（source="vocabulary"），
    /// 首次到期复习由 review_schedule 的 NULL 分支自然接管，进入 7/14/28 天队列。
    func saveVocabularyWord(_ raw: String) {
        guard let book = currentBook, let chapter = book.currentChapter else { return }
        if LibraryDatabase.shared.upsertVocabularyWord(
            raw,
            bookId: book.id,
            bookTitle: book.title,
            chapterTitle: chapter.title
        ) != nil {
            // 仅新词才刷新内存列表（去重命中时静默）
            highlights = LibraryDatabase.shared.loadHighlights()
        }
    }

    // MARK: - Cross-Book Library Search (全书库搜索)
    var crossBookGroups: [CrossBookSearchGroup] = []
    var isCrossBookSearching = false
    private var crossBookTask: Task<Void, Never>?

    func performCrossBookSearch(query rawQuery: String) {
        crossBookTask?.cancel()
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            crossBookGroups = []
            isCrossBookSearching = false
            return
        }
        isCrossBookSearching = true

        crossBookTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            if Task.isCancelled { return }
            let library = await MainActor.run { self.books }
            let groups = await Task.detached(priority: .userInitiated) {
                CrossBookSearchService.shared.searchOnce(query: trimmed, across: library)
            }.value
            guard !Task.isCancelled else { return }
            self.crossBookGroups = groups
            self.isCrossBookSearching = false
        }
    }

    /// 从跨书搜索结果打开对应书籍并跳转到该章
    @MainActor
    func openCrossBookResult(_ item: CrossBookSearchItem) {
        if let current = currentBook, current.id == item.bookId {
            jumpToChapter(item.chapterIndex)
            return
        }
        guard let target = books.first(where: { $0.id == item.bookId }) else { return }
        isSearchPresented = false
        Task {
            await openEPUB(url: target.fileURL)
            jumpToChapter(item.chapterIndex)
        }
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        jumpToSearchResult(searchResults[currentSearchIndex])
    }

    func prevSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        jumpToSearchResult(searchResults[currentSearchIndex])
    }

    // MARK: - Dog-Ear Bookmarks (折角书签 ⌘+D)
    var bookmarks: [Bookmark] = []

    func isCurrentChapterBookmarked() -> Bool {
        guard let book = currentBook else { return false }
        return bookmarks.contains { $0.bookId == book.id && $0.chapterIndex == book.currentChapterIndex }
    }

    func toggleCurrentChapterBookmark() {
        guard let book = currentBook, let chapter = book.currentChapter else { return }
        if let idx = bookmarks.firstIndex(where: { $0.bookId == book.id && $0.chapterIndex == book.currentChapterIndex }) {
            bookmarks.remove(at: idx)
        } else {
            let bm = Bookmark(
                bookId: book.id,
                bookTitle: book.title,
                chapterIndex: book.currentChapterIndex,
                chapterTitle: chapter.title,
                scrollProgress: chapterScrollProgress
            )
            bookmarks.insert(bm, at: 0)
        }
        savePersistedBookmarks()
    }

    func deleteBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        savePersistedBookmarks()
    }

    private func savePersistedBookmarks() {
        LibraryDatabase.shared.upsertBookmarks(bookmarks)
    }

    private func loadPersistedBookmarks() {
        let stored = LibraryDatabase.shared.loadBookmarks()
        if !stored.isEmpty {
            self.bookmarks = stored
        } else if let data = UserDefaults.standard.data(forKey: "dreader.bookmarks"),
                  let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            self.bookmarks = decoded
        }
    }

    // MARK: - Reading Time & Speed Estimation
    private let charactersPerMinute: Double = 400.0
    private var chapterCharCountCache: [URL: Int] = [:]
    private var subsequentChaptersTotalChars: Int = 0

    func getOrComputeCharCount(for url: URL) -> Int {
        if let count = chapterCharCountCache[url] {
            return count
        }
        let html = getCachedHTML(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let count = stripHTMLTags(from: html).count
        chapterCharCountCache[url] = count
        return count
    }

    func updateSubsequentChaptersTotalChars() {
        guard let book = currentBook else {
            subsequentChaptersTotalChars = 0
            return
        }
        var total = 0
        let nextIndex = book.currentChapterIndex + 1
        if nextIndex < book.chapters.count {
            for i in nextIndex..<book.chapters.count {
                let url = book.chapters[i].fileURL
                total += getOrComputeCharCount(for: url)
            }
        }
        subsequentChaptersTotalChars = total
    }

    func currentChapterCharCount() -> Int {
        guard let book = currentBook, let chapter = book.currentChapter else { return 0 }
        return getOrComputeCharCount(for: chapter.fileURL)
    }

    func currentChapterRemainingMinutes() -> Int {
        let count = currentChapterCharCount()
        guard count > 0 else { return 1 }
        let remaining = Double(count) * max(0.02, 1.0 - chapterScrollProgress)
        return max(1, Int(ceil(remaining / charactersPerMinute)))
    }

    func bookRemainingTimeFormatted() -> String {
        guard let book = currentBook, !book.chapters.isEmpty else { return "" }
        let currCount = currentChapterCharCount()
        let currentRemaining = Int(Double(currCount) * max(0.02, 1.0 - chapterScrollProgress))
        let totalRemainingChars = currentRemaining + subsequentChaptersTotalChars

        let totalMinutes = max(1, Int(ceil(Double(totalRemainingChars) / charactersPerMinute)))
        if totalMinutes < 60 {
            return "全书剩约 \(totalMinutes) 分钟"
        } else {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            if mins == 0 {
                return "全书剩约 \(hours) 小时"
            } else {
                return "全书剩约 \(hours) 时 \(mins) 分"
            }
        }
    }

    // MARK: - Speech Synthesis (Native Pronunciation)
    private let speechSynthesizer = AVSpeechSynthesizer()

    func speakText(_ text: String) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        speechSynthesizer.speak(utterance)
    }

    // MARK: - Whole-Chapter Read Aloud (听书)
    let readAloud = ChapterReadAloudService()
    /// Paragraph index → short text anchor for auto-scrolling while narrating
    private var readAloudAnchors: [Int: String] = [:]

    /// Starts continuous chapter narration from a given paragraph offset (default 0).
    func startChapterReadAloud() {
        guard let book = currentBook, let chapter = book.currentChapter else { return }
        let raw = getCachedHTML(for: chapter.fileURL)
            ?? (try? String(contentsOf: chapter.fileURL, encoding: .utf8)) ?? ""
        guard !raw.isEmpty else { return }
        let body = EPUBThemeInjector.extractBodyContent(from: raw)
        let sanitized = EPUBThemeInjector.sanitizeAndElevateLayout(body)
        let paras = EPUBThemeExtractor.extractParagraphs(from: sanitized)
        guard !paras.isEmpty else { return }
        readAloudAnchors = Dictionary(
            uniqueKeysWithValues: paras.map { ($0.index, String($0.text.prefix(16)).replacingOccurrences(of: "\n", with: " ")) }
        )
        readAloud.start(bookId: book.id, paragraphs: paras.map { $0.text }, startIndex: 0, rate: 0.52)
    }

    func toggleChapterReadAloud() {
        switch readAloud.state {
        case .playing:
            readAloud.pause()
        case .paused:
            readAloud.resume()
        case .idle:
            startChapterReadAloud()
        }
    }

    func stopChapterReadAloud() {
        readAloud.stop()
    }

    func readAloudAnchor(for paragraphIndex: Int) -> String? {
        readAloudAnchors[paragraphIndex]
    }

    // MARK: - Import File Panel
    @MainActor
    func showImportOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 EPUB 电子书"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "epub") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let selectedURL = panel.url {
            Task {
                await openEPUB(url: selectedURL)
            }
        }
    }

    func removeBook(id: UUID) {
        if let idx = books.firstIndex(where: { $0.id == id }) {
            let removedBook = books.remove(at: idx)
            if currentBook?.id == removedBook.id {
                currentBook = books.first
                if books.isEmpty {
                    isViewingBookshelf = true
                }
            }
            try? FileManager.default.removeItem(at: removedBook.unzippedDirectory)
        }
    }

    func resetBookProgress(id: UUID) {
        if let idx = books.firstIndex(where: { $0.id == id }) {
            var b = books[idx]
            b.currentChapterIndex = 0
            books[idx] = b
            if currentBook?.id == id {
                currentBook = b
                chapterScrollProgress = 0.0
                updateSubsequentChaptersTotalChars()
            }
        }
    }

    // MARK: - Bilingual Interlinear Reading Management
    var updateTranslationAction: ((Int, String, String) -> Void)?
    var isTranslatingChapter: Bool {
        BilingualTranslationService.shared.isTranslatingChapter
    }
    var chapterTranslationProgress: Double {
        BilingualTranslationService.shared.currentProgressRatio
    }

    func currentChapterBilingualTranslations() -> [Int: String]? {
        guard let book = currentBook else { return nil }
        return BilingualTranslationService.shared.getCachedTranslations(
            bookTitle: book.title,
            chapterIndex: book.currentChapterIndex
        )
    }

    func toggleBilingualMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            settings.isBilingualEnabled.toggle()
        }
    }

    func translateParagraphAt(index: Int, text: String) {
        guard let book = currentBook, let chapter = book.currentChapter else { return }
        let bookTitle = book.title
        let chapterTitle = chapter.title
        let chapterIndex = book.currentChapterIndex
        let agentName = agentService.currentPreset.name

        Task {
            let translation = await BilingualTranslationService.shared.translateParagraph(
                text: text,
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                chapterIndex: chapterIndex,
                paragraphIndex: index,
                agentService: agentService
            )

            await MainActor.run {
                self.updateTranslationAction?(index, translation, agentName)
            }
        }
    }

    func translateCurrentChapterWithAgent() {
        guard let book = currentBook, let chapter = book.currentChapter else { return }
        let bookTitle = book.title
        let chapterTitle = chapter.title
        let chapterIndex = book.currentChapterIndex
        let agentName = agentService.currentPreset.name

        let rawHTML = getCachedHTML(for: chapter.fileURL) ?? (try? String(contentsOf: chapter.fileURL, encoding: .utf8)) ?? ""
        let paragraphs = EPUBThemeInjector.extractParagraphsFromHTML(rawHTML)
        guard !paragraphs.isEmpty else { return }

        let cached = BilingualTranslationService.shared.getCachedTranslations(bookTitle: bookTitle, chapterIndex: chapterIndex) ?? [:]
        let toTranslate = paragraphs.filter { cached[$0.index] == nil }

        Task {
            await BilingualTranslationService.shared.translateEntireChapter(
                paragraphs: toTranslate,
                bookTitle: bookTitle,
                chapterTitle: chapterTitle,
                chapterIndex: chapterIndex,
                agentService: agentService,
                onParagraphTranslated: { idx, trans in
                    self.updateTranslationAction?(idx, trans, agentName)
                }
            )
        }
    }
}
