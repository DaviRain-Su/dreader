import AppKit
import XCTest
@testable import DReader

@MainActor
final class LibraryRegressionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dreader-library-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBook(name: String = "book.epub", title: String = "测试书", lengths: [Int] = []) throws -> EPUBBook {
        let chapters = try lengths.enumerated().map { index, count in
            let url = directory.appendingPathComponent("\(name)-\(index).xhtml")
            try String(repeating: "字", count: count).write(to: url, atomically: true, encoding: .utf8)
            return EPUBChapter(id: "\(index)", title: "第\(index)章", fileURL: url, orderIndex: index)
        }
        return EPUBBook(title: title, fileURL: directory.appendingPathComponent(name),
                        unzippedDirectory: directory, opfDirectory: directory, chapters: chapters)
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "DReaderLibraryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待后台状态超时"])
    }

    func testRestoreUsesSourceOrderForDuplicateTitlesAndFilenames() throws {
        let newest = try makeBook(name: "new.epub", title: "同名书")
        let older = try makeBook(name: "old.epub", title: "同名书")
        var duplicateFilename = try makeBook(name: "other.epub", title: "另一书")
        duplicateFilename.fileURL = directory.appendingPathComponent("DownloadedBooks/new.epub")
        let ordered = ReaderViewModel.orderedRestoredBooks([older, duplicateFilename, newest], sourceURLs: [newest.fileURL, duplicateFilename.fileURL, older.fileURL])
        XCTAssertEqual(ordered.map(\.id), [newest.id, duplicateFilename.id])
    }

    func testEveryBackgroundCountUpdatesRemainingTimeAndSurvivesChapterChange() async throws {
        let book = try makeBook(lengths: [400, 800, 1200, 1600])
        let vm = ReaderViewModel(loadLibrary: false)
        vm.currentBook = book
        vm.updateSubsequentChaptersTotalChars()
        try await waitUntil { vm.bookRemainingTimeFormatted() == "全书剩约 10 分钟" }
        vm.jumpToChapter(1)
        try await waitUntil { vm.bookRemainingTimeFormatted() == "全书剩约 9 分钟" }
        XCTAssertEqual(vm.currentChapterCharCount(), 800)
    }

    func testLegacyEncodedChapterUsesSmartDecoderForCounts() async throws {
        let book = try makeBook(lengths: [1])
        let url = book.chapters[0].fileURL
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = try XCTUnwrap(String(repeating: "中文", count: 300).data(using: String.Encoding(rawValue: gbk)))
        try data.write(to: url)
        let vm = ReaderViewModel(loadLibrary: false)
        vm.currentBook = book
        vm.updateSubsequentChaptersTotalChars()
        try await waitUntil { vm.currentChapterCharCount() == 600 }
    }

    func testPreloadingKeepsReadyBookIndex() async throws {
        let book = try makeBook(lengths: [20])
        let service = BookIndexService.shared
        service.ensureIndexBuilt(for: book) { _ in "<p>索引回归测试需要保留全书上下文。</p>" }
        try await waitUntil { service.isIndexReady(for: book.id) }
        let vm = ReaderViewModel(loadLibrary: false)
        vm.currentBook = book
        vm.preloadAllChapters(for: book)
        try await waitUntil { vm.getCachedHTML(for: book.chapters[0].fileURL) != nil }
        XCTAssertTrue(service.isIndexReady(for: book.id))
        service.invalidateIndex(for: book.id)
    }

    func testNavigationWaitsForMatchingChapterReady() async throws {
        let book = try makeBook(lengths: [100, 200])
        let vm = ReaderViewModel(loadLibrary: false)
        vm.currentBook = book
        vm.chapterDidBecomeReady(book.chapters[0].fileURL)
        var jumpedHighlight: String?
        vm.scrollToHighlightAction = { jumpedHighlight = $0 }
        let highlight = Highlight(bookId: book.id, chapterIndex: 1, chapterTitle: "目标章", text: "标注")
        vm.jumpToHighlight(highlight)
        XCTAssertNil(jumpedHighlight)
        vm.chapterDidBecomeReady(book.chapters[0].fileURL)
        XCTAssertNil(jumpedHighlight)
        vm.chapterDidBecomeReady(book.chapters[1].fileURL)
        XCTAssertEqual(jumpedHighlight, highlight.id.uuidString)

        var jumpedSearch: String?
        vm.scrollToSearchMatchAction = { keyword, _ in jumpedSearch = keyword }
        let result = SearchResultItem(chapterIndex: 0, chapterTitle: "首章", snippetBefore: "", keyword: "目标词", snippetAfter: "", matchIndexInChapter: 0)
        vm.jumpToSearchResult(result)
        XCTAssertNil(jumpedSearch)
        vm.chapterDidBecomeReady(book.chapters[0].fileURL)
        XCTAssertEqual(jumpedSearch, "目标词")
    }

    func testReadAloudWaitsForMatchingChapterAndCancelsStalePreparation() async throws {
        let book = try makeBook(lengths: [100, 200])
        let vm = ReaderViewModel(loadLibrary: false)
        vm.currentBook = book
        var requests = 0
        vm.readAloudSegmentsProvider = {
            requests += 1
            try await Task.sleep(for: .seconds(10))
            return []
        }
        vm.startChapterReadAloud()
        XCTAssertEqual(requests, 0, "章节尚未就绪时不应读取旧 DOM")
        vm.chapterDidBecomeReady(book.chapters[0].fileURL)
        try await waitUntil { requests == 1 }
        vm.jumpToChapter(1)
        vm.chapterDidBecomeReady(book.chapters[0].fileURL)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(requests, 1, "迟到的旧章节回调不能重新启动朗读")
        XCTAssertEqual(vm.readAloud.state, .idle)
        vm.stopChapterReadAloud()
    }

    func testCrossBookSearchKeepsQueryStateInSync() {
        let vm = ReaderViewModel(loadLibrary: false)
        vm.performCrossBookSearch(query: "目标词")
        XCTAssertEqual(vm.searchQuery, "目标词")
        vm.performCrossBookSearch(query: "")
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertTrue(vm.crossBookGroups.isEmpty)
        XCTAssertFalse(vm.isCrossBookSearching)
    }

    func testSearchTextDecodesEntitiesAndSkipsRubyWithoutSplittingInlineWords() {
        let html = "<p>数字&#20013;&#25991;与<ruby>重庆<rt>chóng qìng</rt></ruby>。</p><p>这是<strong>强调</strong>的完整正文。</p><script>关键词不应计入</script>"
        XCTAssertEqual(stripHTMLTags(from: html), "数字中文与重庆。 这是强调的完整正文。")
    }

    func testCoalescedCoverRequestsNotifyAllConsumersWithThumbnail() async throws {
        let file = directory.appendingPathComponent("cover.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 1800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let completed = expectation(description: "全部封面消费者收到回调")
        completed.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            CoverImageCache.shared.loadImage(for: file) { image in
                XCTAssertNotNil(image)
                XCTAssertLessThanOrEqual(max(image?.size.width ?? 0, image?.size.height ?? 0), 512)
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertNotNil(CoverImageCache.shared.cachedImage(for: file))
    }
}
