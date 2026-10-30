import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import DReader

/// 使用真实 EPUB 和生产视图，不依赖系统截图或辅助功能权限。
@MainActor
final class ResumeAcceptanceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var database: LibraryDatabase!
    private var originalStats: ReadingStats!
    private var window: NSWindow?
    private var webView: WKWebView?
    private var coordinator: EPUBWebView.Coordinator?
    private var vm: ReaderViewModel?

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dreader-resume-acceptance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "dreader-resume-acceptance-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        database = LibraryDatabase(databaseURL: root.appendingPathComponent("library.sqlite"), preferences: defaults)
        originalStats = ReadingStatsManager.shared.stats
    }

    override func tearDown() async throws {
        webView?.stopLoading()
        window?.close()
        webView = nil
        coordinator = nil
        vm?.stopChapterReadAloud()
        vm = nil
        ReadingStatsManager.shared.stats = originalStats
        ReadingStatsManager.shared.pauseSession()
        database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService() -> ChapterReadAloudService {
        ChapterReadAloudService(preferredEngine: .qwen, synthesizeAudio: { _, _, _ in
            Data("fixture audio".utf8)
        }, makePlayback: { _, _ in
            .init(play: { true }, pause: {}, stop: {})
        })
    }

    private func waitUntil(_ predicate: () async -> Bool, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "ResumeAcceptance", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "等待真实阅读/听书状态超时"])
    }

    private struct JSValue: @unchecked Sendable {
        let value: Any?
    }

    private func evaluate(_ script: String) async throws -> Any? {
        let result: JSValue = try await withCheckedThrowingContinuation { continuation in
            webView?.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: JSValue(value: result)) }
            }
        }
        return result.value
    }

    func testRealEPUBReadingAndListeningResume() async throws {
        let source = URL(fileURLWithPath: "/Users/davirian/Library/Application Support/DReader/DownloadedBooks/天幕红尘 (豆豆 [豆豆]) (z-library.sk, 1lib.sk, z-lib.sk).epub")
        let parser = EPUBParser(cacheRoot: root.appendingPathComponent("cache"),
                                identityRoot: root.appendingPathComponent("identity"))
        let book = try await parser.parse(fileURL: source)
        XCTAssertGreaterThan(book.chapters.count, 2)
        let targetIndex = book.chapters.firstIndex(where: { chapter in
            guard let html = EPUBWebView.Coordinator.readTextSmart(chapter.fileURL) else { return false }
            return html.contains("<p") && html.utf8.count > 10_000
        }) ?? 1
        database.saveReadingPosition(.init(bookId: book.id, chapterIndex: targetIndex,
                                            scrollProgress: 0.45, updatedAt: Date()))

        let viewModel = ReaderViewModel(loadLibrary: false, database: database, readAloud: makeService())
        vm = viewModel
        viewModel.currentBook = book
        viewModel.selectBookForReading(book)
        XCTAssertEqual(viewModel.currentBook?.currentChapterIndex, targetIndex)
        XCTAssertEqual(viewModel.readAloud.state, .idle)

        let reader = EPUBWebView(
            chapterURL: book.currentChapter!.fileURL,
            opfDirectory: book.opfDirectory,
            unzippedDirectory: book.unzippedDirectory,
            highlights: [], bookTitle: book.title,
            chapterTitle: book.currentChapter!.title,
            chapterIndex: book.currentChapterIndex,
            hasNextChapter: true, nextChapterTitle: "下一章",
            settings: viewModel.settings,
            selectionManager: viewModel.selectionManager,
            onHighlightApplied: nil,
            onNextChapter: {}, onPrevChapter: {},
            onChapterReady: { url, index in viewModel.chapterDidBecomeReady(url, chapterIndex: index) },
            onScrollProgress: { progress in viewModel.noteChapterScrollProgress(progress) },
            registerScrollAction: { action in viewModel.scrollPageAction = action },
            registerScrollToProgressAction: { action in viewModel.scrollToReadingProgressAction = action },
            registerHighlightAction: { _ in }, registerUpdateColorAction: { _ in },
            registerUpdateThoughtAction: { _ in }, registerRemoveHighlightAction: { _ in },
            registerScrollToReadAloudSegmentAction: { action in viewModel.scrollToReadAloudSegmentAction = action },
            registerReadAloudSegmentsAction: { action in viewModel.readAloudSegmentsProvider = action },
            getCachedHTML: { url in viewModel.getCachedHTML(for: url) },
            cacheHTML: { html, url in viewModel.cacheHTML(html, for: url) }
        )
        let coordinator = reader.makeCoordinator()
        self.coordinator = coordinator
        viewModel.scrollToReadingProgressAction = { progress in coordinator.scrollToProgress(progress) }
        viewModel.readAloudSegmentsProvider = { try await coordinator.readAloudSegments() }
        viewModel.scrollToReadAloudSegmentAction = { id in coordinator.scrollToReadAloudSegment(id: id) }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "selectionBridge")
        configuration.userContentController.addUserScript(WKUserScript(
            source: EPUBThemeInjector.generateJS(), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        self.webView = webView
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(webView)
        window.orderFront(nil)
        self.window = window
        coordinator.loadChapter(url: book.currentChapter!.fileURL, opfDir: book.opfDirectory,
                                unzippedDir: book.unzippedDirectory, settings: viewModel.settings,
                                hasNextChapter: true, nextChapterTitle: "下一章")
        try await waitUntil {
            (try? await evaluate("window.dreaderReaderReady === true") as? Bool) == true
        }
        try await waitUntil {
            guard let metrics = try? await evaluate("window.dreaderScrollMetrics()") as? [String: Any],
                  let current = metrics["currentScroll"] as? Double,
                  let maximum = metrics["maxScroll"] as? Double, maximum > 0 else { return false }
            return abs(current / maximum - 0.45) < 0.03
        }
        XCTAssertEqual(viewModel.currentBook?.currentChapterIndex, targetIndex)

        let bitmap = try XCTUnwrap(webView.bitmapImageRepForCachingDisplay(in: webView.bounds))
        webView.cacheDisplay(in: webView.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/Users/davirian/dreader/.build/position-resume-validation/真实阅读恢复.png"))

        let segments = try await coordinator.readAloudSegments()
        XCTAssertFalse(segments.isEmpty)
        let selected = segments.first(where: { QwenTextChunker.chunks(for: $0.text).count > 1 }) ?? segments[0]
        let chunks = QwenTextChunker.chunks(for: selected.text)
        let chunkIndex = min(1, chunks.count - 1)
        database.saveListeningPosition(.init(
            bookId: book.id, chapterIndex: targetIndex, segmentID: selected.id,
            chunkIndex: chunkIndex, chunkText: chunks[chunkIndex], updatedAt: Date()
        ))
        viewModel.toggleChapterReadAloud()
        try await waitUntil { !viewModel.readAloud.isPreparing && viewModel.readAloud.state == .playing }
        XCTAssertEqual(viewModel.readAloud.currentSegmentID, selected.id)
        XCTAssertEqual(database.listeningPosition(for: book.id)?.chunkIndex, chunkIndex)
        viewModel.stopChapterReadAloud()
        XCTAssertNotNil(database.listeningPosition(for: book.id))

        viewModel.selectBookForReading(book)
        XCTAssertEqual(viewModel.readAloud.state, .idle, "重新打开书不能自动播放")
        viewModel.toggleChapterReadAloud()
        try await waitUntil { !viewModel.readAloud.isPreparing && viewModel.readAloud.state == .playing }
        XCTAssertEqual(viewModel.readAloud.currentSegmentID, selected.id)
        XCTAssertEqual(database.listeningPosition(for: book.id)?.chunkIndex, chunkIndex)
        viewModel.stopChapterReadAloud()
    }
}
