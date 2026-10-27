import SwiftUI
import WebKit

struct EPUBWebView: NSViewRepresentable {
    let chapterURL: URL
    let opfDirectory: URL
    let unzippedDirectory: URL
    let highlights: [Highlight]
    var bookTitle: String = ""
    var chapterTitle: String = ""
    var chapterIndex: Int = 0
    let hasNextChapter: Bool
    let nextChapterTitle: String?
    let settings: ReaderSettings
    let selectionManager: ReaderSelectionManager
    let onHighlightApplied: ((String, String) -> Void)?
    let onNextChapter: () -> Void
    let onPrevChapter: () -> Void
    var onSocraticAI: ((String) -> Void)? = nil
    var onSocraticThought: ((String) -> Void)? = nil
    /// 键盘标注流（webview 聚焦时 JS keydown 桥接）：参数 true = 写想法，false = 直接高亮
    var onKeyboardAnnotate: ((Bool) -> Void)? = nil
    var bilingualTranslations: [Int: String]? = nil
    var agentName: String = "AI 伴读"
    var onTranslateParagraph: ((Int, String) -> Void)? = nil
    var registerUpdateTranslationAction: ((@escaping (Int, String, String) -> Void) -> Void)? = nil
    var onChapterLinkTapped: ((URL) -> Bool)? = nil
    let onScrollProgress: (Double) -> Void
    let registerScrollAction: (@escaping (Int) -> Void) -> Void
    let registerHighlightAction: (@escaping (String, String, String?) -> Void) -> Void
    let registerUpdateColorAction: (@escaping (String, String) -> Void) -> Void
    let registerUpdateThoughtAction: (@escaping (String, String?) -> Void) -> Void
    let registerRemoveHighlightAction: (@escaping (String) -> Void) -> Void
    var registerScrollToSearchMatchAction: ((@escaping (String, Int) -> Void) -> Void)? = nil
    var registerScrollToHighlightAction: ((@escaping (String) -> Void) -> Void)? = nil
    let getCachedHTML: (URL) -> String?
    let cacheHTML: (String, URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // Selection & Navigation Bridge
        contentController.add(context.coordinator, name: "selectionBridge")

        // Injected JS script
        let userScript = WKUserScript(
            source: EPUBThemeInjector.generateJS(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(userScript)

        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.wantsLayer = true
        webView.layer?.drawsAsynchronously = true
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        webView.allowsMagnification = true

        context.coordinator.webView = webView
        registerScrollAction { [weak coordinator = context.coordinator] dir in
            coordinator?.scrollPage(direction: dir)
        }
        registerHighlightAction { [weak coordinator = context.coordinator] colorHex, id, note in
            coordinator?.applyHighlightInDOM(colorHex: colorHex, id: id, note: note)
        }
        registerUpdateColorAction { [weak coordinator = context.coordinator] id, colorHex in
            coordinator?.updateHighlightColorInDOM(id: id, colorHex: colorHex)
        }
        registerUpdateThoughtAction { [weak coordinator = context.coordinator] id, note in
            coordinator?.updateHighlightThoughtInDOM(id: id, note: note)
        }
        registerRemoveHighlightAction { [weak coordinator = context.coordinator] id in
            coordinator?.removeHighlightFromDOM(id: id)
        }
        registerScrollToSearchMatchAction? { [weak coordinator = context.coordinator] keyword, matchIdx in
            coordinator?.scrollToSearchMatch(keyword: keyword, matchIndex: matchIdx)
        }
        registerScrollToHighlightAction? { [weak coordinator = context.coordinator] id in
            coordinator?.scrollToHighlight(id: id)
        }
        registerUpdateTranslationAction? { [weak coordinator = context.coordinator] index, text, agentName in
            coordinator?.updateTranslationInDOM(index: index, translation: text, agentName: agentName)
        }

        context.coordinator.loadChapter(
            url: chapterURL,
            opfDir: opfDirectory,
            unzippedDir: unzippedDirectory,
            settings: settings,
            hasNextChapter: hasNextChapter,
            nextChapterTitle: nextChapterTitle
        )

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let prevBilingual = context.coordinator.lastBilingualEnabled
        context.coordinator.parent = self
        context.coordinator.lastBilingualEnabled = settings.isBilingualEnabled

        let prevScriptMode = context.coordinator.lastScriptMode
        context.coordinator.lastScriptMode = settings.chineseScriptMode

        if context.coordinator.currentURL != chapterURL || prevBilingual != settings.isBilingualEnabled {
            context.coordinator.loadChapter(
                url: chapterURL,
                opfDir: opfDirectory,
                unzippedDir: unzippedDirectory,
                settings: settings,
                hasNextChapter: hasNextChapter,
                nextChapterTitle: nextChapterTitle
            )
        } else if prevScriptMode != settings.chineseScriptMode {
            // Instant script mode switch for CURRENT chapter preserving scroll position
            context.coordinator.updateScriptModeInCurrentChapter(
                settings: settings,
                hasNextChapter: hasNextChapter,
                nextChapterTitle: nextChapterTitle
            )
        } else if context.coordinator.lastSettingsSummary != settingsSummary {
            context.coordinator.updateStyles(settings: settings)
            context.coordinator.refreshCurrentChapterHighlights(highlights: highlights)
        }
    }

    private var highlightsSummary: String {
        highlights.map { "\($0.id.uuidString)-\($0.colorHex)-\($0.note ?? "")" }.joined(separator: ";")
    }

    private var settingsSummary: String {
        "\(settings.theme.rawValue)-\(settings.fontFamily.rawValue)-\(settings.fontSize)-\(settings.lineHeight)-\(settings.maxWidth)-\(settings.paragraphSpacing)-\(settings.isJustified)-\(settings.pageLayout.rawValue)-\(settings.isBilingualEnabled)-\(settings.chineseScriptMode.rawValue)-\(settings.isVertical ? "V" : "H")-\(settings.isLineGuide ? "G1" : "G0")-\(highlightsSummary)"
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: EPUBWebView
        weak var webView: WKWebView?
        var currentURL: URL?
        var currentOpfDir: URL?
        var isPageReady: Bool = false
        var lastSettingsSummary: String = ""
        var lastBilingualEnabled: Bool = false
        var lastScriptMode: ChineseScriptMode = .original
        var pendingScrollHighlightId: String? = nil
        /// 仿真翻页进行中（防止连按叠帧）
        var isPageTurnAnimating: Bool = false

        init(_ parent: EPUBWebView) {
            self.parent = parent
        }

        func scrollPage(direction: Int) {
            if direction == 0 {
                webView?.evaluateJavaScript("window.scrollTo({ top: 0, behavior: 'smooth' }); document.body.scrollTop = 0; document.documentElement.scrollTop = 0;", completionHandler: nil)
                return
            }
            // 仿真翻页：旧页快照盖在原地 → webview 无动画瞬时跳页 → 快照整幅滑出露出新页。
            // 动画进行中直接忽略新按键（叠帧会让两层动画错位）。
            if isPageTurnAnimating { return }
            if parent.settings.isPageTurnAnimation, let webView = webView, isPageReady {
                isPageTurnAnimating = true
                let pageColor = parent.settings.theme.backgroundColorHex
                webView.takeSnapshot(with: nil) { [weak self] image, _ in
                    guard let self = self, let image = image else {
                        self?.isPageTurnAnimating = false
                        self?.plainScroll(direction: direction)
                        return
                    }
                    DispatchQueue.main.async {
                        self.performPageTurn(direction: direction, snapshot: image, pageColor: pageColor, webView: webView)
                    }
                }
            } else {
                plainScroll(direction: direction)
            }
        }

        private func plainScroll(direction: Int) {
            webView?.evaluateJavaScript("window.dreaderScrollPage(\(direction));", completionHandler: nil)
        }

        /// 快照合成翻页：在 webview 上盖旧页图层，先把 webview 无动画滚到目标位置，再让快照滑出。
        private func performPageTurn(direction: Int, snapshot: NSImage, pageColor: String, webView: WKWebView) {
            // 先读当前滚动量与边界状态（动画开始前）
            webView.evaluateJavaScript("window.dreaderPageTurnPlan(\(direction));") { [weak self] result, _ in
                guard let self = self else { return }
                guard let plan = result as? [String: Any],
                      let willTurn = plan["willTurn"] as? Bool else {
                    // JS 未就绪：退回普通平滑滚动
                    self.isPageTurnAnimating = false
                    self.plainScroll(direction: direction)
                    return
                }
                guard willTurn else {
                    // 页内滚动（未到边界）或需翻章：交回普通路径（翻章自带 DOM 切换，不套平移动画）
                    self.isPageTurnAnimating = false
                    self.plainScroll(direction: direction)
                    return
                }
                let offset = (plan["offset"] as? Double) ?? 0
                let vertical = (plan["vertical"] as? Bool) ?? false

                self.runPageTurnOverlay(
                    direction: direction,
                    offset: offset,
                    vertical: vertical,
                    snapshot: snapshot,
                    pageColor: pageColor,
                    webView: webView
                )
            }
        }

        private func runPageTurnOverlay(
            direction: Int,
            offset: Double,
            vertical: Bool,
            snapshot: NSImage,
            pageColor: String,
            webView: WKWebView
        ) {
            let bounds = webView.bounds
            guard bounds.width > 1, bounds.height > 1 else {
                isPageTurnAnimating = false
                plainScroll(direction: direction)
                return
            }

            // 裁剪容器：NSView 默认不裁剪子视图，不裁剪的话快照滑出时会溢出盖到侧边栏/顶栏
            let clip = NSView(frame: bounds)
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            webView.addSubview(clip)

            // 1. 不透明纸面垫底（webview 背景透明，直接露底会闪）
            let paper = NSView(frame: bounds)
            paper.wantsLayer = true
            paper.layer?.backgroundColor = Color(hex: pageColor).cgColor
            clip.addSubview(paper)

            // 2. 旧页快照：从起始位置滑向终点的方向平移一整页
            let snapshotView = NSImageView(frame: bounds)
            snapshotView.image = snapshot
            snapshotView.wantsLayer = true
            clip.addSubview(snapshotView)

            // 3. webview 内容瞬时跳到目标位置（被快照+纸面盖住，不可见）
            let js: String
            if vertical {
                // 竖排：前进 = scrollLeft 减小（从右往左读）
                js = direction > 0
                    ? "window.scrollBy({ left: -\(offset), behavior: 'auto' });"
                    : "window.scrollBy({ left: \(offset), behavior: 'auto' });"
            } else {
                js = direction > 0
                    ? "window.scrollBy({ top: \(offset), behavior: 'auto' });"
                    : "window.scrollBy({ top: -\(offset), behavior: 'auto' });"
            }
            webView.evaluateJavaScript(js, completionHandler: nil)

            // 4. 动画：快照朝阅读前进方向滑出
            let dx: CGFloat
            let dy: CGFloat
            if vertical {
                dx = direction > 0 ? bounds.width : -bounds.width // 前进 → 旧页左滑出
                dy = 0
            } else {
                dx = 0
                dy = direction > 0 ? -bounds.height : bounds.height // 前进 → 旧页上滑出
            }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                snapshotView.removeFromSuperview()
                paper.removeFromSuperview()
                clip.removeFromSuperview()
                self?.isPageTurnAnimating = false
            }
            let anim = CABasicAnimation(keyPath: "position")
            anim.fromValue = NSValue(point: NSPoint(x: bounds.midX, y: bounds.midY))
            anim.toValue = NSValue(point: NSPoint(x: bounds.midX + dx, y: bounds.midY + dy))
            anim.duration = 0.32
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.isRemovedOnCompletion = true
            snapshotView.layer?.add(anim, forKey: "dreader-page-turn")
            CATransaction.commit()
        }

        /// 拦截页内链接导航（如 Kindle 目录页的章节链接）。
        /// 原始章节文件大多没有 charset 声明，WebKit 裸导航会按 Latin-1 解码产生乱码，
        /// 且丢失全部主题/高亮/进度环境。这里转交 Swift 跳章并走完整渲染管线。
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let target = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // 只拦截书内 file:// 链接；外链与锚点不动（锚点由 JS 端脚注拦截处理）
            let insideBook = target.path.hasPrefix(parent.unzippedDirectory.path)
            if insideBook, let handler = parent.onChapterLinkTapped, handler(target) {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func applyHighlightInDOM(colorHex: String, id: String, note: String?) {
            let escapedNote = note?
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            let script = "window.dreaderApplyHighlight('\(colorHex)', '\(id)', '\(escapedNote)');"
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        func updateHighlightColorInDOM(id: String, colorHex: String) {
            let script = "window.dreaderUpdateHighlightColor('\(id)', '\(colorHex)');"
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        func updateHighlightThoughtInDOM(id: String, note: String?) {
            let escapedNote = note?
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            let script = "window.dreaderUpdateHighlightThought('\(id)', '\(escapedNote)');"
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        func removeHighlightFromDOM(id: String) {
            let script = "window.dreaderRemoveHighlight('\(id)');"
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        func scrollToHighlight(id: String) {
            let script = "window.dreaderScrollToHighlight('\(id)');"
            webView?.evaluateJavaScript(script) { [weak self] result, _ in
                if let found = result as? Bool, !found {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self?.webView?.evaluateJavaScript(script, completionHandler: nil)
                    }
                }
            }
        }

        func restoreHighlightsInDOM(_ highlights: [Highlight]) {
            guard let webView = webView, !highlights.isEmpty else { return }
            let items: [[String: Any]] = highlights.map { h in
                [
                    "id": h.id.uuidString,
                    "text": h.text,
                    "colorHex": h.colorHex,
                    "note": h.note ?? ""
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: items),
               let jsonString = String(data: data, encoding: .utf8) {
                let script = "window.dreaderRestoreHighlights(\(jsonString));"
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }

        func loadChapter(
            url: URL,
            opfDir: URL,
            unzippedDir: URL,
            settings: ReaderSettings,
            hasNextChapter: Bool,
            nextChapterTitle: String?
        ) {
            guard let webView = webView else { return }
            currentURL = url
            lastSettingsSummary = parent.settingsSummary

            let rawHTML: String
            if let cached = parent.getCachedHTML(url) {
                rawHTML = cached
            } else if let loaded = Self.readTextSmart(url) {
                rawHTML = loaded
                parent.cacheHTML(loaded, url)
            } else {
                webView.loadFileURL(url, allowingReadAccessTo: unzippedDir)
                return
            }

            let chapterDir = url.deletingLastPathComponent()

            // High performance: in-place DOM swap if page template is already loaded
            if isPageReady && currentOpfDir == opfDir {
                swapChapterDOM(
                    rawHTML: rawHTML,
                    chapterDir: chapterDir,
                    opfDir: opfDir,
                    settings: settings,
                    highlights: parent.highlights,
                    hasNextChapter: hasNextChapter,
                    nextChapterTitle: nextChapterTitle
                )
            } else {
                currentOpfDir = opfDir
                isPageReady = false
                let processedHTML = EPUBThemeInjector.generateInjectedHTML(
                    rawHTML: rawHTML,
                    chapterDir: chapterDir,
                    opfDir: opfDir,
                    settings: settings,
                    highlights: parent.highlights,
                    bilingualTranslations: parent.bilingualTranslations,
                    agentName: parent.agentName,
                    hasNextChapter: hasNextChapter,
                    nextChapterTitle: nextChapterTitle,
                    bookTitle: parent.bookTitle,
                    chapterTitle: parent.chapterTitle,
                    chapterIndex: parent.chapterIndex
                )

                // Write rendered page to disk as .html inside the book cache directory for HTML5 parsing and full sandbox read access
                let renderURL = chapterDir.appendingPathComponent("_dreader_render.html")
                do {
                    try processedHTML.write(to: renderURL, atomically: true, encoding: .utf8)
                    webView.loadFileURL(renderURL, allowingReadAccessTo: unzippedDir)
                } catch {
                    webView.loadHTMLString(processedHTML, baseURL: chapterDir)
                }
            }
        }

        func refreshCurrentChapterHighlights(highlights: [Highlight]) {
            restoreHighlightsInDOM(highlights)
        }

        /// 智能读文本：UTF-8 → 声明编码 → GBK → Latin-1。
        /// Kindle 等来源的章节文件可能没有 charset 声明，或声明 GBK 实际 UTF-8，
        /// 直接 String(contentsOf:encoding:) 会产生 mojibake 乱码。
        static func readTextSmart(_ url: URL) -> String? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            // 1. UTF-8 优先（严格校验，避免半 UTF-8 被误读）
            if let s = String(data: data, encoding: .utf8) { return s }
            // 2. 读 XML/HTML 声明中声称的编码
            let head = String(data: data.prefix(300), encoding: .isoLatin1) ?? ""
            if let match = head.range(of: "encoding=[\"']([^\"']+)[\"']", options: .regularExpression) {
                let quoted = head[match]
                let enc = quoted.split(whereSeparator: { $0 == "\"" || $0 == "'" }).last.map(String.init) ?? ""
                if !enc.isEmpty {
                    let iana = CFStringConvertIANACharSetNameToEncoding(enc as CFString)
                    if iana != kCFStringEncodingInvalidId {
                        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(iana)
                        if let s = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) { return s }
                    }
                }
            }
            // 3. 中文电子书最常见的 GBK/GB18030 兜底
            let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let s = String(data: data, encoding: String.Encoding(rawValue: gbk)) { return s }
            // 4. 最后 Latin-1（永不失败）
            return String(data: data, encoding: .isoLatin1)
        }

        func updateScriptModeInCurrentChapter(
            settings: ReaderSettings,
            hasNextChapter: Bool,
            nextChapterTitle: String?
        ) {
            guard let webView = webView, let url = currentURL, let opfDir = currentOpfDir else { return }
            lastSettingsSummary = parent.settingsSummary
            lastScriptMode = settings.chineseScriptMode

            let rawHTML: String
            if let cached = parent.getCachedHTML(url) {
                rawHTML = cached
            } else if let loaded = try? String(contentsOf: url, encoding: .utf8) {
                rawHTML = loaded
            } else if let loadedLatin = try? String(contentsOf: url, encoding: .isoLatin1) {
                rawHTML = loadedLatin
            } else {
                return
            }

            let chapterDir = url.deletingLastPathComponent()
            let resolvedHTML = EPUBThemeInjector.resolveResourceURLs(in: rawHTML, chapterDir: chapterDir, opfDir: opfDir)
            var bodyContent = EPUBThemeInjector.extractBodyContent(from: resolvedHTML)
            bodyContent = EPUBThemeInjector.sanitizeAndElevateLayout(bodyContent)

            // Tag-safe Chinese Script Conversion
            if settings.chineseScriptMode != .original {
                bodyContent = ChineseScriptConverter.convertHTML(bodyContent, mode: settings.chineseScriptMode)
            }

            if !parent.highlights.isEmpty {
                bodyContent = EPUBThemeInjector.injectHighlights(in: bodyContent, highlights: parent.highlights)
            }
            if settings.isBilingualEnabled {
                bodyContent = EPUBThemeInjector.injectBilingualBlocks(
                    in: bodyContent,
                    translations: parent.bilingualTranslations,
                    agentName: parent.agentName,
                    theme: settings.theme
                )
            }
            let headElements = EPUBThemeInjector.extractHeadElements(from: resolvedHTML)

            let displayBookTitle = ChineseScriptConverter.convert(parent.bookTitle, mode: settings.chineseScriptMode)
            let displayChapterTitle = ChineseScriptConverter.convert(parent.chapterTitle, mode: settings.chineseScriptMode)
            let displayNextChapterTitle = nextChapterTitle.map { ChineseScriptConverter.convert($0, mode: settings.chineseScriptMode) }

            let endCard = EPUBThemeInjector.generateEndCardHTML(
                hasNextChapter: hasNextChapter,
                nextChapterTitle: displayNextChapterTitle,
                theme: settings.theme,
                bookTitle: displayBookTitle,
                chapterTitle: displayChapterTitle,
                chapterIndex: parent.chapterIndex
            )

            let highlightItems: [[String: Any]] = parent.highlights.map { h in
                [
                    "id": h.id.uuidString,
                    "text": ChineseScriptConverter.convert(h.text, mode: settings.chineseScriptMode),
                    "colorHex": h.colorHex,
                    "note": h.note ?? ""
                ]
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: [
                "body": bodyContent,
                "styles": headElements,
                "endCard": endCard,
                "highlights": highlightItems
            ]), let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            let script = "window.dreaderSetChapterContentPreservingScroll ? window.dreaderSetChapterContentPreservingScroll(\(jsonString)) : window.dreaderSetChapterContent(\(jsonString));"
            webView.evaluateJavaScript(script) { [weak self] result, error in
                let success = (result as? Bool) ?? false
                if success {
                    self?.restoreHighlightsInDOM(self?.parent.highlights ?? [])
                } else if error != nil {
                    // Fall back to full reload if needed
                    self?.loadChapter(
                        url: url,
                        opfDir: opfDir,
                        unzippedDir: self?.parent.unzippedDirectory ?? opfDir,
                        settings: settings,
                        hasNextChapter: hasNextChapter,
                        nextChapterTitle: nextChapterTitle
                    )
                }
            }
        }

        func swapChapterDOM(
            rawHTML: String,
            chapterDir: URL,
            opfDir: URL,
            settings: ReaderSettings,
            highlights: [Highlight],
            hasNextChapter: Bool,
            nextChapterTitle: String?
        ) {
            guard let webView = webView else { return }

            let resolvedHTML = EPUBThemeInjector.resolveResourceURLs(in: rawHTML, chapterDir: chapterDir, opfDir: opfDir)
            var bodyContent = EPUBThemeInjector.extractBodyContent(from: resolvedHTML)
            bodyContent = EPUBThemeInjector.sanitizeAndElevateLayout(bodyContent)

            // Tag-safe Chinese Script Conversion
            if settings.chineseScriptMode != .original {
                bodyContent = ChineseScriptConverter.convertHTML(bodyContent, mode: settings.chineseScriptMode)
            }

            if !highlights.isEmpty {
                bodyContent = EPUBThemeInjector.injectHighlights(in: bodyContent, highlights: highlights)
            }
            if settings.isBilingualEnabled {
                bodyContent = EPUBThemeInjector.injectBilingualBlocks(
                    in: bodyContent,
                    translations: parent.bilingualTranslations,
                    agentName: parent.agentName,
                    theme: settings.theme
                )
            }
            let headElements = EPUBThemeInjector.extractHeadElements(from: resolvedHTML)
            let displayBookTitle = ChineseScriptConverter.convert(parent.bookTitle, mode: settings.chineseScriptMode)
            let displayChapterTitle = ChineseScriptConverter.convert(parent.chapterTitle, mode: settings.chineseScriptMode)
            let displayNextChapterTitle = nextChapterTitle.map { ChineseScriptConverter.convert($0, mode: settings.chineseScriptMode) }

            let endCard = EPUBThemeInjector.generateEndCardHTML(
                hasNextChapter: hasNextChapter,
                nextChapterTitle: displayNextChapterTitle,
                theme: settings.theme,
                bookTitle: displayBookTitle,
                chapterTitle: displayChapterTitle,
                chapterIndex: parent.chapterIndex
            )

            let highlightItems: [[String: Any]] = highlights.map { h in
                [
                    "id": h.id.uuidString,
                    "text": ChineseScriptConverter.convert(h.text, mode: settings.chineseScriptMode),
                    "colorHex": h.colorHex,
                    "note": h.note ?? ""
                ]
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: [
                "body": bodyContent,
                "styles": headElements,
                "endCard": endCard,
                "highlights": highlightItems
            ]), let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            let script = "window.dreaderSetChapterContent(\(jsonString));"
            webView.evaluateJavaScript(script) { [weak self] result, error in
                let success = (result as? Bool) ?? false
                if success {
                    self?.restoreHighlightsInDOM(highlights)
                    // 换章后同步行引导线（DOM 重挂会移除引导元素）
                    let guideScript = settings.isLineGuide
                        ? "window.dreaderSetLineGuide && window.dreaderSetLineGuide(true, '\(settings.theme.textColorHex)');"
                        : "window.dreaderSetLineGuide && window.dreaderSetLineGuide(false);"
                    webView.evaluateJavaScript(guideScript, completionHandler: nil)
                    if let pendingId = self?.pendingScrollHighlightId {
                        self?.pendingScrollHighlightId = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            self?.scrollToHighlight(id: pendingId)
                        }
                    }
                } else if error != nil {
                    // Fall back to full reload if needed
                    self?.isPageReady = false
                    if let url = self?.currentURL, let opf = self?.currentOpfDir {
                        self?.loadChapter(
                            url: url,
                            opfDir: opf,
                            unzippedDir: self?.parent.unzippedDirectory ?? opf,
                            settings: settings,
                            hasNextChapter: hasNextChapter,
                            nextChapterTitle: nextChapterTitle
                        )
                    }
                }
            }
        }

        func updateStyles(settings: ReaderSettings) {
            guard let webView = webView else { return }
            lastSettingsSummary = parent.settingsSummary

            let css = EPUBThemeInjector.generateCSS(settings: settings)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "'", with: "\\'")

            let js = """
            (function() {
                var el = document.getElementById('dreader-injected-style');
                if (!el) {
                    el = document.createElement('style');
                    el.id = 'dreader-injected-style';
                    document.body.appendChild(el);
                }
                el.innerHTML = '\(css)';
                if (el.parentNode) {
                    el.parentNode.appendChild(el);
                }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)

            // 行引导线开/关与主题色同步（横排/竖排双轴均由 JS 内部处理）
            let guideColor = settings.theme.textColorHex
            if settings.isLineGuide {
                webView.evaluateJavaScript("window.dreaderSetLineGuide && window.dreaderSetLineGuide(true, '\(guideColor)');", completionHandler: nil)
            } else {
                webView.evaluateJavaScript("window.dreaderSetLineGuide && window.dreaderSetLineGuide(false);", completionHandler: nil)
            }
        }

        func applyHighlight(colorHex: String, id: String) {
            let script = "window.applyDReaderHighlight('\(colorHex)', '\(id)');"
            webView?.evaluateJavaScript(script) { [weak self] result, error in
                if let success = result as? Bool, success {
                    self?.parent.onHighlightApplied?(colorHex, id)
                }
            }
        }

        func scrollToSearchMatch(keyword: String, matchIndex: Int) {
            let kwEscaped = keyword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            let js = "window.dreaderScrollToSearchMatch && window.dreaderScrollToSearchMatch(\"\(kwEscaped)\", \(matchIndex));"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: - WKScriptMessageHandler
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "selectionBridge",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if type == "selection",
                   let text = body["text"] as? String,
                   let x = body["x"] as? Double,
                   let y = body["y"] as? Double,
                   let bottomY = body["bottomY"] as? Double,
                   let width = body["width"] as? Double,
                   let height = body["height"] as? Double {
                    self.parent.selectionManager.activeHighlightCard = nil
                    self.parent.selectionManager.activeSelection = SelectionInfo(
                        text: text,
                        x: CGFloat(x),
                        y: CGFloat(y),
                        bottomY: CGFloat(bottomY),
                        width: CGFloat(width),
                        height: CGFloat(height)
                    )
                } else if type == "clear" {
                    self.parent.selectionManager.activeSelection = nil
                } else if type == "highlightClicked",
                          let idStr = body["id"] as? String,
                          let id = UUID(uuidString: idStr),
                          let x = body["x"] as? Double,
                          let y = body["y"] as? Double,
                          let bottomY = body["bottomY"] as? Double {
                    self.parent.selectionManager.activeSelection = nil
                    self.parent.selectionManager.activeHighlightCard = HighlightCardInfo(
                        highlightId: id,
                        x: CGFloat(x),
                        y: CGFloat(y),
                        bottomY: CGFloat(bottomY)
                    )
                } else if type == "dismissHighlightCard" {
                    self.parent.selectionManager.activeHighlightCard = nil
                } else if type == "footnote",
                          let noteText = body["text"] as? String,
                          let x = body["x"] as? Double,
                          let y = body["y"] as? Double,
                          let bottomY = body["bottomY"] as? Double,
                          !noteText.isEmpty {
                    self.parent.selectionManager.activeSelection = nil
                    self.parent.selectionManager.activeHighlightCard = nil
                    self.parent.selectionManager.activeFootnoteCard = FootnoteCardInfo(
                        text: noteText,
                        x: CGFloat(x),
                        y: CGFloat(y),
                        bottomY: CGFloat(bottomY)
                    )
                } else if type == "keyboardHighlight" {
                    self.parent.onKeyboardAnnotate?(false)
                } else if type == "keyboardThought" {
                    self.parent.onKeyboardAnnotate?(true)
                } else if type == "nextChapter" {
                    self.parent.onNextChapter()
                } else if type == "prevChapter" {
                    self.parent.onPrevChapter()
                } else if type == "scrollProgress", let p = body["progress"] as? Double {
                    self.parent.onScrollProgress(p)
                } else if type == "socraticAI", let q = body["question"] as? String {
                    self.parent.onSocraticAI?(q)
                } else if type == "socraticThought", let q = body["question"] as? String {
                    self.parent.onSocraticThought?(q)
                } else if type == "translateParagraph",
                          let idx = body["index"] as? Int,
                          let text = body["text"] as? String {
                    self.parent.onTranslateParagraph?(idx, text)
                }
            }
        }

        func updateTranslationInDOM(index: Int, translation: String, agentName: String) {
            guard let webView = webView else { return }
            guard let jsonTextData = try? JSONSerialization.data(withJSONObject: [translation]),
                  let jsonText = String(data: jsonTextData, encoding: .utf8),
                  let jsonAgentData = try? JSONSerialization.data(withJSONObject: [agentName]),
                  let jsonAgent = String(data: jsonAgentData, encoding: .utf8) else { return }

            let js = "window.dreaderUpdateTranslation(\(index), \(jsonText)[0], \(jsonAgent)[0]);"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageReady = true
            updateStyles(settings: parent.settings)
            // Ensure first chapter starts cleanly at the top
            webView.evaluateJavaScript("window.scrollTo(0, 0); document.body.scrollTop = 0; document.documentElement.scrollTop = 0;", completionHandler: nil)
            if let pendingId = pendingScrollHighlightId {
                pendingScrollHighlightId = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    self?.scrollToHighlight(id: pendingId)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isPageReady = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isPageReady = false
        }
    }
}
