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
    private let databaseOverride: LibraryDatabase?
    private var database: LibraryDatabase { databaseOverride ?? .shared }
    private var deletedHighlights: [Highlight] = []

    var isViewingBookshelf: Bool = true // Default to showing Bookshelf on launch
    var isBrowsingOnlineLibrary: Bool = false // 书架层子页面：在线数字书库多栏页
    var sidebarTab: SidebarTab = .toc
    var isSidebarVisible: Bool = false
    var isAIPanelVisible: Bool = false
    var showReadingInsights: Bool = false
    var showWeChatSyncModal: Bool = false
    var showGlobalNotebooksModal: Bool = false
    var showReviewSessionModal: Bool = false
    var isLoadingBook: Bool = false
    var errorMessage: String?
    var chapterRenderID: UUID = UUID()
    var pendingRecap: RecapHint? = nil

    // MARK: 试读（在线书库 → 只读前几章，不落书架）
    /// 试读元数据：记录书从哪来，用于"完整导入"时回到既有的下载管线。
    enum PreviewSource: Equatable {
        case opds(fileURL: URL)          // 完整 EPUB 已在临时目录，导入即原文件走 openEPUB
        case weread(bookId: String, title: String, author: String, cover: String) // 完整本需再走微信抓取
    }
    var previewTotalChapterCount: Int = 0
    private(set) var previewBook: EPUBBook?
    var isInPreviewMode: Bool { previewBook != nil }

    /// 统一入口：从书架层打开在线数字书库页面。
    func openOnlineLibrary() {
        if !isViewingBookshelf { returnToBookshelf() }
        withAnimation(.easeInOut(duration: 0.22)) {
            isViewingBookshelf = true
            isBrowsingOnlineLibrary = true
        }
    }

    /// 前情回顾的延迟浮现任务（换书时取消旧的），以及本会话内已关闭提示的书
    private var recapTask: Task<Void, Never>?
    private var recapDismissedBookTitles: Set<String> = []

    var readingStats: ReadingStats {
        ReadingStatsManager.shared.stats
    }

    init(loadLibrary: Bool = true, database: LibraryDatabase? = nil,
         readAloud: ChapterReadAloudService? = nil) {
        self.databaseOverride = database
        self.readAloud = readAloud ?? ChapterReadAloudService()
        self.readAloud.onPositionChanged = { [weak self] position, bookId in
            self?.saveListeningPosition(position, bookId: bookId)
        }
        if loadLibrary || database != nil {
            loadPersistedHighlights()
            loadPersistedBookmarks()
        }
        guard loadLibrary else { return }
        // 跟随系统外观：启动即按当前亮暗套用昼/夜主题偏好（init 总在主线程构造视图前调用）
        if settings.followSystemAppearance {
            MainActor.assumeIsolated { settings.applySystemAppearance() }
        }
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
        // 跟随系统外观：macOS 亮/暗模式切换（AppleInterfaceTheme: Dark=暗, Light/Auto=亮）
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            // 系统切换动画落定后再应用，避免主题与窗口材质闪跳
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self, self.settings.followSystemAppearance else { return }
                MainActor.assumeIsolated { self.settings.applySystemAppearance() }
            }
        }
    }

    /// 重新扫描持久化书架目录，按完整路径补入新增 EPUB。
    @MainActor
    func reloadLibraryFromDisk() {
        for url in Self.persistedLibraryEPUBs() {
            guard !books.contains(where: { url.standardizedFileURL == $0.fileURL.standardizedFileURL }) else { continue }
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
        // 同名不同内容现在有独立身份；解析器负责缓存串行发布，书架按解析后的 ID 去重。
        let urls = Self.persistedLibraryEPUBs()
        await withTaskGroup(of: EPUBBook?.self) { group in
            var iterator = urls.makeIterator()
            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask { try? await EPUBParser.shared.parse(fileURL: url) }
            }
            for _ in 0..<4 { addNext() }
            for await book in group {
                addNext()
                if let book {
                    books = Self.orderedRestoredBooks(books + [book], sourceURLs: urls)
                }
            }
        }

        // 内置 demo 书（Walden/Little_Prince/LuXun）已按用户要求停用：书架只保留真实藏书。
        // SampleBookGenerator 保留在代码库中，需要时手动调用。

        isLoadingBook = false
        // Keep isViewingBookshelf = true so the user starts at the bookshelf!
    }

    /// 并发解析完成顺序不影响同书名的版本选择：始终保留来源列表中较新的版本。
    static func orderedRestoredBooks(_ candidates: [EPUBBook], sourceURLs: [URL]) -> [EPUBBook] {
        let order = Dictionary(sourceURLs.enumerated().map { ($1.standardizedFileURL, $0) }, uniquingKeysWith: min)
        var titles = Set<String>()
        var ids = Set<UUID>()
        return candidates.sorted {
            (order[$0.fileURL.standardizedFileURL] ?? Int.max) < (order[$1.fileURL.standardizedFileURL] ?? Int.max)
        }.filter { book in
            guard !titles.contains(book.title), !ids.contains(book.id) else { return false }
            titles.insert(book.title)
            ids.insert(book.id)
            return true
        }
    }

    /// Canonical shelf directory: Application Support/DReader (legacy samples) + DownloadedBooks/
    static func persistedLibraryEPUBs(baseDirectory: URL? = nil) -> [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = baseDirectory ?? appSupport.appendingPathComponent("DReader", isDirectory: true)
        var urls: [URL] = []
        let fm = FileManager.default
        for dir in [base, base.appendingPathComponent("DownloadedBooks")] {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                urls.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "epub" })
            }
        }
        let collisions = base.appendingPathComponent("DownloadedBooks/Variants", isDirectory: true)
        if let directories = try? fm.contentsOfDirectory(at: collisions, includingPropertiesForKeys: [.isDirectoryKey]) {
            for directory in directories where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    urls.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "epub" })
                }
            }
        }
        // Order: file modification (newest first) to keep the shelf fresh-feeling on restore
        return urls.sorted { a, b in
            let da = (try? fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
            return da > db
        }
    }

    /// 同名不同内容存入独立子目录，保留原文件名和旧书副本。
    static func persistShelfCopy(for fileURL: URL, shelfDirectory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let shelfDir = shelfDirectory ?? appSupport.appendingPathComponent("DReader/DownloadedBooks", isDirectory: true)
        try fm.createDirectory(at: shelfDir, withIntermediateDirectories: true)
        var destination = shelfDir.appendingPathComponent(fileURL.lastPathComponent)
        if destination.standardizedFileURL == fileURL.standardizedFileURL { return destination }
        if fm.fileExists(atPath: destination.path) {
            let fingerprint = try EPUBIdentity.fingerprint(of: fileURL)
            if try EPUBIdentity.fingerprint(of: destination) == fingerprint { return destination }
            let variant = shelfDir.appendingPathComponent("Variants/\(fingerprint)", isDirectory: true)
            try fm.createDirectory(at: variant, withIntermediateDirectories: true)
            destination = variant.appendingPathComponent(fileURL.lastPathComponent)
            if fm.fileExists(atPath: destination.path),
               try EPUBIdentity.fingerprint(of: destination) == fingerprint { return destination }
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func returnToBookshelf() {
        ReadingStatsManager.shared.pauseSession()
        flushReadingPosition()
        stopChapterReadAloud()
        withAnimation(.easeInOut(duration: 0.25)) {
            isViewingBookshelf = true
            isBrowsingOnlineLibrary = false
            selectionManager.clear()
        }
    }

    func selectBookForReading(_ book: EPUBBook) {
        if currentBook?.id != book.id {
            flushReadingPosition()
        }
        stopChapterReadAloud()
        readingSaveTask?.cancel()
        pendingListeningResume = nil
        completedReadingBookIDs.remove(book.id)

        let saved = database.readingPosition(for: book.id)
        var restored = book
        if let saved, restored.chapters.indices.contains(saved.chapterIndex) {
            restored.currentChapterIndex = saved.chapterIndex
        } else {
            restored.currentChapterIndex = 0
        }
        chapterScrollProgress = saved.map { min(max($0.scrollProgress, 0), 1) } ?? 0
        hasListeningResume = database.listeningPosition(for: book.id) != nil

        ReadingStatsManager.shared.startSession()
        let previousBookID = currentBook?.id
        let previousReadyURL = readyChapterURL
        let previousReadyIndex = readyChapterIndex
        withAnimation(.easeInOut(duration: 0.25)) {
            if previousBookID == restored.id,
               previousReadyURL == restored.currentChapter?.fileURL,
               previousReadyIndex == restored.currentChapterIndex {
                readyChapterURL = previousReadyURL
                readyChapterIndex = previousReadyIndex
            } else {
                readyChapterURL = nil
                readyChapterIndex = nil
            }
            if saved != nil, let chapter = restored.currentChapter {
                pendingReadingDestination = (chapter.fileURL, .readingPosition(chapterScrollProgress))
            } else {
                pendingReadingDestination = nil
            }
            currentBook = restored
            isViewingBookshelf = false
            isSidebarVisible = false
            selectionManager.clear()
        }
        if let chapter = restored.currentChapter,
           readyChapterURL == chapter.fileURL,
           readyChapterIndex == restored.currentChapterIndex {
            chapterDidBecomeReady(chapter.fileURL, chapterIndex: restored.currentChapterIndex)
        }
        updateBookInLibrary(restored)
        scheduleRecapIfAwayLong(for: restored)
        // 竖排偏好：已设置按书记忆 → 恢复；未设置 → 古籍默认竖排（仅首开时写入偏好）
        if settings.storedVertical(for: restored.id) {
            settings.isVertical = true
        } else if !UserDefaults.standard.bool(forKey: "dreader.vertical.seen.\(restored.id.uuidString)") {
            UserDefaults.standard.set(true, forKey: "dreader.vertical.seen.\(restored.id.uuidString)")
            if ReaderSettings.looksLikeClassicalChinese(title: restored.title, author: restored.author) {
                settings.isVertical = true
                var prefs = UserDefaults.standard.string(forKey: "dreader.vertical_by_book").flatMap {
                    $0.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                } ?? [:]
                prefs[restored.id.uuidString] = "1"
                if let data = try? JSONEncoder().encode(prefs) {
                    UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "dreader.vertical_by_book")
                }
            }
        }
        updateSubsequentChaptersTotalChars()
    }

    // MARK: - 读完复盘状态
    var pendingFinishSnapshot: FinishSnapshot?

    // MARK: - 前情回顾（Kindle Recaps 范式）

    /// 开书后判定是否值得给出前情回顾：本书最近印记 ≥ 3 天前、位置不在第一章，且本会话未关过提示。
    /// 邀请条延迟 1.4s 浮现，避免与开书动效抢注意力。
    private func scheduleRecapIfAwayLong(for book: EPUBBook) {
        recapTask?.cancel()
        pendingRecap = nil
        guard previewBook == nil else { return }
        guard !recapDismissedBookTitles.contains(book.title), book.currentChapterIndex == 0 else { return }
        guard let activity = database.latestActivity(bookTitle: book.title) else { return }
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

    // MARK: - 读完复盘（Finish Card）

    /// 读完判定：最后一章滚动过 85% 即视为读完（尾页常有版权页噪声，85% 已过正文）。
    /// 每本书只庆祝一次（UserDefaults 记账）；再次打开不重复打扰。
    func noteChapterScrollProgress(_ progress: Double) {
        let clamped = min(max(progress, 0), 1)
        // DOM 初始化先回到章首；待恢复记录被 ready 消费前，不能把旧进度写成 0。
        if case .readingPosition? = pendingReadingDestination?.1, clamped == 0 { return }
        chapterScrollProgress = clamped
        scheduleReadingPositionSave()
        guard let book = currentBook,
              book.currentChapterIndex == book.chapters.count - 1,
              clamped >= 0.85
        else { return }
        let finishKey = "dreader.finish_card_shown.\(book.id.uuidString)"
        guard !UserDefaults.standard.bool(forKey: finishKey) else { return }
        UserDefaults.standard.set(true, forKey: finishKey)
        ReadingStatsManager.shared.pauseSession()
        Task { @MainActor in
            // 让滚动停下再浮卡，避免抢最后一下滚动
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, currentBook?.id == book.id else { return }
            if let snapshot = FinishSnapshot.build(book: book) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    pendingFinishSnapshot = snapshot
                }
            }
        }
    }

    /// 切章、换书、返回书架或退出时同步保存；滚动期间只做短时间去抖。
    /// 试读不入库：不位置落库。
    func flushReadingPosition() {
        readingSaveTask?.cancel()
        readingSaveTask = nil
        guard previewBook == nil else { return }
        guard let book = currentBook else { return }
        saveReadingPosition(
            bookId: book.id,
            chapterIndex: book.currentChapterIndex,
            progress: chapterScrollProgress
        )
    }

    private func scheduleReadingPositionSave() {
        guard previewBook == nil else { return }
        guard let book = currentBook, let chapter = book.currentChapter,
              readyChapterURL == chapter.fileURL,
              readyChapterIndex == book.currentChapterIndex else { return }
        let bookId = book.id
        let chapterIndex = book.currentChapterIndex
        let progress = chapterScrollProgress
        readingSaveTask?.cancel()
        readingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveReadingPosition(bookId: bookId, chapterIndex: chapterIndex, progress: progress)
        }
    }

    private func saveReadingPosition(bookId: UUID, chapterIndex: Int, progress: Double) {
        guard previewBook == nil,
              readAloud.state == .idle,
              !completedReadingBookIDs.contains(bookId) else { return }
        database.saveReadingPosition(.init(
            bookId: bookId,
            chapterIndex: chapterIndex,
            scrollProgress: min(max(progress, 0), 1),
            updatedAt: Date()
        ))
    }

    func dismissFinishCard() {
        if let bookId = currentBook?.id {
            completedReadingBookIDs.insert(bookId)
            readingSaveTask?.cancel()
            database.deleteReadingPosition(for: bookId)
        }
        chapterScrollProgress = 0
        withAnimation(.easeOut(duration: 0.25)) {
            pendingFinishSnapshot = nil
        }
    }

    // MARK: - Open EPUB
    @MainActor
    func openEPUB(url: URL) async {
        isLoadingBook = true
        errorMessage = nil

        do {
            var parseURL = url
            let needsConversion = Self.isKindleStream(url) || MarkdownImporter.isMarkdown(fileURL: url) || PDFImporter.isPDF(fileURL: url)
            if needsConversion {
                let convert: @Sendable (URL) throws -> URL = MarkdownImporter.isMarkdown(fileURL: url)
                    ? Self.convertMarkdownEPUB
                    : PDFImporter.isPDF(fileURL: url)
                        ? Self.convertPDFEPUB
                        : Self.convertMOBIEPUB
                do {
                    let parsed = try await Task.detached(priority: .userInitiated) {
                        try convert(url)
                    }.value
                    parseURL = parsed
                } catch {
                    isLoadingBook = false
                    errorMessage = "《\(url.deletingPathExtension().lastPathComponent)》导入失败 — \(error.localizedDescription)"
                    return
                }
            }
            var book = try await EPUBParser.shared.parse(fileURL: parseURL)
            book.fileURL = try await Task.detached(priority: .userInitiated) {
                try Self.persistShelfCopy(for: url)
            }.value
            if let existingIndex = books.firstIndex(where: { $0.title == book.title }) {
                books[existingIndex] = book
                selectBookForReading(book)
            } else {
                books.insert(book, at: 0)
                selectBookForReading(book)
            }
            self.isLoadingBook = false
        } catch {
            self.isLoadingBook = false
            let fileName = url.deletingPathExtension().lastPathComponent
            self.errorMessage = "《\(fileName)》导入失败 — \(error.localizedDescription)"
        }
    }

    /// 文件点选项在打开面板里的类型集合（EPUB / Kindle 流 / Markdown / PDF）。
    static var importableContentTypes: [UTType] {
        let extensions = ["epub", "mobi", "azw3", "md", "markdown", "pdf"]
        return extensions.compactMap { UTType(filenameExtension: $0) } + [UTType.data]
    }

    /// 扩展名或 PalmDB 魔数（"BOOK"/"TEXt"，PDB 头 0x3C 偏移处）判定 Kindle 流文件。
    static func isKindleStream(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mobi", "azw3", "azw", "prc"].contains(ext) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: 0x3C)
        guard let header = try? handle.read(upToCount: 8), header.count >= 4 else { return false }
        return header.prefix(4) == Data("BOOK".utf8) || header.prefix(4) == Data("TEXt".utf8)
    }

    /// 解析 MOBI → 组装标准 EPUB，输出到 Application Support 的转换缓存目录。
    static func convertMOBIEPUB(from url: URL) throws -> URL {
        let parsed = try MOBIParser.parse(fileURL: url)
        return try convertParsedToEPUB(parsed, from: url)
    }

    /// Markdown → 组装标准 EPUB（标题切章、frontmatter 提元数据）。
    static func convertMarkdownEPUB(from url: URL) throws -> URL {
        let parsed = try MarkdownImporter.parse(fileURL: url)
        return try convertParsedToEPUB(parsed, from: url)
    }

    /// PDF → 组装标准 EPUB：文字层走重排，扫描件走原版式页面图。
    static func convertPDFEPUB(from url: URL) throws -> URL {
        let parsed = try PDFImporter.parse(fileURL: url)
        return try convertParsedToEPUB(parsed, from: url)
    }

    /// 解析产物 → ConvertedBooks 里的 EPUB；重导入覆盖转换件（幂等）。
    private static func convertParsedToEPUB(_ parsed: ParsedBook, from url: URL) throws -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DReader/ConvertedBooks", isDirectory: true)
        var output = root.appendingPathComponent("\(stem).epub")
        if output.path == url.path { output = root.appendingPathComponent("\(stem)-converted.epub") }
        try EpubAssembler.assemble(book: parsed, outputURL: output)
        return output
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
    var scrollToReadingProgressAction: ((Double) -> Void)?
    private var readingSaveTask: Task<Void, Never>?
    private var completedReadingBookIDs: Set<UUID> = []
    var hasListeningResume = false
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

    private var pendingPreloadURLs: Set<URL> = []

    /// 只预热当前章附近的正文；全书字数由统一后台队列补齐。
    func preloadAllChapters(for book: EPUBBook) {
        let chapters = book.chapters
        guard chapters.indices.contains(book.currentChapterIndex) else { return }
        let lower = max(0, book.currentChapterIndex - 2)
        let upper = min(chapters.count, book.currentChapterIndex + 3)
        let urls = chapters[lower..<upper].map(\.fileURL).filter {
            htmlContentCache[$0] == nil && pendingPreloadURLs.insert($0).inserted
        }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            for url in urls {
                let content = EPUBWebView.Coordinator.readTextSmart(url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.pendingPreloadURLs.remove(url)
                    if let content { self.cacheHTML(content, for: url) }
                }
            }
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
        flushReadingPosition()
        stopChapterReadAloud()
        readyChapterURL = nil
        readyChapterIndex = nil
        pendingReadingDestination = nil
        book.currentChapterIndex += 1
        currentBook = book
        updateBookInLibrary(book)
        updateSubsequentChaptersTotalChars()
        chapterScrollProgress = 0.0
        flushReadingPosition()
        selectionManager.clear()
    }

    func prevChapter() {
        guard var book = currentBook, book.currentChapterIndex > 0 else { return }
        flushReadingPosition()
        stopChapterReadAloud()
        readyChapterURL = nil
        readyChapterIndex = nil
        pendingReadingDestination = nil
        book.currentChapterIndex -= 1
        currentBook = book
        updateBookInLibrary(book)
        updateSubsequentChaptersTotalChars()
        chapterScrollProgress = 0.0
        flushReadingPosition()
        selectionManager.clear()
    }

    func jumpToChapter(_ index: Int, preserveReadingPosition: Bool = false) {
        guard var book = currentBook, book.chapters.indices.contains(index) else { return }
        if book.currentChapterIndex == index {
            // Smoothly scroll to the beginning of the current chapter
            if !preserveReadingPosition {
                chapterScrollProgress = 0
                scrollPageAction?(0)
                flushReadingPosition()
            }
            return
        }
        flushReadingPosition()
        stopChapterReadAloud()
        readyChapterURL = nil
        readyChapterIndex = nil
        pendingReadingDestination = nil
        book.currentChapterIndex = index
        currentBook = book
        updateBookInLibrary(book)
        updateSubsequentChaptersTotalChars()
        chapterScrollProgress = 0.0
        if !preserveReadingPosition {
            flushReadingPosition()
        }
        selectionManager.clear()
    }

    private func updateBookInLibrary(_ book: EPUBBook) {
        guard previewBook == nil else { return }
        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx] = book
        }
    }

    // MARK: - 试读（在线书库）

    var previewSource: PreviewSource?

    /// 试读打开：不落书架、不写位置/统计，关掉即丢。书的前 N 章由调用方已经裁好。
    @MainActor
    func enterPreview(book: EPUBBook, meta: PreviewSource, totalChapters: Int) {
        flushReadingPosition()          // 此前若在读别的书，先落位保存
        stopChapterReadAloud()
        readingSaveTask?.cancel()
        pendingListeningResume = nil
        pendingReadingDestination = nil
        readyChapterURL = nil
        readyChapterIndex = nil
        chapterScrollProgress = 0
        completedReadingBookIDs.remove(book.id)
        previewBook = book
        previewTotalChapterCount = totalChapters
        previewSource = meta
        withAnimation(.easeInOut(duration: 0.25)) {
            currentBook = book
            isViewingBookshelf = false
            isBrowsingOnlineLibrary = false
            isSidebarVisible = false
            selectionManager.clear()
        }
    }

    /// 试读收摊：临时书丢弃（temp 文件留给系统 tmp 清理或被"完整导入"复用）。
    @MainActor
    func exitPreview() {
        previewTotalChapterCount = 0
        previewSource = nil
        previewBook = nil
        readingSaveTask?.cancel()
        pendingReadingDestination = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            currentBook = nil
            isViewingBookshelf = true
            isBrowsingOnlineLibrary = true
            selectionManager.clear()
        }
    }

    /// OPDS 试读 → 完整导入：完整文件已下载在临时目录，直接走既有 openEPUB 全管线（二次解析 + 落架）。
    @MainActor
    func importOPDSPreview() {
        guard case .opds(let fileURL)? = previewSource else { return }
        previewTotalChapterCount = 0
        previewSource = nil
        previewBook = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            isViewingBookshelf = true
            isBrowsingOnlineLibrary = true
        }
        Task { await openEPUB(url: fileURL) }
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

    private enum ReadingDestination {
        case highlight(String)
        case search(String, Int)
        case readAloud
        case readingPosition(Double)
    }
    private var pendingReadingDestination: (URL, ReadingDestination)?
    private var readyChapterURL: URL?
    private var readyChapterIndex: Int?

    func chapterDidBecomeReady(_ url: URL, chapterIndex: Int) {
        guard currentBook?.currentChapterIndex == chapterIndex,
              currentBook?.currentChapter?.fileURL == url else { return }
        readyChapterURL = url
        readyChapterIndex = chapterIndex
        guard let (targetURL, destination) = pendingReadingDestination, targetURL == url else { return }
        pendingReadingDestination = nil
        switch destination {
        case .highlight(let id): scrollToHighlightAction?(id)
        case .search(let keyword, let index): scrollToSearchMatchAction?(keyword, index)
        case .readAloud: startChapterReadAloud()
        case .readingPosition(let progress):
            chapterScrollProgress = progress
            scrollToReadingProgressAction?(progress)
            if let book = currentBook {
                saveReadingPosition(bookId: book.id, chapterIndex: chapterIndex, progress: progress)
            }
        }
    }

    /// 兼容旧测试和内部调用；生产 ready 回调携带 spine occurrence。
    func chapterDidBecomeReady(_ url: URL) {
        guard let index = currentBook?.currentChapterIndex else { return }
        chapterDidBecomeReady(url, chapterIndex: index)
    }

    func jumpToHighlight(_ highlight: Highlight) {
        guard let book = currentBook, book.chapters.indices.contains(highlight.chapterIndex) else { return }
        let url = book.chapters[highlight.chapterIndex].fileURL
        if book.currentChapterIndex == highlight.chapterIndex, readyChapterURL == url {
            scrollToHighlightAction?(highlight.id.uuidString)
        } else {
            if book.currentChapterIndex != highlight.chapterIndex { jumpToChapter(highlight.chapterIndex) }
            pendingReadingDestination = (url, .highlight(highlight.id.uuidString))
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
            // 旧记录缺少字段标记时延续已有保护；此后只标记用户实际编辑的字段。
            let legacyEdited = (h.updatedAt ?? h.createdAt) > h.createdAt
            h.isNoteLocallyEdited = h.isNoteLocallyEdited ?? legacyEdited
            h.isColorLocallyEdited = h.isColorLocallyEdited ?? legacyEdited
            if let c = colorHex {
                h.colorHex = c
                h.isColorLocallyEdited = true
                lastChosenHighlightColor = c
                updateHighlightColorAction?(id.uuidString, c)
            }
            if let n = note {
                let trimmed = n.trimmingCharacters(in: .whitespacesAndNewlines)
                h.note = trimmed.isEmpty ? nil : trimmed
                h.isNoteLocallyEdited = true
                updateHighlightThoughtAction?(id.uuidString, h.note)
            }
            h.updatedAt = Date()
            highlights[idx] = h
            savePersistedHighlights()
        }
    }

    func deleteHighlight(_ id: UUID) {
        if let removed = highlights.first(where: { $0.id == id }) {
            deletedHighlights.append(removed)
        }
        highlights.removeAll { $0.id == id }
        database.deleteHighlight(id: id)
        database.deleteReviewSchedule(highlightId: id)
        selectionManager.activeHighlightCard = nil
        removeHighlightAction?(id.uuidString)
    }

    func persistHighlightsDirectly() {
        savePersistedHighlights()
    }

    @MainActor
    @discardableResult
    func applyWeChatSyncResult(_ incoming: [Highlight], baseline: [Highlight]) -> Int {
        let oldCount = highlights.count
        highlights = WeChatReadingService.mergeHighlights(incoming, into: highlights,
            baseline: baseline, deleted: deletedHighlights)
        savePersistedHighlights()
        return max(0, highlights.count - oldCount)
    }

    private func savePersistedHighlights() {
        database.upsertHighlights(highlights)
        // Legacy UserDefaults copy retired from active use; SQLite (LibraryDatabase) is now
        // the source of truth. The old UserDefaults blob stays as a historical backup.
    }

    private func loadPersistedHighlights() {
        // 旧格式迁移由数据库负责；空数组也是有效的已保存状态。
        highlights = database.loadHighlights()
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

        guard book.chapters.indices.contains(item.chapterIndex) else { return }
        let url = book.chapters[item.chapterIndex].fileURL
        if book.currentChapterIndex == item.chapterIndex, readyChapterURL == url {
            scrollToSearchMatchAction?(item.keyword, item.matchIndexInChapter)
        } else {
            if book.currentChapterIndex != item.chapterIndex { jumpToChapter(item.chapterIndex) }
            pendingReadingDestination = (url, .search(item.keyword, item.matchIndexInChapter))
        }
    }

    // MARK: - AI 伴读笔记落库

    /// 用提问时捕获的书章归属保存回答，切章和换书不改变旧消息的来源。
    @MainActor
    func saveAIMessageAsNote(_ message: ChatMessage) {
        guard message.role == .assistant, let source = message.noteSource else { return }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = Highlight(
            bookId: source.bookId,
            bookTitle: source.bookTitle,
            chapterIndex: source.chapterIndex,
            chapterTitle: source.chapterTitle,
            text: "【AI 伴读解读】\(source.chapterTitle)",
            colorHex: "#A5D8FF",
            note: trimmed,
            source: "ai_companion"
        )
        database.upsertHighlights([note])
        highlights.append(note)
    }

    /// Kindle 生词本闭环：查词动作把词自动收进生词库（source="vocabulary"），
    /// 首次到期复习由 review_schedule 的 NULL 分支自然接管，进入 7/14/28 天队列。
    func saveVocabularyWord(_ raw: String) {
        guard let book = currentBook, let chapter = book.currentChapter else { return }
        if database.upsertVocabularyWord(
            raw,
            bookId: book.id,
            bookTitle: book.title,
            chapterTitle: chapter.title
        ) != nil {
            // 仅新词才刷新内存列表（去重命中时静默）
            highlights = database.loadHighlights()
        }
    }

    // MARK: - Cross-Book Library Search (全书库搜索)
    var crossBookGroups: [CrossBookSearchGroup] = []
    var isCrossBookSearching = false
    private var crossBookTask: Task<Void, Never>?

    func performCrossBookSearch(query rawQuery: String) {
        searchQuery = rawQuery
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
            let removed = bookmarks.remove(at: idx)
            database.deleteBookmark(id: removed.id)
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
        database.deleteBookmark(id: id)
    }

    private func savePersistedBookmarks() {
        database.upsertBookmarks(bookmarks)
    }

    private func loadPersistedBookmarks() {
        bookmarks = database.loadBookmarks()
    }

    // MARK: - Reading Time & Speed Estimation
    private let charactersPerMinute: Double = 400.0
    private var chapterCharCountCache: [URL: Int] = [:]
    private var subsequentChaptersTotalChars: Int = 0
    private var pendingCharCountURLs: Set<URL> = []
    private var charCountQueue: [URL] = []
    private var activeCharCountTasks = 0
    private let maxCharCountTasks = 2

    private func cachedCharCount(for url: URL) -> Int? {
        chapterCharCountCache[url]
    }

    /// 所有字数任务共用两路队列，避免合订本为每章同时创建读盘任务。
    func computeCharCountInBackground(for url: URL) {
        guard chapterCharCountCache[url] == nil, pendingCharCountURLs.insert(url).inserted else { return }
        charCountQueue.append(url)
        startQueuedCharCounts()
    }

    private func startQueuedCharCounts() {
        while activeCharCountTasks < maxCharCountTasks, !charCountQueue.isEmpty {
            let url = charCountQueue.removeFirst()
            let cachedHTML = getCachedHTML(for: url)
            activeCharCountTasks += 1
            Task.detached(priority: .utility) { [weak self] in
                let html = cachedHTML ?? EPUBWebView.Coordinator.readTextSmart(url)
                let count = html.map { stripHTMLTags(from: $0).count }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.activeCharCountTasks -= 1
                    self.pendingCharCountURLs.remove(url)
                    if let count { self.chapterCharCountCache[url] = count }
                    self.refreshSubsequentChaptersTotalChars()
                    self.startQueuedCharCounts()
                }
            }
        }
    }

    private func refreshSubsequentChaptersTotalChars() {
        guard let book = currentBook else {
            subsequentChaptersTotalChars = 0
            return
        }
        subsequentChaptersTotalChars = book.chapters.dropFirst(book.currentChapterIndex + 1).reduce(0) {
            $0 + (chapterCharCountCache[$1.fileURL] ?? 0)
        }
    }

    /// 界面只查缓存，后台完成后对当前阅读位置重新求和。
    func updateSubsequentChaptersTotalChars() {
        refreshSubsequentChaptersTotalChars()
        guard let book = currentBook else { return }
        let needed = Set(book.chapters.dropFirst(book.currentChapterIndex).map(\.fileURL))
        let obsolete = charCountQueue.filter { !needed.contains($0) }
        charCountQueue.removeAll { !needed.contains($0) }
        for url in obsolete { pendingCharCountURLs.remove(url) }
        if let chapter = book.currentChapter { computeCharCountInBackground(for: chapter.fileURL) }
        for chapter in book.chapters.dropFirst(book.currentChapterIndex + 1) {
            computeCharCountInBackground(for: chapter.fileURL)
        }
        preloadAllChapters(for: book)
    }

    func currentChapterCharCount() -> Int {
        guard let chapter = currentBook?.currentChapter else { return 0 }
        if let count = cachedCharCount(for: chapter.fileURL) { return count }
        computeCharCountInBackground(for: chapter.fileURL)
        return 0
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
        _ = book // 保持既有签名

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
    let readAloud: ChapterReadAloudService
    var scrollToReadAloudSegmentAction: ((Int) -> Void)?
    var readAloudSegmentsProvider: (() async throws -> [ChapterReadAloudService.Segment])?
    private var readAloudPreparationTask: Task<Void, Never>?
    private var pendingListeningResume: LibraryDatabase.ListeningPosition?

    private func saveListeningPosition(_ position: ChapterReadAloudService.PlaybackPosition?, bookId: UUID?) {
        guard let bookId else { return }
        guard let position else {
            database.deleteListeningPosition(for: bookId)
            if currentBook?.id == bookId { hasListeningResume = false }
            return
        }
        // 只由当前书章产生新记录；过期回调不能把别章写进这本书。
        guard currentBook?.id == bookId, let chapterIndex = currentBook?.currentChapterIndex else { return }
        database.saveListeningPosition(.init(
            bookId: bookId,
            chapterIndex: chapterIndex,
            segmentID: position.segmentID,
            chunkIndex: position.chunkIndex,
            chunkText: position.chunkText,
            updatedAt: Date()
        ))
        hasListeningResume = true
    }

    /// 从当前真实渲染的 DOM 获取正文，保留其定位标识而不是前 16 字锚点。
    func startChapterReadAloud() {
        readAloud.settingsProvider = { [settings] in settings }
        guard let book = currentBook,
              let chapter = book.currentChapter else { return }
        readAloudPreparationTask?.cancel()
        if case .readAloud? = pendingReadingDestination?.1 {
            pendingReadingDestination = nil
        }
        var resume = pendingListeningResume
        if let saved = resume, !book.chapters.indices.contains(saved.chapterIndex) {
            database.deleteListeningPosition(for: book.id)
            hasListeningResume = false
            pendingListeningResume = nil
            resume = nil
        }
        if let resume, resume.chapterIndex != book.currentChapterIndex {
            // 只有这次明确点击才改变当前章节；原阅读位置先独立保存。
            flushReadingPosition()
            pendingListeningResume = resume
            jumpToChapter(resume.chapterIndex, preserveReadingPosition: true)
            if let target = currentBook?.currentChapter {
                pendingReadingDestination = (target.fileURL, .readAloud)
            }
            return
        }
        let chapterIndex = book.currentChapterIndex
        let chapterURL = chapter.fileURL
        guard readyChapterURL == chapterURL, readyChapterIndex == chapterIndex else {
            pendingReadingDestination = (chapterURL, .readAloud)
            return
        }
        guard let readAloudSegmentsProvider else { return }
        readAloudPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let segments = try await readAloudSegmentsProvider()
                guard !Task.isCancelled,
                      self.currentBook?.id == book.id,
                      self.currentBook?.currentChapterIndex == chapterIndex,
                      self.currentBook?.currentChapter?.fileURL == chapterURL,
                      self.readyChapterURL == chapterURL,
                      self.readyChapterIndex == chapterIndex else { return }
                self.readAloudPreparationTask = nil
                guard !segments.isEmpty else {
                    self.errorMessage = "本章没有可朗读的正文"
                    return
                }
                self.pendingListeningResume = nil
                let playbackResume = resume.map {
                    ChapterReadAloudService.PlaybackPosition(
                        bookId: $0.bookId,
                        segmentID: $0.segmentID,
                        chunkIndex: $0.chunkIndex,
                        chunkText: $0.chunkText
                    )
                }
                self.readAloud.start(bookId: book.id, segments: segments,
                                     resume: playbackResume, rate: 0.52)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.currentBook?.id == book.id,
                      self.currentBook?.currentChapterIndex == chapterIndex else { return }
                self.readAloudPreparationTask = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func toggleChapterReadAloud() {
        switch readAloud.state {
        case .playing:
            readAloud.pause()
        case .paused:
            readAloud.resume()
        case .idle:
            if let book = currentBook {
                pendingListeningResume = database.listeningPosition(for: book.id)
            }
            startChapterReadAloud()
        }
    }

    func stopChapterReadAloud() {
        readAloudPreparationTask?.cancel()
        readAloudPreparationTask = nil
        if case .readAloud? = pendingReadingDestination?.1 {
            pendingReadingDestination = nil
        }
        readAloud.stop()
    }

    func flushPositionPersistence() {
        flushReadingPosition()
        stopChapterReadAloud()
    }

    // MARK: - Import File Panel
    @MainActor
    func showImportOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择电子书"
        panel.allowedContentTypes = Self.importableContentTypes
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
        if currentBook?.id == id {
            readingSaveTask?.cancel()
            stopChapterReadAloud()
            pendingReadingDestination = nil
            readyChapterURL = nil
            readyChapterIndex = nil
            hasListeningResume = false
        }
        database.deletePositions(for: id)
        completedReadingBookIDs.remove(id)
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
        readingSaveTask?.cancel()
        if currentBook?.id == id {
            stopChapterReadAloud()
            pendingReadingDestination = nil
            readyChapterURL = nil
            readyChapterIndex = nil
            hasListeningResume = false
        }
        database.deletePositions(for: id)
        completedReadingBookIDs.remove(id)
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
