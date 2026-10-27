import SwiftUI
import AppKit
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
