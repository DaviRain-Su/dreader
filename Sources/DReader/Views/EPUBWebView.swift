import SwiftUI
import WebKit

struct EPUBWebView: NSViewRepresentable {
    let chapterURL: URL
    let opfDirectory: URL
    let unzippedDirectory: URL
    let highlights: [Highlight]
    let hasNextChapter: Bool
    let nextChapterTitle: String?
    let settings: ReaderSettings
    let selectionManager: ReaderSelectionManager
    let onHighlightApplied: ((String, String) -> Void)?
    let onNextChapter: () -> Void
    let onPrevChapter: () -> Void
    let onScrollProgress: (Double) -> Void
    let registerScrollAction: (@escaping (Int) -> Void) -> Void
    let registerHighlightAction: (@escaping (String, String, String?) -> Void) -> Void
    let registerUpdateColorAction: (@escaping (String, String) -> Void) -> Void
    let registerUpdateThoughtAction: (@escaping (String, String?) -> Void) -> Void
    let registerRemoveHighlightAction: (@escaping (String) -> Void) -> Void
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
        context.coordinator.parent = self
        if context.coordinator.currentURL != chapterURL {
            context.coordinator.loadChapter(
                url: chapterURL,
                opfDir: opfDirectory,
                unzippedDir: unzippedDirectory,
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
        "\(settings.theme.rawValue)-\(settings.fontFamily.rawValue)-\(settings.fontSize)-\(settings.lineHeight)-\(settings.maxWidth)-\(settings.paragraphSpacing)-\(settings.isJustified)-\(settings.pageLayout.rawValue)-\(highlightsSummary)"
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: EPUBWebView
        weak var webView: WKWebView?
        var currentURL: URL?
        var currentOpfDir: URL?
        var isPageReady: Bool = false
        var lastSettingsSummary: String = ""

        init(_ parent: EPUBWebView) {
            self.parent = parent
        }

        func scrollPage(direction: Int) {
            if direction == 0 {
                webView?.evaluateJavaScript("window.scrollTo({ top: 0, behavior: 'smooth' }); document.body.scrollTop = 0; document.documentElement.scrollTop = 0;", completionHandler: nil)
            } else {
                webView?.evaluateJavaScript("window.dreaderScrollPage(\(direction));", completionHandler: nil)
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
            } else if let loaded = try? String(contentsOf: url, encoding: .utf8) {
                rawHTML = loaded
                parent.cacheHTML(loaded, url)
            } else if let loadedLatin = try? String(contentsOf: url, encoding: .isoLatin1) {
                rawHTML = loadedLatin
                parent.cacheHTML(loadedLatin, url)
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
                    hasNextChapter: hasNextChapter,
                    nextChapterTitle: nextChapterTitle
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
            if !highlights.isEmpty {
                bodyContent = EPUBThemeInjector.injectHighlights(in: bodyContent, highlights: highlights)
            }
            let headElements = EPUBThemeInjector.extractHeadElements(from: resolvedHTML)
            let endCard = EPUBThemeInjector.generateEndCardHTML(
                hasNextChapter: hasNextChapter,
                nextChapterTitle: nextChapterTitle,
                theme: settings.theme
            )

            let highlightItems: [[String: Any]] = highlights.map { h in
                [
                    "id": h.id.uuidString,
                    "text": h.text,
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
        }

        func applyHighlight(colorHex: String, id: String) {
            let script = "window.applyDReaderHighlight('\(colorHex)', '\(id)');"
            webView?.evaluateJavaScript(script) { [weak self] result, error in
                if let success = result as? Bool, success {
                    self?.parent.onHighlightApplied?(colorHex, id)
                }
            }
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
                } else if type == "nextChapter" {
                    self.parent.onNextChapter()
                } else if type == "prevChapter" {
                    self.parent.onPrevChapter()
                } else if type == "scrollProgress", let p = body["progress"] as? Double {
                    self.parent.onScrollProgress(p)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageReady = true
            updateStyles(settings: parent.settings)
            // Ensure first chapter starts cleanly at the top
            webView.evaluateJavaScript("window.scrollTo(0, 0); document.body.scrollTop = 0; document.documentElement.scrollTop = 0;", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isPageReady = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isPageReady = false
        }
    }
}
