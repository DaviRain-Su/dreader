import XCTest
import SQLite3
@testable import DReader

@MainActor
final class KnowledgeRegressionTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var database: LibraryDatabase!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dreader-knowledge-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "dreader-knowledge-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        database = makeDatabase()
    }

    override func tearDown() async throws {
        database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDatabase() -> LibraryDatabase {
        LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"), preferences: defaults)
    }

    private func makeBook(_ title: String) -> EPUBBook {
        let chapter = EPUBChapter(id: "chapter", title: "\(title)第一章",
            fileURL: directory.appendingPathComponent("\(title).xhtml"), orderIndex: 0)
        return EPUBBook(title: title, fileURL: directory.appendingPathComponent("\(title).epub"),
            unzippedDirectory: directory, opfDirectory: directory, chapters: [chapter])
    }

    private func remote(_ id: String = "mark", bookID: String = "remote-book", note: String? = nil) -> Highlight {
        Highlight(bookId: UUID(), bookTitle: "测试书", chapterIndex: 0, chapterTitle: "第一章",
            text: "相同引文", colorHex: "#FFE066", createdAt: Date(timeIntervalSince1970: 100),
            note: note, updatedAt: Date(timeIntervalSince1970: 100), source: "wechat_read",
            wechatBookId: bookID, wechatBookmarkId: id)
    }

    func testRepeatedSyncPreservesLocalThoughtAndExplicitClear() throws {
        let server = remote()
        database.upsertHighlights([server])
        let vm = ReaderViewModel(loadLibrary: false, database: database)
        vm.updateHighlight(id: server.id, note: "本地新增的想法")
        vm.applyWeChatSyncResult([server], baseline: vm.highlights)
        XCTAssertEqual(database.loadHighlights().first?.note, "本地新增的想法")

        vm.updateHighlight(id: server.id, note: "")
        var withCloudThought = server
        withCloudThought.note = "旧的云端想法"
        vm.applyWeChatSyncResult([withCloudThought], baseline: vm.highlights)
        XCTAssertNil(database.loadHighlights().first?.note)
    }

    func testSyncCompletionKeepsConcurrentEditsDeletesAndNewNotes() throws {
        let edited = remote("edited")
        let deleted = remote("deleted")
        database.upsertHighlights([edited, deleted])
        let vm = ReaderViewModel(loadLibrary: false, database: database)
        let baseline = vm.highlights
        vm.updateHighlight(id: edited.id, colorHex: "#A5D8FF", note: "同步等待期间编辑")
        vm.deleteHighlight(deleted.id)
        let addedLocally = remote("local")
        vm.highlights.append(addedLocally)
        vm.persistHighlightsDirectly()
        let newRemote = remote("new")
        vm.applyWeChatSyncResult([edited, deleted, newRemote], baseline: baseline)
        let stored = database.loadHighlights()
        XCTAssertEqual(stored.count, 3)
        XCTAssertFalse(stored.contains { $0.id == deleted.id })
        XCTAssertEqual(stored.first { $0.id == edited.id }?.note, "同步等待期间编辑")
        XCTAssertEqual(stored.first { $0.id == edited.id }?.colorHex, "#A5D8FF")
        XCTAssertTrue(stored.contains { $0.id == addedLocally.id })
        XCTAssertTrue(stored.contains { $0.id == newRemote.id })
        // 另一个并行同步也不能把删除重新插回。
        let recreatedRemote = Highlight(bookId: deleted.bookId, bookTitle: deleted.bookTitle,
            chapterIndex: deleted.chapterIndex, chapterTitle: deleted.chapterTitle,
            text: deleted.text, colorHex: deleted.colorHex, source: "wechat_read",
            wechatBookId: deleted.wechatBookId, wechatBookmarkId: deleted.wechatBookmarkId)
        vm.applyWeChatSyncResult([recreatedRemote], baseline: [])
        XCTAssertFalse(database.loadHighlights().contains { $0.wechatBookmarkId == deleted.wechatBookmarkId })
    }

    func testIndependentReviewsAndIdenticalQuotesKeepDistinctRemoteIdentities() throws {
        let service = WeChatReadingService(loadPreferences: false)
        let notebook = WeChatNotebookItem(bookId: "book", book: WeChatBookMeta(title: "测试书", author: "作者",
            cover: nil, version: nil, format: nil), reviewCount: 2, noteCount: 0, bookmarkCount: 0,
            readingProgress: nil, markedStatus: nil, sort: nil)
        let reviews = ["一", "二"].enumerated().map { index, text in
            WeChatReviewItem(reviewId: "review-\(index)", content: text, abstract: nil, range: nil,
                chapterUid: nil, chapterIdx: nil, chapterName: nil, createTime: 100, star: nil, isFinish: nil)
        }
        let converted = service.convertToDReaderHighlights(notebook: notebook, bookmarks: [], chapters: [],
            reviews: reviews, matchingLocalBook: nil)
        let merged = WeChatReadingService.mergeHighlights(converted, into: [])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.compactMap(\.note)), ["一", "二"])
        XCTAssertEqual(WeChatReadingService.mergeHighlights(converted, into: merged).count, 2)
        let otherNotebook = WeChatNotebookItem(bookId: "another-book", book: notebook.book,
            reviewCount: 2, noteCount: 0, bookmarkCount: 0, readingProgress: nil, markedStatus: nil, sort: nil)
        let otherBook = service.convertToDReaderHighlights(notebook: otherNotebook, bookmarks: [], chapters: [],
            reviews: reviews, matchingLocalBook: nil)
        XCTAssertEqual(WeChatReadingService.mergeHighlights(otherBook, into: merged).count, 4)
        XCTAssertEqual(Set((merged + otherBook).map(\.id)).count, 4)
    }

    func testSameRemoteIdentityRetainsExistingLocalUUID() throws {
        let local = remote(note: "保留的想法")
        let sameRemote = remote()
        let merged = WeChatReadingService.mergeHighlights([sameRemote], into: [local])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, local.id)
        XCTAssertEqual(merged.first?.note, "保留的想法")
    }

    func testDeletedBookmarksStayDeletedAfterDatabaseReopenAndBackup() throws {
        let book = makeBook("书签书")
        var vm: ReaderViewModel? = ReaderViewModel(loadLibrary: false, database: database)
        vm?.currentBook = book
        vm?.toggleCurrentChapterBookmark()
        XCTAssertEqual(database.loadBookmarks().count, 1)
        vm?.toggleCurrentChapterBookmark()
        XCTAssertTrue(database.loadBookmarks().isEmpty)
        vm?.toggleCurrentChapterBookmark()
        let id = try XCTUnwrap(vm?.bookmarks.first?.id)
        vm?.deleteBookmark(id: id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertTrue(try decoder.decode(LibraryDatabase.BackupPayload.self, from: database.exportBackup()).bookmarks.isEmpty)
        vm = nil
        database = nil
        database = makeDatabase()
        XCTAssertTrue(ReaderViewModel(loadLibrary: false, database: database).bookmarks.isEmpty)
    }

    func testEmptyMigratedLibraryDoesNotRestoreLegacyHighlightsOrBookmarks() throws {
        database = nil
        let legacy = remote()
        let book = makeBook("旧书")
        let bookmark = Bookmark(bookId: book.id, bookTitle: book.title, chapterIndex: 0,
            chapterTitle: "第一章", scrollProgress: 0.5)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "dreader.highlights")
        defaults.set(try JSONEncoder().encode([bookmark]), forKey: "dreader.bookmarks")
        database = makeDatabase()
        var vm: ReaderViewModel? = ReaderViewModel(loadLibrary: false, database: database)
        XCTAssertEqual(vm?.highlights.count, 1)
        XCTAssertEqual(vm?.bookmarks.count, 1)
        vm?.deleteHighlight(legacy.id)
        vm?.deleteBookmark(id: bookmark.id)
        vm = nil
        database = nil
        database = makeDatabase()
        let reopened = ReaderViewModel(loadLibrary: false, database: database)
        XCTAssertTrue(reopened.highlights.isEmpty)
        XCTAssertTrue(reopened.bookmarks.isEmpty)
        // 旧 JSON 仍保留，但不能绕过数据库的迁移标记回填空库。
        XCTAssertNotNil(defaults.data(forKey: "dreader.highlights"))
        XCTAssertTrue(defaults.bool(forKey: "dreader.librarydb.migrated.v1"))
    }

    func testSameFilenameImportsKeepBothPersistentPayloadsAndScanAfterRestart() throws {
        let first = directory.appendingPathComponent("first/book.epub")
        let second = directory.appendingPathComponent("second/book.epub")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("first archive fixture".utf8).write(to: first)
        try Data("second archive fixture".utf8).write(to: second)
        let base = directory.appendingPathComponent("library")
        let shelf = base.appendingPathComponent("DownloadedBooks")
        let storedFirst = try ReaderViewModel.persistShelfCopy(for: first, shelfDirectory: shelf)
        let storedSecond = try ReaderViewModel.persistShelfCopy(for: second, shelfDirectory: shelf)
        XCTAssertNotEqual(storedFirst, storedSecond)
        XCTAssertEqual(storedFirst.lastPathComponent, "book.epub")
        XCTAssertEqual(storedSecond.lastPathComponent, "book.epub")
        XCTAssertEqual(try Data(contentsOf: storedFirst), try Data(contentsOf: first))
        XCTAssertEqual(try Data(contentsOf: storedSecond), try Data(contentsOf: second))
        XCTAssertEqual(try ReaderViewModel.persistShelfCopy(for: second, shelfDirectory: shelf), storedSecond)
        let restored = ReaderViewModel.persistedLibraryEPUBs(baseDirectory: base)
        XCTAssertEqual(Set(restored.map { $0.resolvingSymlinksInPath().path }),
            Set([storedFirst, storedSecond].map { $0.resolvingSymlinksInPath().path }))
    }

    func testColorOnlyEditStillReceivesCloudNoteAfterDatabaseReopen() throws {
        var server = remote(note: "云端想法一")
        server.isNoteLocallyEdited = false
        server.isColorLocallyEdited = false
        database.upsertHighlights([server])
        var vm: ReaderViewModel? = ReaderViewModel(loadLibrary: false, database: database)
        vm?.updateHighlight(id: server.id, colorHex: "#A5D8FF")
        vm = nil
        database = nil
        database = makeDatabase()
        let reopened = ReaderViewModel(loadLibrary: false, database: database)
        server.note = "云端想法二"
        server.colorHex = "#FFC9C9"
        reopened.applyWeChatSyncResult([server], baseline: reopened.highlights)
        let stored = try XCTUnwrap(database.loadHighlights().first)
        XCTAssertEqual(stored.note, "云端想法二")
        XCTAssertEqual(stored.colorHex, "#A5D8FF")
        XCTAssertEqual(stored.isNoteLocallyEdited, false)
        XCTAssertEqual(stored.isColorLocallyEdited, true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LibraryDatabase.BackupPayload.self, from: database.exportBackup())
        XCTAssertEqual(backup.highlights.first?.isColorLocallyEdited, true)
        XCTAssertEqual(backup.highlights.first?.isNoteLocallyEdited, false)
    }

    func testExistingSQLiteSchemaAndLegacyJSONKeepLocalNoteProtection() throws {
        database = nil
        let legacyURL = directory.appendingPathComponent("legacy.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacyURL.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TABLE highlights (
                id TEXT PRIMARY KEY, book_id TEXT NOT NULL, book_title TEXT NOT NULL DEFAULT '',
                chapter_index INTEGER NOT NULL DEFAULT 0, chapter_title TEXT NOT NULL DEFAULT '',
                text TEXT NOT NULL DEFAULT '', color_hex TEXT NOT NULL DEFAULT '#FFE066',
                created_at REAL NOT NULL DEFAULT 0, note TEXT, updated_at REAL, source TEXT,
                wechat_book_id TEXT, wechat_bookmark_id TEXT, wechat_author TEXT
            );
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        database = LibraryDatabase(databaseURL: legacyURL, preferences: defaults)
        var local = remote(note: "旧版已编辑的想法")
        local.updatedAt = Date(timeIntervalSince1970: 200)
        let json = try JSONEncoder().encode(local)
        local = try JSONDecoder().decode(Highlight.self, from: json)
        XCTAssertNil(local.isNoteLocallyEdited)
        database.upsertHighlights([local])
        let vm = ReaderViewModel(loadLibrary: false, database: database)
        vm.applyWeChatSyncResult([remote()], baseline: vm.highlights)
        let stored = try XCTUnwrap(database.loadHighlights().first)
        XCTAssertEqual(stored.note, "旧版已编辑的想法")
        XCTAssertEqual(stored.isNoteLocallyEdited, true)
        XCTAssertEqual(stored.isColorLocallyEdited, true)
    }

    func testAIAnswerKeepsRepeatedSpineOccurrence() throws {
        let first = makeBook("重复章节")
        let chapter = try XCTUnwrap(first.chapters.first)
        let repeated = EPUBChapter(id: chapter.id, title: "再次出现", fileURL: chapter.fileURL, orderIndex: 1)
        let book = EPUBBook(title: first.title, fileURL: first.fileURL, unzippedDirectory: directory,
            opfDirectory: directory, chapters: [chapter, repeated], currentChapterIndex: 1)
        let source = try XCTUnwrap(AINoteSource(book: book, chapter: book.currentChapter))
        XCTAssertEqual(source.chapterIndex, 1)
        XCTAssertEqual(source.chapterTitle, "再次出现")
        let vm = ReaderViewModel(loadLibrary: false, database: database)
        vm.saveAIMessageAsNote(ChatMessage(role: .assistant, content: "第二个章节位置的回答", noteSource: source))
        XCTAssertEqual(database.loadHighlights().first?.chapterIndex, 1)
    }

    func testSavingOldAIAnswerUsesCapturedSourceAfterBookAndChapterChange() throws {
        let original = makeBook("原书")
        let source = try XCTUnwrap(AINoteSource(book: original, chapter: original.currentChapter))
        let answer = ChatMessage(role: .assistant, content: "原书的解读", noteSource: source)
        let vm = ReaderViewModel(loadLibrary: false, database: database)
        vm.currentBook = makeBook("新书")
        vm.saveAIMessageAsNote(answer)
        let saved = try XCTUnwrap(database.loadHighlights().first)
        XCTAssertEqual(saved.bookId, original.id)
        XCTAssertEqual(saved.bookTitle, "原书")
        XCTAssertEqual(saved.chapterTitle, original.currentChapter?.title)
        XCTAssertEqual(saved.note, "原书的解读")
        vm.saveAIMessageAsNote(ChatMessage(role: .assistant, content: "没有来源"))
        XCTAssertEqual(database.loadHighlights().count, 1)
    }
}
