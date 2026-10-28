import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import DReader

@MainActor
final class ReaderInteractionTests: XCTestCase {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var coordinator: EPUBWebView.Coordinator!
    private var selection: ReaderSelectionManager!
    private var settings: ReaderSettings!
    private var directory: URL!
    private var nextCount = 0
    private var previousCount = 0
    private var keyboardActions: [Bool] = []
    private var scrollProgress: Double = 0
    private var savedPreferences: [String: Any] = [:]
    private let preferenceKeys = ["dreader.chinese_script_mode", "dreader.line_guide_enabled", "dreader.page_turn_animation"]

    override func setUp() async throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("dreader-interactions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for key in preferenceKeys {
            savedPreferences[key] = UserDefaults.standard.object(forKey: key)
        }
        settings = ReaderSettings()
        settings.chineseScriptMode = .original
        settings.isLineGuide = false
        settings.isPageTurnAnimation = false
        selection = ReaderSelectionManager()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let reader = makeReader(file: directory.appendingPathComponent("first.xhtml"))
        coordinator = reader.makeCoordinator()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator!, name: "selectionBridge")
        configuration.userContentController.addUserScript(WKUserScript(
            source: EPUBThemeInjector.generateJS(), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        window.contentView?.addSubview(webView)
        window.orderFront(nil)
    }

    override func tearDown() async throws {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "selectionBridge")
        window?.close()
        webView = nil
        coordinator = nil
        window = nil
        try? FileManager.default.removeItem(at: directory)
        for key in preferenceKeys {
            if let value = savedPreferences[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedPreferences.removeAll()
    }

    private func makeReader(file: URL, index: Int = 0, highlights: [Highlight] = [],
                            opfDir: URL? = nil, unzippedDir: URL? = nil) -> EPUBWebView {
        EPUBWebView(
            chapterURL: file, opfDirectory: opfDir ?? directory, unzippedDirectory: unzippedDir ?? directory,
            highlights: highlights, bookTitle: "交互回归测试", chapterTitle: "第\(index + 1)章",
            chapterIndex: index, hasNextChapter: true, nextChapterTitle: "下一章",
            settings: settings, selectionManager: selection, onHighlightApplied: nil,
            onNextChapter: { self.nextCount += 1 }, onPrevChapter: { self.previousCount += 1 },
            onKeyboardAnnotate: { self.keyboardActions.append($0) }, onScrollProgress: { self.scrollProgress = $0 },
            registerScrollAction: { _ in }, registerHighlightAction: { _ in },
            registerUpdateColorAction: { _ in }, registerUpdateThoughtAction: { _ in },
            registerRemoveHighlightAction: { _ in }, getCachedHTML: { _ in nil }, cacheHTML: { _, _ in })
    }

    private struct JavaScriptValue: @unchecked Sendable {
        let value: Any?
    }

    private func evaluate(_ script: String) async throws -> Any? {
        let result: JavaScriptValue = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: JavaScriptValue(value: value)) }
            }
        }
        return result.value
    }

    private func waitUntil(_ script: String, timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await evaluate(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        let state = try? await evaluate("JSON.stringify({ready:window.dreaderReaderReady,state:document.readyState,bodyLength:document.body?.innerHTML.length,container:!!document.getElementById('dreader-chapter-body'),marker:document.getElementById('dreader-regression-marker')?.dataset.token})")
        throw NSError(domain: "DReaderInteractionTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "等待页面条件超时：\(script)；页面：\(webView.url?.path ?? "nil")；加载中：\(webView.isLoading)；状态：\(state ?? "nil")"])
    }

    private func loadFixture(vertical: Bool = false, highlights: [Highlight] = []) async throws {
        settings.isVertical = vertical
        let paragraphs = (0..<120).map { "<p id='p\($0)'>第\($0)段。回归测试验证翻页、划线与笔记。阅读是一段需要耐心的旅程，正文应该随翻页平稳前进。</p>" }.joined()
        let html = "<html><head><meta charset='utf-8'></head><body>\(paragraphs)<p>跨标签<b>划线测试</b>文本。</p><p><a href='#fn1'>注释</a></p><aside id='fn1'>1. 脚注正文</aside></body></html>"
        let file = directory.appendingPathComponent("first.xhtml")
        try html.write(to: file, atomically: true, encoding: .utf8)
        coordinator.parent = makeReader(file: file, highlights: highlights)
        coordinator.loadChapter(url: file, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
        try await waitUntil("document.getElementById('p0') !== null && window.dreaderReaderReady === true")
        try await Task.sleep(for: .milliseconds(100))
    }

    func testReaderScriptRegistersEveryInteraction() async throws {
        try await loadFixture()
        let functions = ["dreaderScrollPage", "dreaderPageTurnPlan", "dreaderApplyHighlight",
                         "dreaderSetChapterContent", "dreaderRestoreHighlights", "dreaderScrollToSearchMatch",
                         "dreaderScrollToHighlight", "dreaderUpdateTranslation", "dreaderGoNextChapter"]
        for name in functions {
            let type = try await evaluate("typeof window.\(name)") as? String
            XCTAssertEqual(type, "function", "正文函数未注册：\(name)")
        }
    }

    func testHorizontalPageNavigationAndChapterButton() async throws {
        try await loadFixture()
        coordinator.scrollPage(direction: 1)
        try await waitUntil("window.scrollY > 100")
        coordinator.scrollPage(direction: -1)
        try await waitUntil("window.scrollY < 2")
        let before = nextCount
        _ = try await evaluate("document.querySelector('.dreader-end-btn').click(); true")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(nextCount, before + 1)
    }

    func testKeyboardChapterNavigationIsNotRegisteredTwice() async throws {
        try await loadFixture()
        _ = try await evaluate("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight', bubbles:true})); true")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(nextCount, 1, "一按右键只能翻一章；模板脚本和 WKUserScript 不应重复注册")
    }

    func testSelectionHighlightNotesAndDelete() async throws {
        try await loadFixture()
        _ = try await evaluate("""
            (() => {
                const range = document.createRange();
                range.selectNodeContents(document.getElementById('p0'));
                const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                document.dispatchEvent(new MouseEvent('mouseup', {bubbles:true}));
                return true;
            })()
            """)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(selection.activeSelection?.text.contains("第0段") == true)
        let applied = try await evaluate("window.dreaderApplyHighlight('#FFE066', 'test-highlight', '测试笔记')") as? Bool
        XCTAssertEqual(applied, true)
        let count = try await evaluate("document.querySelectorAll('mark[data-id=\"test-highlight\"]').length") as? Int
        XCTAssertEqual(count, 1)
        _ = try await evaluate("window.dreaderUpdateHighlightColor('test-highlight', '#A5D8FF'); window.dreaderUpdateHighlightThought('test-highlight', '更新笔记'); true")
        let color = try await evaluate("document.querySelector('mark[data-id=\"test-highlight\"]').getAttribute('data-color')") as? String
        XCTAssertEqual(color, "#A5D8FF")
        let note = try await evaluate("document.querySelectorAll('mark[data-id=\"test-highlight\"] .dreader-thought-dot').length") as? Int
        XCTAssertEqual(note, 1)
        _ = try await evaluate("window.dreaderRemoveHighlight('test-highlight'); true")
        let removed = try await evaluate("document.querySelector('mark[data-id=\"test-highlight\"]') === null && document.getElementById('p0').textContent.includes('第0段')") as? Bool
        XCTAssertEqual(removed, true)
    }

    func testRestoreHighlightAcrossInlineTagsAndSearch() async throws {
        try await loadFixture()
        _ = try await evaluate("window.dreaderRestoreHighlights([{id:'restored',text:'跨标签划线测试文本。',colorHex:'#FFE066',note:'笔记'}]); true")
        let restored = try await evaluate("document.querySelector('mark[data-id=\"restored\"]') !== null") as? Bool
        XCTAssertEqual(restored, true)
        let found = try await evaluate("window.dreaderScrollToSearchMatch('第60段', 0)") as? Bool
        XCTAssertEqual(found, true)
    }

    func testBookChapterLinkUsesNativeNavigation() async throws {
        try await loadFixture()
        try "<html><body>目标章节</body></html>".write(to: directory.appendingPathComponent("second.xhtml"), atomically: true, encoding: .utf8)
        var tapped: URL?
        coordinator.parent.onChapterLinkTapped = { url in
            tapped = url
            return true
        }
        _ = try await evaluate("""
            (() => {
                const link = document.createElement('a');
                link.href = 'second.xhtml'; link.textContent = '下一章';
                document.getElementById('dreader-chapter-body').appendChild(link);
                link.click(); return true;
            })()
            """)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(tapped?.lastPathComponent, "second.xhtml")
        let keptTemplate = try await evaluate("window.dreaderReaderReady === true && document.getElementById('p0') !== null") as? Bool
        XCTAssertEqual(keptTemplate, true, "书内链接必须转交原生换章，不能裸加载并丢失阅读环境")
    }

    func testColdLoadRestoresHighlightAcrossInlineTags() async throws {
        let highlight = Highlight(bookId: UUID(), chapterIndex: 0, chapterTitle: "测试章",
                                  text: "跨标签划线测试文本。", note: "已有笔记")
        try await loadFixture(highlights: [highlight])
        let restored = try await evaluate("document.querySelector('mark[data-id=\"\(highlight.id.uuidString)\"]') !== null") as? Bool
        XCTAssertEqual(restored, true, "重新打开章节时必须恢复跨标签的已有划线")
    }

    func testVerticalPageNavigationAndProgress() async throws {
        try await loadFixture(vertical: true)
        let initial = try await evaluate("JSON.stringify({x:scrollX,width:document.documentElement.scrollWidth,viewport:innerWidth,vertical:window.dreaderIsVertical()})")
        print("竖排初始布局：\(initial ?? "nil")")
        let plan = try await evaluate("window.dreaderPageTurnPlan(1)") as? [String: Any]
        XCTAssertEqual(plan?["willTurn"] as? Bool, true)
        coordinator.scrollPage(direction: 1)
        try await waitUntil("Math.abs(window.scrollX) > 50")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(nextCount, 0, "竖排第一页应滚动，不能跳到下一章")
        let metrics = try await evaluate("JSON.stringify({x:scrollX,root:document.scrollingElement.scrollLeft,metrics:window.dreaderScrollMetrics()})")
        print("竖排翻页后：\(metrics ?? "nil")，桥接进度：\(scrollProgress)")
        XCTAssertGreaterThan(scrollProgress, 0, "竖排进度不能一直是 0")
        coordinator.scrollPage(direction: -1)
        try await waitUntil("Math.abs(window.scrollX) < 2")
        XCTAssertEqual(previousCount, 0, "竖排后翻应回到章首，不能提前跳章")
    }

    func testKeyboardAnnotationsAndEditableFields() async throws {
        try await loadFixture()
        _ = try await evaluate("document.dispatchEvent(new KeyboardEvent('keydown', {key:'h', bubbles:true})); document.dispatchEvent(new KeyboardEvent('keydown', {key:'n', bubbles:true})); true")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(keyboardActions, [false, true])
        _ = try await evaluate("""
            (() => {
                const input = document.createElement('textarea');
                document.body.appendChild(input);
                input.dispatchEvent(new KeyboardEvent('keydown', {key:'h', bubbles:true}));
                input.dispatchEvent(new KeyboardEvent('keydown', {key:'n', bubbles:true}));
                input.remove(); return true;
            })()
            """)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(keyboardActions, [false, true], "输入笔记时不能触发 H/N 标注")
    }

    func testFootnoteAndLineGuide() async throws {
        try await loadFixture()
        _ = try await evaluate("document.querySelector('a[href=\"#fn1\"]').click(); true")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(selection.activeFootnoteCard?.text, "脚注正文")
        _ = try await evaluate("window.dreaderSetLineGuide(true, '#888888'); true")
        let enabled = try await evaluate("document.getElementById('dreader-line-guide') !== null") as? Bool
        XCTAssertEqual(enabled, true)
        _ = try await evaluate("window.dreaderSetLineGuide(false); true")
        let disabled = try await evaluate("document.getElementById('dreader-line-guide') === null") as? Bool
        XCTAssertEqual(disabled, true)
    }

    func testAnimatedPageTurnUnlocksAfterAnimation() async throws {
        try await loadFixture()
        settings.isPageTurnAnimation = true
        coordinator.scrollPage(direction: 1)
        try await waitUntil("window.scrollY > 100")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(coordinator.isPageTurnAnimating)
        let firstOffset = try await evaluate("window.scrollY") as? Double ?? 0
        coordinator.scrollPage(direction: 1)
        try await waitUntil("window.scrollY > \(firstOffset + 100)")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(coordinator.isPageTurnAnimating)
    }

    func testChapterSwapStaysVisibleWhenAnimationFramesPause() async throws {
        try await loadFixture()
        _ = try await evaluate("window.requestAnimationFrame = function() { return 1; }; true")
        let file = directory.appendingPathComponent("visible.xhtml")
        try "<html><body><p id='visible-chapter'>正文必须可见</p></body></html>".write(to: file, atomically: true, encoding: .utf8)
        coordinator.parent = makeReader(file: file, index: 1)
        coordinator.loadChapter(url: file, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "第三章")
        try await waitUntil("document.getElementById('visible-chapter') !== null")
        let opacity = try await evaluate("getComputedStyle(document.getElementById('dreader-chapter-body')).opacity") as? String
        XCTAssertEqual(opacity, "1")
    }

    func testChapterSwapReloadsWhenContainerIsMissing() async throws {
        try await loadFixture()
        _ = try await evaluate("document.getElementById('dreader-chapter-body').remove(); true")
        let file = directory.appendingPathComponent("next.xhtml")
        try "<html><body><p id='recovered'>下一章已经恢复</p></body></html>".write(to: file, atomically: true, encoding: .utf8)
        coordinator.parent = makeReader(file: file, index: 1)
        coordinator.loadChapter(url: file, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "第三章")
        try await waitUntil("document.getElementById('recovered') !== null && window.dreaderReaderReady === true")
    }

    func testEmptyChapterKeepsReaderControlsForNextChapter() async throws {
        try await loadFixture()
        let file = directory.appendingPathComponent("empty.xhtml")
        try "".write(to: file, atomically: true, encoding: .utf8)
        coordinator.parent = makeReader(file: file, index: 1)
        coordinator.loadChapter(url: file, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "第三章")
        try await waitUntil("document.getElementById('p0') === null && document.querySelector('.dreader-end-btn') !== null")
        _ = try await evaluate("document.querySelector('.dreader-end-btn').click(); true")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(nextCount, 1)
    }

    func testRapidChapterChangesCannotDisplayStaleRead() async throws {
        try await loadFixture()
        let missing = directory.appendingPathComponent("missing.xhtml")
        coordinator.parent = makeReader(file: missing, index: 1)
        coordinator.loadChapter(url: missing, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "第三章")
        let final = directory.appendingPathComponent("final.xhtml")
        try "<html><body><p id='final-chapter'>最终章节</p></body></html>".write(to: final, atomically: true, encoding: .utf8)
        coordinator.parent = makeReader(file: final, index: 2)
        coordinator.loadChapter(url: final, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "第四章")
        try await waitUntil("document.getElementById('final-chapter') !== null")
        try await Task.sleep(for: .milliseconds(150))
        let stillFinal = try await evaluate("document.getElementById('final-chapter') !== null && window.dreaderReaderReady === true") as? Bool
        XCTAssertEqual(stillFinal, true)
        XCTAssertEqual(coordinator.currentURL, final)
    }

    func testRelativeStylesAndLinksFollowChapterDirectory() async throws {
        for (index, name) in ["one", "two"].enumerated() {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let color = index == 0 ? "rgb(1, 2, 3)" : "rgb(4, 5, 6)"
            try "#resource-check { outline-color: \(color); }".write(to: folder.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
            let file = folder.appendingPathComponent("chapter.xhtml")
            try "<html><head><link rel='stylesheet' href='style.css'></head><body><p id='resource-check' data-chapter='\(name)'>章节样式</p><a id='resource-link' href='next.xhtml'>下一章</a></body></html>".write(to: file, atomically: true, encoding: .utf8)
            coordinator.parent = makeReader(file: file, index: index)
            coordinator.loadChapter(url: file, opfDir: directory, unzippedDir: directory,
                                    settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
            try await waitUntil("document.getElementById('resource-check')?.dataset.chapter === '\(name)' && getComputedStyle(document.getElementById('resource-check')).outlineColor === '\(color)'")
            let href = try await evaluate("document.getElementById('resource-link').href") as? String
            XCTAssertEqual(href, folder.appendingPathComponent("next.xhtml").absoluteString)
        }
    }

    func testLongChapterColdLoadAndSwitch() async throws {
        let textDirectory = directory.appendingPathComponent("OEBPS/Text", isDirectory: true)
        try FileManager.default.createDirectory(at: textDirectory, withIntermediateDirectories: true)
        let paragraphs = (0..<1500).map { "<p>第\($0)段。长章回归测试验证翻页与划线。正文应该随翻页平稳前进，切换章节后正常显示。</p>" }.joined()
        let file = textDirectory.appendingPathComponent("long.xhtml")
        try "<html><body><div id='long-chapter'>\(paragraphs)</div></body></html>".write(to: file, atomically: true, encoding: .utf8)
        coordinator.parent = makeReader(file: file)
        coordinator.loadChapter(url: file, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
        try await waitUntil("document.getElementById('long-chapter') !== null && window.dreaderReaderReady === true", timeout: 15)
        try await Task.sleep(for: .milliseconds(150))
        coordinator.scrollPage(direction: 1)
        try await waitUntil("window.scrollY > 50")
    }

    func testRealAnthologyChaptersWhenConfigured() async throws {
        guard let configuredRoots = ProcessInfo.processInfo.environment["DREADER_REGRESSION_BOOK_ROOTS"] else {
            throw XCTSkip("设置 DREADER_REGRESSION_BOOK_ROOTS 后可回归本地合订本副本")
        }
        for (bookIndex, path) in configuredRoots.split(separator: ":").enumerated() {
            let source = URL(fileURLWithPath: String(path), isDirectory: true)
            let copied = directory.appendingPathComponent("anthology-\(bookIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
            let sourceFiles = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey])!
            for input in sourceFiles.allObjects.compactMap({ $0 as? URL }) {
                let relative = String(input.path.dropFirst(source.path.count + 1))
                let output = copied.appendingPathComponent(relative)
                if try input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                } else {
                    try Data(contentsOf: input).write(to: output)
                }
            }
            let enumerator = FileManager.default.enumerator(at: copied, includingPropertiesForKeys: [.fileSizeKey])!
            let chapters = enumerator.compactMap { $0 as? URL }.filter {
                ["xhtml", "html", "htm"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent != "_dreader_render.html"
            }.sorted {
                ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let samples = Array(chapters.prefix(2))
            XCTAssertEqual(samples.count, 2)
            for (index, file) in samples.enumerated() {
                let token = "anthology-\(bookIndex)-\(index)"
                let raw = try XCTUnwrap(EPUBWebView.Coordinator.readTextSmart(file))
                let marked = raw.replacingOccurrences(of: "</body>", with: "<span id='dreader-regression-marker' data-token='\(token)'></span></body>", options: .caseInsensitive)
                try marked.write(to: file, atomically: true, encoding: .utf8)
                let started = Date()
                coordinator.parent = makeReader(file: file, index: index, opfDir: copied, unzippedDir: copied)
                coordinator.loadChapter(url: file, opfDir: copied, unzippedDir: copied,
                                        settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
                try await waitUntil("document.getElementById('dreader-regression-marker')?.dataset.token === '\(token)' && window.dreaderReaderReady === true", timeout: 20)
                try await waitUntil("getComputedStyle(document.getElementById('dreader-chapter-body')).opacity === '1'", timeout: 3)
                print("真实合订本样本 \(bookIndex + 1)-\(index + 1)：\(raw.utf8.count) 字节，加载 \(String(format: "%.3f", Date().timeIntervalSince(started))) 秒")
                coordinator.scrollPage(direction: 1)
                try await waitUntil("window.scrollY > 50")
                coordinator.scrollPage(direction: 0)
                try await waitUntil("window.scrollY < 2")
                _ = try await evaluate("""
                    (() => {
                        const paragraph = [...document.querySelectorAll('#dreader-chapter-body p')].find(p => p.textContent.trim().length > 20);
                        if (!paragraph) return false;
                        const range = document.createRange(); range.selectNodeContents(paragraph);
                        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                        document.dispatchEvent(new MouseEvent('mouseup', {bubbles:true}));
                        return true;
                    })()
                    """)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(selection.activeSelection?.text.isEmpty ?? true)
                coordinator.applyHighlightInDOM(colorHex: "#FFE066", id: token, note: "合订本划线测试")
                try await waitUntil("document.querySelector('mark[data-id=\"\(token)\"]') !== null")
                coordinator.removeHighlightFromDOM(id: token)
                try await waitUntil("document.querySelector('mark[data-id=\"\(token)\"]') === null")
                let nextBefore = nextCount
                _ = try await evaluate("document.querySelector('.dreader-end-btn').click(); true")
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(nextCount, nextBefore + 1)
            }
        }
    }

    func testThemeBilingualAndScriptModeKeepInteractionsWorking() async throws {
        try await loadFixture()
        settings.theme = .dark
        settings.fontSize = 22
        coordinator.updateStyles(settings: settings)
        let fontSize = try await evaluate("getComputedStyle(document.getElementById('p0')).fontSize") as? String
        XCTAssertEqual(fontSize, "22px")
        settings.isBilingualEnabled = true
        coordinator.parent = makeReader(file: directory.appendingPathComponent("first.xhtml"))
        coordinator.loadChapter(url: directory.appendingPathComponent("first.xhtml"), opfDir: directory,
                                unzippedDir: directory, settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
        try await waitUntil("document.getElementById('dreader-trans-slot-0') !== null")
        coordinator.updateTranslationInDOM(index: 0, translation: "测试译文", agentName: "测试伴读")
        try await waitUntil("document.querySelector('.dreader-bilingual-body')?.textContent === '测试译文'")
        settings.chineseScriptMode = .simplified
        coordinator.updateScriptModeInCurrentChapter(settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
        try await Task.sleep(for: .milliseconds(100))
        coordinator.scrollPage(direction: 1)
        try await waitUntil("window.scrollY > 100")
    }
}
