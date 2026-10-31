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

    private func loadReaderHTML(_ body: String, bilingual: Bool = false) async throws {
        settings.isBilingualEnabled = bilingual
        let html = "<html><head><meta charset='utf-8'></head><body>\(body)</body></html>"
        let file = directory.appendingPathComponent("first.xhtml")
        try html.write(to: file, atomically: true, encoding: .utf8)
        coordinator.parent = makeReader(file: file)
        coordinator.loadChapter(url: file, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
        try await waitUntil("document.getElementById('dreader-chapter-body') !== null && window.dreaderReaderReady === true")
        try await Task.sleep(for: .milliseconds(100))
    }

    func testReadAloudUsesRenderedTextAndIndependentStableIDs() async throws {
        settings.bilingualMode = .interlinear
        try await loadReaderHTML("""
            <h2>章节标题</h2><p>甲。</p><p>乙。</p>
            <div>没有 p 标签的正文内容。</div>
            <ul><li>第一条完整列表项。</li></ul>
            <table><tr><td>表格中的完整文字。</td></tr></table>
            <p>数字实体：&#20013;&#25991;。</p>
            <p><ruby>重庆<rt>chóng qìng</rt></ruby>是一座城市。</p>
            <p>这是<strong>强调</strong>的完整正文。</p>
            <p id='repeat-a'>同一句话重复出现。</p><p id='repeat-b'>同一句话重复出现。</p>
            <div id='inline-source'>直接<strong>正文</strong>文本。<p>块中段。</p>尾部文本。</div>
            <ul><li>列表前缀<p>嵌套段落。</p><ul><li>深层项。</li></ul></li></ul>
            <div class='dreader-classic-divider'>✦ ❦ ✦</div>
            """, bilingual: true)
        let expected = [
            "章节标题", "甲。", "乙。", "没有 p 标签的正文内容。", "第一条完整列表项。",
            "表格中的完整文字。", "数字实体：中文。", "重庆是一座城市。",
            "这是强调的完整正文。", "同一句话重复出现。", "同一句话重复出现。",
            "直接正文文本。", "块中段。", "尾部文本。", "列表前缀 嵌套段落。 深层项。"
        ]
        let segments = try await coordinator.readAloudSegments()
        XCTAssertEqual(segments.map(\.text), expected)
        XCTAssertEqual(segments.map(\.id), Array(0..<expected.count))
        let inlineChildren = try await evaluate("document.getElementById('inline-source').children.length") as? Int
        XCTAssertEqual(inlineChildren, 3, "除原有 strong、p 和双语槽外，朗读提取不能额外包裹正文")
        let bilingualIDs = try await evaluate("Array.from(document.querySelectorAll('[data-dreader-para]')).map(e => e.getAttribute('data-dreader-para')).join(',')") as? String
        XCTAssertEqual(bilingualIDs, "0,1,2,3,4,5,6,7,8", "朗读标识不能改变双语译文使用的段落编号")
        _ = try await evaluate("window.dreaderRestoreHighlights([{id:'inline',text:'这是强调的完整正文。',colorHex:'#FFE066',note:''}]); true")
        let restored = try await coordinator.readAloudSegments()
        XCTAssertEqual(restored.map(\.text), expected, "已有划线不得改变朗读文本或顺序")
        coordinator.scrollToReadAloudSegment(id: 11)
        let inlineActive = try await evaluate("document.getElementById('inline-source').classList.contains('dreader-read-aloud-active')") as? Bool
        XCTAssertEqual(inlineActive, true, "未包裹 inline 正文也应能按 Range 定位")
        coordinator.scrollToReadAloudSegment(id: 10)
        let active = try await evaluate("document.querySelector('.dreader-read-aloud-active')?.id") as? String
        XCTAssertEqual(active, "repeat-b", "相同文本的第二段应使用自己的定位 ID")
    }

    func testSearchFindsHighlightedAndInlineTextWithoutDuplicatingHighlights() async throws {
        try await loadReaderHTML("""
            <p>已有<mark class='dreader-highlight' data-id='saved'>关键词</mark>文本。</p>
            <p>这是<strong>强调</strong>的完整正文。</p>
            <p id='repeat-a'>同一句话重复出现。</p><p id='repeat-b'>同一句话重复出现。</p>
            <div class='dreader-bilingual-trans'>关键词译文</div>
            """)
        coordinator.scrollToSearchMatch(keyword: "关键词", matchIndex: 0)
        var selected = try await evaluate("window.getSelection().toString()") as? String
        XCTAssertEqual(selected, "关键词")
        let highlights = try await evaluate("document.querySelectorAll('mark[data-id=\"saved\"]').length") as? Int
        XCTAssertEqual(highlights, 1, "搜索不能拆开或复制已有划线")
        coordinator.scrollToSearchMatch(keyword: "这是强调的完整正文。", matchIndex: 0)
        selected = try await evaluate("window.getSelection().toString()") as? String
        XCTAssertEqual(selected, "这是强调的完整正文。")
        coordinator.scrollToSearchMatch(keyword: "同一句话重复出现。", matchIndex: 1)
        let repeatID = try await evaluate("window.getSelection().anchorNode.parentElement.closest('p')?.id") as? String
        XCTAssertEqual(repeatID, "repeat-b")
        let translatedHit = try await evaluate("window.dreaderScrollToSearchMatch('关键词', 1)") as? Bool
        XCTAssertEqual(translatedHit, false, "翻译卡片不应成为正文搜索命中")
    }

    func testReaderScriptRegistersEveryInteraction() async throws {
        try await loadFixture()
        let functions = ["dreaderScrollPage", "dreaderPageTurnPlan", "dreaderApplyHighlight",
                         "dreaderSetChapterContent", "dreaderRestoreHighlights", "dreaderScrollToSearchMatch",
                         "dreaderScrollToHighlight", "dreaderReadAloudSegments", "dreaderScrollToReadAloudSegment",
                         "dreaderScrollToProgress", "dreaderUpdateTranslation", "dreaderGoNextChapter"]
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

    /// 同文本在多处出现时,按划线快照的前后文把 mark 放回各自的段落(而非全部落第一处)
    func testRestoreHighlightsDisambiguateByContextSnapshot() async throws {
        try await loadReaderHTML(
            "<p>甲前文重复句。</p><p>乙前文重复句。</p><p>丙前文重复句。</p>")
        // 三条划线同文本,前缀不同(划线时各自记录的 ~24 字前文)
        _ = try await evaluate("""
            window.dreaderRestoreHighlights([
                {id:'h1', text:'重复句。', colorHex:'#FFE066', note:'', prefix:'乙前文', suffix:''},
                {id:'h2', text:'重复句。', colorHex:'#FFE066', note:'', prefix:'丙前文', suffix:''},
                {id:'h3', text:'重复句。', colorHex:'#FFE066', note:'', suffix:''}
            ]); true
            """)
        let placements = try await evaluate("""
            JSON.stringify(Array.from(document.querySelectorAll('mark[data-id]')).map(m => {
                const row = m.closest('p[data-dreader-para]');
                return { id: m.getAttribute('data-id'), para: row ? row.getAttribute('data-dreader-para') : null };
            }))
            """) as? String
        guard let placements,
              let data = placements.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return XCTFail("划线位置解析失败")
        }
        func para(_ id: String) -> String { rows.first { $0["id"] as? String == id }?["para"] as? String ?? "missing" }
        XCTAssertEqual(para("h1"), "1", "前缀『乙前文』的划线必须落在第二段")
        XCTAssertEqual(para("h2"), "2", "前缀『丙前文』的划线必须落在第三段")
        XCTAssertEqual(para("h3"), "0", "无前缀的划线保持旧行为落第一处")
        // 三条都在,没有互相覆盖漏标
        XCTAssertEqual(rows.count, 3)
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

    func testReadingProgressRestoresHorizontalVerticalAndOccurrence() async throws {
        try await loadFixture()
        coordinator.scrollToProgress(0.5)
        try await waitUntil("(() => { const m = window.dreaderScrollMetrics(); return Math.abs(m.currentScroll / m.maxScroll - 0.5) < 0.02; })()")
        coordinator.scrollToProgress(0)
        try await waitUntil("window.dreaderScrollMetrics().currentScroll < 2")
        coordinator.scrollToProgress(1)
        try await waitUntil("(() => { const m = window.dreaderScrollMetrics(); return Math.abs(m.currentScroll - m.maxScroll) < 2; })()")

        let file = directory.appendingPathComponent("first.xhtml")
        coordinator.parent = makeReader(file: file, index: 1)
        coordinator.loadChapter(url: file, opfDir: directory, unzippedDir: directory,
                                settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
        try await waitUntil("window.dreaderReaderReady === true")
        XCTAssertEqual(coordinator.currentChapterIndex, 1, "同 URL 的第二 occurrence 也必须进入自己的加载状态")

        try await loadFixture(vertical: true)
        coordinator.scrollToProgress(0.5)
        try await waitUntil("(() => { const m = window.dreaderScrollMetrics(); return m.vertical && m.currentScroll > 0 && window.scrollX < 0 && Math.abs(m.currentScroll / m.maxScroll - 0.5) < 0.02; })()")
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
                let segments = try await coordinator.readAloudSegments()
                XCTAssertFalse(segments.isEmpty, "有可见正文的真实章节应提供朗读片段")
                XCTAssertTrue(segments.allSatisfy { !$0.text.isEmpty })
                XCTAssertEqual(Set(segments.map(\.id)).count, segments.count)
                XCTAssertFalse(segments.contains { $0.text.contains("下一章") }, "章末导航按钮不应进入朗读")
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
        settings.bilingualMode = .interlinear
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
        let beforeTranslation = try await coordinator.readAloudSegments()
        XCTAssertFalse(beforeTranslation.isEmpty)
        XCTAssertFalse(beforeTranslation.contains { $0.text.contains("测试译文") || $0.text.contains("AI 伴读翻译") })
        settings.chineseScriptMode = .simplified
        coordinator.updateScriptModeInCurrentChapter(settings: settings, hasNextChapter: true, nextChapterTitle: "下一章")
        try await Task.sleep(for: .milliseconds(100))
        let afterConversion = try await coordinator.readAloudSegments()
        XCTAssertEqual(afterConversion.map(\.id), beforeTranslation.map(\.id), "双语和简繁重排不应复用错位的朗读定位")
        XCTAssertFalse(afterConversion.contains { $0.text.contains("下一章") })
        coordinator.scrollPage(direction: 1)
        try await waitUntil("window.scrollY > 100")
    }

    // MARK: - 左右分栏对照(sideBySide)

    func testSideBySideRowsKeepAnchorsAndExcludedFromReadAloud() async throws {
        settings.bilingualMode = .sideBySide
        try await loadReaderHTML(
            "<p>第一段原文但愿各自安好。</p><p>第二段原文文本。</p><p>第三段原文文本。</p>",
            bilingual: true)
        settings.bilingualMode = .interlinear

        // 行结构:每段一行 grid,左原文右空槽(未译不显示按钮)
        let rowInfo = try await evaluate("""
            JSON.stringify({
                rows: document.querySelectorAll('.dreader-bilingual-row').length,
                slots: document.querySelectorAll('.dreader-bilingual-side-slot').length,
                trans: document.querySelectorAll('.dreader-bilingual-side-trans').length,
                buttons: document.querySelectorAll('.dreader-bilingual-translate-btn').length,
                anchors: Array.from(document.querySelectorAll('.dreader-bilingual-row > p')).map(
                    e => e.getAttribute('data-dreader-para')).join(',')
            })
            """)
        guard let obj = rowInfo as? String,
              let data = obj.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("sideBySide 结构未注入")
        }
        XCTAssertEqual(info["rows"] as? Int, 3, "段落必须包成双栏行")
        XCTAssertEqual(info["slots"] as? Int, 3, "未译段以空槽占位")
        XCTAssertEqual(info["trans"] as? Int, 0)
        XCTAssertEqual(info["buttons"] as? Int, 0, "分栏模式不给未译段按钮")
        XCTAssertEqual(info["anchors"] as? String, "0,1,2", "双栏行内原文锚点编号不变")

        // 右列直填(JS 分派)
        coordinator.updateTranslationInDOM(index: 1, translation: "第二段译文", agentName: "AI")
        try await waitUntil(
            "document.querySelector('.dreader-bilingual-side-trans[data-para-index=\"1\"]')?.textContent === '第二段译文'")
        // 直填不得误改左侧原文
        let leftText = try await evaluate(
            "document.querySelector('.dreader-bilingual-row > p[data-dreader-para=\"1\"]').textContent") as? String
        XCTAssertEqual(leftText, "第二段原文文本。")

        // 朗读仍取原文,不吞译文侧
        let segments = try await coordinator.readAloudSegments()
        XCTAssertTrue(segments.contains { $0.text.contains("第一段原文但愿各自安好") }, "双栏行内原文仍要保持正文可听")
        XCTAssertFalse(segments.contains { $0.text.contains("第二段译文") }, "译文右列不进朗读")
    }

    func testSideBySideBatchPendingHintsTrackInFlightParagraphs() async throws {
        settings.bilingualMode = .sideBySide
        try await loadReaderHTML(
            "<p>提示段落一原文。</p><p>提示段落二原文。</p><p>提示段落三原文。</p>",
            bilingual: true)
        settings.bilingualMode = .interlinear

        // 批次开始:对应段空槽点亮「正在翻译…」提示(呼吸点 + 文案)
        coordinator.setBilingualBatchPending([0, 2])
        try await waitUntil(
            "document.querySelectorAll('.dreader-bilingual-pending-hint').length === 2")
        let pendingSlots = try await evaluate(
            "Array.from(document.querySelectorAll('.dreader-bilingual-pending')).map(e => e.getAttribute('data-para-index')).join(',')") as? String
        XCTAssertEqual(pendingSlots, "0,2", "pending 标记只落在批次覆盖的段上")

        // 译文落地(右列直填)清掉该段提示;未落地段保留
        coordinator.updateTranslationInDOM(index: 0, translation: "第零段译文", agentName: "AI")
        try await waitUntil(
            "document.querySelectorAll('.dreader-bilingual-pending-hint').length === 1")
        let remaining = try await evaluate(
            "Array.from(document.querySelectorAll('.dreader-bilingual-pending')).map(e => e.getAttribute('data-para-index')).join(',')") as? String
        XCTAssertEqual(remaining, "2", "已译段的提示必须清干净,未译段留住")

        // 空数组=全清(批会话结束/整章完成)
        coordinator.setBilingualBatchPending([])
        try await waitUntil(
            "document.querySelectorAll('.dreader-bilingual-pending-hint').length === 0")
    }

    func testSideBySideSearchDoesNotHitTranslationText() async throws {
        settings.bilingualMode = .sideBySide
        try await loadReaderHTML(
            "<p>搜索正文的工整句子。</p>", bilingual: true)
        settings.bilingualMode = .interlinear
        coordinator.updateTranslationInDOM(index: 0, translation: "搜索正文的绝无可能命中文案", agentName: "AI")
        try await waitUntil(
            "document.querySelector('.dreader-bilingual-side-trans')?.textContent?.includes('命中文案') === true")

        // 搜原文命中;搜译文 miss(译文右列与逐段译文卡同走排除清单)
        let translatedHit = try await evaluate("window.dreaderScrollToSearchMatch('绝无可能命中文案', 0)") as? Bool
        XCTAssertEqual(translatedHit, false, "译文右列不应成为正文搜索命中")
        let originalHit = try await evaluate("window.dreaderScrollToSearchMatch('搜索正文的工整句子', 0)") as? Bool
        XCTAssertEqual(originalHit, true)
    }
}
