import XCTest
@testable import DReader

@MainActor
final class PositionPersistenceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var database: LibraryDatabase!
    private var originalStats: ReadingStats!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dreader-positions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "dreader-positions-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        database = LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"), preferences: defaults)
        originalStats = ReadingStatsManager.shared.stats
    }

    override func tearDown() async throws {
        ReadingStatsManager.shared.stats = originalStats
        ReadingStatsManager.shared.pauseSession()
        database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBook(id: UUID = UUID(), repeatedURL: Bool = false) -> EPUBBook {
        let shared = directory.appendingPathComponent("shared.xhtml")
        let chapters = (0..<3).map { index in
            EPUBChapter(id: repeatedURL ? "same" : "chapter-\(index)", title: "第\(index + 1)章",
                        fileURL: repeatedURL ? shared : directory.appendingPathComponent("chapter-\(index).xhtml"),
                        orderIndex: index)
        }
        return EPUBBook(id: id, title: "续接测试书", author: "测试作者",
                        fileURL: directory.appendingPathComponent("book.epub"),
                        unzippedDirectory: directory, opfDirectory: directory, chapters: chapters)
    }

    private func makeService() -> ChapterReadAloudService {
        ChapterReadAloudService(preferredEngine: .qwen, synthesizeAudio: { _, _, _ in
            Data("fixture audio".utf8)
        }, makePlayback: { _, _ in
            .init(play: { true }, pause: {}, stop: {})
        })
    }

    private func makeVM(book: EPUBBook) -> ReaderViewModel {
        let vm = ReaderViewModel(loadLibrary: false, database: database, readAloud: makeService())
        vm.currentBook = book
        return vm
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "PositionPersistenceTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "等待续接状态超时"])
    }

    func testPositionTablesRoundTripAndBackupCompatibility() throws {
        let bookId = UUID()
        database.saveReadingPosition(.init(bookId: bookId, chapterIndex: 2, scrollProgress: 0.55, updatedAt: Date()))
        database.saveListeningPosition(.init(bookId: bookId, chapterIndex: 2, segmentID: 4,
                                              chunkIndex: 1, chunkText: "第二个短块", updatedAt: Date()))
        XCTAssertEqual(database.readingPosition(for: bookId)?.scrollProgress, 0.55)
        XCTAssertEqual(database.listeningPosition(for: bookId)?.chunkIndex, 1)

        let backup = try database.exportBackup()
        let payload = try JSONDecoder().decode(LibraryDatabase.BackupPayload.self, from: backup)
        XCTAssertEqual(payload.readingPositions.count, 1)
        XCTAssertEqual(payload.listeningPositions.count, 1)
        let reopened = LibraryDatabase(databaseURL: directory.appendingPathComponent("reopened.sqlite"), preferences: defaults)
        _ = try reopened.importBackup(backup)
        XCTAssertEqual(reopened.readingPosition(for: bookId)?.chapterIndex, 2)
        XCTAssertEqual(reopened.listeningPosition(for: bookId)?.chunkText, "第二个短块")

        database.saveReadingPosition(.init(bookId: bookId, chapterIndex: 2, scrollProgress: 0, updatedAt: Date()))
        XCTAssertNotNil(database.readingPosition(for: bookId))
        XCTAssertEqual(database.readingPosition(for: bookId)?.scrollProgress, 0)
        XCTAssertNil(database.readingPosition(for: UUID()))
        database.deletePositions(for: bookId)
        XCTAssertNil(database.readingPosition(for: bookId))
        XCTAssertNil(database.listeningPosition(for: bookId))

        let oldJSON = try JSONSerialization.data(withJSONObject: ["version": 1, "highlights": [], "bookmarks": []])
        let oldPayload = try JSONDecoder().decode(LibraryDatabase.BackupPayload.self, from: oldJSON)
        XCTAssertTrue(oldPayload.readingPositions.isEmpty)
        XCTAssertTrue(oldPayload.listeningPositions.isEmpty)
    }

    func testSelectBookRestoresReadingWithoutAutoPlaying() {
        let book = makeBook()
        database.saveReadingPosition(.init(bookId: book.id, chapterIndex: 1, scrollProgress: 0.55, updatedAt: Date()))
        database.saveListeningPosition(.init(bookId: book.id, chapterIndex: 2, segmentID: 3,
                                              chunkIndex: 0, chunkText: "听书位置", updatedAt: Date()))
        let vm = makeVM(book: book)
        vm.selectBookForReading(book)
        XCTAssertEqual(vm.currentBook?.currentChapterIndex, 1)
        XCTAssertEqual(vm.chapterScrollProgress, 0.55)
        XCTAssertEqual(vm.readAloud.state, .idle)
        XCTAssertTrue(vm.hasListeningResume)

        var restored: Double?
        vm.scrollToReadingProgressAction = { restored = $0 }
        vm.chapterDidBecomeReady(book.chapters[1].fileURL, chapterIndex: 1)
        XCTAssertEqual(restored, 0.55)
        vm.stopChapterReadAloud()
    }

    func testRepeatedURLReadyRequiresMatchingOccurrence() {
        let book = makeBook(repeatedURL: true)
        database.saveReadingPosition(.init(bookId: book.id, chapterIndex: 1, scrollProgress: 0.65, updatedAt: Date()))
        let vm = makeVM(book: book)
        vm.selectBookForReading(book)
        var restored: Double?
        vm.scrollToReadingProgressAction = { restored = $0 }
        vm.chapterDidBecomeReady(book.chapters[0].fileURL, chapterIndex: 0)
        XCTAssertNil(restored)
        vm.chapterDidBecomeReady(book.chapters[1].fileURL, chapterIndex: 1)
        XCTAssertEqual(restored, 0.65)
        vm.stopChapterReadAloud()
    }

    func testChapterNavigationAndResetPersistCorrectStates() {
        let book = makeBook()
        let vm = makeVM(book: book)
        vm.selectBookForReading(book)
        vm.chapterDidBecomeReady(book.chapters[0].fileURL, chapterIndex: 0)
        vm.noteChapterScrollProgress(0.42)
        vm.nextChapter()
        XCTAssertEqual(vm.currentBook?.currentChapterIndex, 1)
        XCTAssertEqual(database.readingPosition(for: book.id)?.scrollProgress, 0)
        vm.prevChapter()
        XCTAssertEqual(database.readingPosition(for: book.id)?.chapterIndex, 0)
        XCTAssertEqual(database.readingPosition(for: book.id)?.scrollProgress, 0)

        database.saveListeningPosition(.init(bookId: book.id, chapterIndex: 1, segmentID: 2,
                                              chunkIndex: 0, chunkText: "旧听书", updatedAt: Date()))
        vm.resetBookProgress(id: book.id)
        XCTAssertNil(database.readingPosition(for: book.id))
        XCTAssertNil(database.listeningPosition(for: book.id))
        XCTAssertFalse(vm.hasListeningResume)
    }

    func testResumeUsesSecondChunkWithSameDOMID() async throws {
        let book = makeBook()
        let text = String(repeating: "这是一个用于验证准确续听位置的长句子，包含足够多的中文内容。", count: 20)
        let chunks = QwenTextChunker.chunks(for: text)
        XCTAssertGreaterThan(chunks.count, 1)
        database.saveListeningPosition(.init(bookId: book.id, chapterIndex: 0, segmentID: 8,
                                              chunkIndex: 1, chunkText: chunks[1], updatedAt: Date()))
        let vm = makeVM(book: book)
        vm.readAloudSegmentsProvider = { [.init(id: 8, text: text)] }
        vm.selectBookForReading(book)
        XCTAssertEqual(vm.readAloud.state, .idle)
        vm.toggleChapterReadAloud()
        vm.chapterDidBecomeReady(book.chapters[0].fileURL, chapterIndex: 0)
        try await waitUntil { !vm.readAloud.isPreparing && vm.readAloud.state == .playing }
        let saved = database.listeningPosition(for: book.id)
        XCTAssertEqual(saved?.chunkIndex, 1)
        XCTAssertEqual(saved?.chunkText, chunks[1])
        XCTAssertEqual(vm.readAloud.currentSegmentID, 8)
        vm.stopChapterReadAloud()
    }

    func testCrossChapterResumePreservesReadingPosition() async throws {
        let book = makeBook()
        let text = String(repeating: "跨章续听也要回到同一个短块，而不是从头开始。", count: 18)
        let chunks = QwenTextChunker.chunks(for: text)
        database.saveReadingPosition(.init(bookId: book.id, chapterIndex: 0, scrollProgress: 0.35, updatedAt: Date()))
        database.saveListeningPosition(.init(bookId: book.id, chapterIndex: 1, segmentID: 6,
                                              chunkIndex: 1, chunkText: chunks[1], updatedAt: Date()))
        let vm = makeVM(book: book)
        vm.readAloudSegmentsProvider = { [.init(id: 6, text: text)] }
        vm.selectBookForReading(book)
        XCTAssertEqual(vm.currentBook?.currentChapterIndex, 0)
        vm.toggleChapterReadAloud()
        XCTAssertEqual(vm.currentBook?.currentChapterIndex, 1)
        XCTAssertEqual(vm.readAloud.state, .idle, "目标章 ready 前不能自动播放")
        vm.chapterDidBecomeReady(book.chapters[1].fileURL, chapterIndex: 1)
        try await waitUntil { !vm.readAloud.isPreparing && vm.readAloud.state == .playing }
        XCTAssertEqual(database.readingPosition(for: book.id)?.chapterIndex, 0)
        XCTAssertEqual(database.readingPosition(for: book.id)?.scrollProgress, 0.35)
        XCTAssertEqual(database.listeningPosition(for: book.id)?.chunkIndex, 1)
        vm.stopChapterReadAloud()
    }

    func testDeleteBookClearsBothPositionTables() {
        let book = makeBook()
        database.saveReadingPosition(.init(bookId: book.id, chapterIndex: 2, scrollProgress: 0.7, updatedAt: Date()))
        database.saveListeningPosition(.init(bookId: book.id, chapterIndex: 2, segmentID: 4,
                                              chunkIndex: 0, chunkText: "旧位置", updatedAt: Date()))
        let vm = makeVM(book: book)
        vm.removeBook(id: book.id)
        XCTAssertNil(database.readingPosition(for: book.id))
        XCTAssertNil(database.listeningPosition(for: book.id))
    }
}
