import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

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
    var isSidebarVisible: Bool = true
    var isAIPanelVisible: Bool = true
    var isLoadingBook: Bool = false
    var errorMessage: String?
    var chapterRenderID: UUID = UUID()

    init() {
        loadPersistedHighlights()
        loadPersistedBookmarks()
        Task {
            await initializeLibrary()
        }
    }

    // MARK: - Library Initialization
    @MainActor
    func initializeLibrary() async {
        isLoadingBook = true
        let sampleURLs = await SampleBookGenerator.shared.generateAllSampleBooksIfNeeded()

        for url in sampleURLs {
            if let book = try? await EPUBParser.shared.parse(fileURL: url) {
                if let idx = books.firstIndex(where: { $0.title == book.title }) {
                    books[idx] = book
                } else {
                    books.append(book)
                }
                preloadAllChapters(for: book)
            }
        }

        isLoadingBook = false
        // Keep isViewingBookshelf = true so the user starts at the bookshelf!
    }

    func returnToBookshelf() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isViewingBookshelf = true
            selectionManager.clear()
        }
    }

    func selectBookForReading(_ book: EPUBBook) {
        withAnimation(.easeInOut(duration: 0.25)) {
            currentBook = book
            isViewingBookshelf = false
            selectionManager.clear()
        }
        preloadAllChapters(for: book)
    }

    // MARK: - Open EPUB
    @MainActor
    func openEPUB(url: URL) async {
        isLoadingBook = true
        errorMessage = nil

        do {
            let book = try await EPUBParser.shared.parse(fileURL: url)
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
            self.errorMessage = "加载书籍失败: \(error.localizedDescription)"
        }
    }

    var chapterScrollProgress: Double = 0.0
    var scrollPageAction: ((Int) -> Void)?
    var applyHighlightAction: ((String, String, String?) -> Void)?
    var updateHighlightColorAction: ((String, String) -> Void)?
    var updateHighlightThoughtAction: ((String, String?) -> Void)?
    var removeHighlightAction: ((String) -> Void)?
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
            for ch in chapters {
                if let content = try? String(contentsOf: ch.fileURL, encoding: .utf8) {
                    preloaded[ch.fileURL] = content
                }
            }
            if let self = self {
                await self.storePreloadedChapters(preloaded)
            }
        }
    }

    @MainActor
    private func storePreloadedChapters(_ preloaded: [URL: String]) {
        for (url, content) in preloaded {
            self.htmlContentCache[url] = content
        }
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
        book.currentChapterIndex += 1
        currentBook = book
        updateBookInLibrary(book)
        chapterScrollProgress = 0.0
        selectionManager.clear()
    }

    func prevChapter() {
        guard var book = currentBook, book.currentChapterIndex > 0 else { return }
        book.currentChapterIndex -= 1
        currentBook = book
        updateBookInLibrary(book)
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
        book.currentChapterIndex = index
        currentBook = book
        updateBookInLibrary(book)
        chapterScrollProgress = 0.0
        selectionManager.clear()
    }

    private func updateBookInLibrary(_ book: EPUBBook) {
        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx] = book
        }
    }

    // MARK: - Highlighting & Thoughts (WeChat Read style)
    func currentBookHighlights() -> [Highlight] {
        guard let book = currentBook else { return [] }
        return highlights.filter { $0.bookTitle == book.title || $0.bookId == book.id }
    }

    func currentChapterHighlights() -> [Highlight] {
        guard let book = currentBook else { return [] }
        return highlights.filter {
            ($0.bookTitle == book.title || $0.bookId == book.id) && $0.chapterIndex == book.currentChapterIndex
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
        savePersistedHighlights()
        selectionManager.activeHighlightCard = nil
        removeHighlightAction?(id.uuidString)
    }

    private func savePersistedHighlights() {
        if let encoded = try? JSONEncoder().encode(highlights) {
            UserDefaults.standard.set(encoded, forKey: "dreader.highlights")
        }
    }

    private func loadPersistedHighlights() {
        if let data = UserDefaults.standard.data(forKey: "dreader.highlights"),
           let decoded = try? JSONDecoder().decode([Highlight].self, from: data) {
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
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(encoded, forKey: "dreader.bookmarks")
        }
    }

    private func loadPersistedBookmarks() {
        if let data = UserDefaults.standard.data(forKey: "dreader.bookmarks"),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            self.bookmarks = decoded
        }
    }

    // MARK: - Reading Time & Speed Estimation
    private let charactersPerMinute: Double = 400.0

    func currentChapterCharCount() -> Int {
        guard let book = currentBook, let chapter = book.currentChapter else { return 0 }
        let html = getCachedHTML(for: chapter.fileURL) ?? (try? String(contentsOf: chapter.fileURL, encoding: .utf8)) ?? ""
        return stripHTMLTags(from: html).count
    }

    func currentChapterRemainingMinutes() -> Int {
        let count = currentChapterCharCount()
        guard count > 0 else { return 1 }
        let remaining = Double(count) * max(0.02, 1.0 - chapterScrollProgress)
        return max(1, Int(ceil(remaining / charactersPerMinute)))
    }

    func bookRemainingTimeFormatted() -> String {
        guard let book = currentBook, !book.chapters.isEmpty else { return "" }
        var totalRemainingChars = 0

        let currCount = currentChapterCharCount()
        totalRemainingChars += Int(Double(currCount) * max(0.02, 1.0 - chapterScrollProgress))

        for i in (book.currentChapterIndex + 1)..<book.chapters.count {
            let ch = book.chapters[i]
            let html = getCachedHTML(for: ch.fileURL) ?? (try? String(contentsOf: ch.fileURL, encoding: .utf8)) ?? ""
            totalRemainingChars += stripHTMLTags(from: html).count
        }

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
}
