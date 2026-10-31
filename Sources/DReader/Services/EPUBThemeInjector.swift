import Foundation

/// Injects high-grade typography CSS and selection event listeners into EPUB HTML
struct EPUBThemeInjector {
    static func generateInjectedHTML(
        rawHTML: String,
        chapterDir: URL,
        opfDir: URL,
        settings: ReaderSettings,
        highlights: [Highlight] = [],
        bilingualTranslations: [Int: String]? = nil,
        agentName: String = "AI 伴读",
        hasNextChapter: Bool = false,
        nextChapterTitle: String? = nil,
        bookTitle: String = "",
        chapterTitle: String = "",
        chapterIndex: Int = 0
    ) -> String {
        let resolvedHTML = resolveResourceURLs(in: rawHTML, chapterDir: chapterDir, opfDir: opfDir)
        let css = generateCSS(settings: settings)
        let js = generateJS()

        var bodyContent = extractBodyContent(from: resolvedHTML)
        bodyContent = sanitizeAndElevateLayout(bodyContent)

        // Chinese Script Conversion (繁体一键转简体 / 简体转繁体)
        if settings.chineseScriptMode != .original {
            bodyContent = ChineseScriptConverter.convertHTML(bodyContent, mode: settings.chineseScriptMode)
        }

        if !highlights.isEmpty {
            bodyContent = injectHighlights(in: bodyContent, highlights: highlights)
        }
        if settings.isBilingualEnabled {
            bodyContent = injectBilingualBlocks(
                in: bodyContent,
                translations: bilingualTranslations,
                agentName: agentName,
                theme: settings.theme
            )
        }
        let headElements = extractHeadElements(from: resolvedHTML)
        let displayBookTitle = ChineseScriptConverter.convert(bookTitle, mode: settings.chineseScriptMode)
        let displayChapterTitle = ChineseScriptConverter.convert(chapterTitle, mode: settings.chineseScriptMode)
        let displayNextChapterTitle = nextChapterTitle.map { ChineseScriptConverter.convert($0, mode: settings.chineseScriptMode) }

        let endCard = generateEndCardHTML(
            hasNextChapter: hasNextChapter,
            nextChapterTitle: displayNextChapterTitle,
            theme: settings.theme,
            bookTitle: displayBookTitle,
            chapterTitle: displayChapterTitle,
            chapterIndex: chapterIndex
        )

        let baseURL = chapterDir.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <base id="dreader-chapter-base" href="\(baseURL)">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <script id="dreader-injected-script">
            /*<![CDATA[*/
            \(js)
            /*]]>*/
            </script>
        </head>
        <body>
            <div id="dreader-chapter-styles">
                \(headElements)
            </div>
            <style id="dreader-injected-style">
            \(css)
            </style>
            <div id="dreader-chapter-body">
                \(bodyContent)
            </div>
            <div id="dreader-end-container">
                \(endCard)
            </div>
        </body>
        </html>
        """
    }

    /// Automatically resolves relative image paths, SVG image hrefs, and CSS asset URLs to absolute file:// URLs
    static func resolveResourceURLs(in rawHTML: String, chapterDir: URL, opfDir: URL) -> String {
        var html = rawHTML

        // 1. Resolve standard <img> tags
        let imgPattern = "(?i)(<img[^>]+src=[\"'])([^\"']+)([\"'])"
        html = replaceURLs(in: html, pattern: imgPattern, chapterDir: chapterDir, opfDir: opfDir)

        // 2. Resolve SVG <image> tags (href and xlink:href)
        let svgPattern = "(?i)(<image[^>]+(?:href|xlink:href)=[\"'])([^\"']+)([\"'])"
        html = replaceURLs(in: html, pattern: svgPattern, chapterDir: chapterDir, opfDir: opfDir)

        // 3. Resolve CSS url(...)
        let cssUrlPattern = "(?i)(url\\([\"']?)([^'\"\\)]+)([\"']?\\))"
        html = replaceURLs(in: html, pattern: cssUrlPattern, chapterDir: chapterDir, opfDir: opfDir)

        return html
    }

    private static func replaceURLs(in html: String, pattern: String, chapterDir: URL, opfDir: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        var result = html
        let ns = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let prefix = ns.substring(with: match.range(at: 1))
            let rawSrc = ns.substring(with: match.range(at: 2))
            let suffix = ns.substring(with: match.range(at: 3))

            // Ignore external and data URLs
            if rawSrc.starts(with: "http:") || rawSrc.starts(with: "https:") || rawSrc.starts(with: "data:") || rawSrc.starts(with: "file:") {
                continue
            }

            let cleanSrc = rawSrc.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? rawSrc
            let decodedSrc = cleanSrc.removingPercentEncoding ?? cleanSrc

            // Priority 1: Relative to chapter directory
            let candidate1 = chapterDir.appendingPathComponent(decodedSrc).standardizedFileURL
            // Priority 2: Relative to opf directory
            let candidate2 = opfDir.appendingPathComponent(decodedSrc).standardizedFileURL

            let resolvedURL: URL?
            if FileManager.default.fileExists(atPath: candidate1.path) {
                resolvedURL = candidate1
            } else if FileManager.default.fileExists(atPath: candidate2.path) {
                resolvedURL = candidate2
            } else {
                resolvedURL = candidate1
            }

            if let absURL = resolvedURL {
                let newSnippet = "\(prefix)\(absURL.absoluteString)\(suffix)"
                result = (result as NSString).replacingCharacters(in: match.range, with: newSnippet)
            }
        }
        return result
    }

    /// Injects <mark class="dreader-highlight"> and thought indicators into the HTML body
    static func injectHighlights(in bodyHTML: String, highlights: [Highlight]) -> String {
        var result = bodyHTML

        for h in highlights {
            let cleanText = h.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }
            let hasNote = (h.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let badgeHTML = hasNote ? "<span class=\"dreader-thought-dot\" title=\"查看想法\">💭</span>" : ""
            let markStart = "<mark class=\"dreader-highlight\" data-id=\"\(h.id.uuidString)\" data-color=\"\(h.colorHex)\" style=\"background-color: \(h.colorHex)40 !important; border-block-end: 2.5px solid \(h.colorHex) !important;\" onclick=\"window.dreaderClickHighlight('\(h.id.uuidString)', event)\">"
            let markEnd = "\(badgeHTML)</mark>"

            let escapedTarget = NSRegularExpression.escapedPattern(for: cleanText)
            if let regex = try? NSRegularExpression(pattern: escapedTarget, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                if let match = regex.firstMatch(in: result, options: [], range: range) {
                    let replacement = "\(markStart)\(cleanText)\(markEnd)"
                    result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                }
            }
        }
        return result
    }

    /// Injects dual-language interlinear translation cards or AI translation slots under each paragraph
    static func injectBilingualBlocks(
        in html: String,
        translations: [Int: String]?,
        agentName: String,
        theme: ReaderTheme
    ) -> String {
        let pPattern = "(?i)(<p\\b[^>]*>)([\\s\\S]*?)(</p>)"
        guard let regex = try? NSRegularExpression(pattern: pPattern, options: []) else { return html }

        var result = html
        let ns = result as NSString
        let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))

        // Process in reverse to preserve string indices
        for (idx, match) in matches.enumerated().reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let openTag = ns.substring(with: match.range(at: 1))
            let innerContent = ns.substring(with: match.range(at: 2))
            let closeTag = ns.substring(with: match.range(at: 3))

            let plainText = innerContent
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if plainText.count < 2 {
                continue
            }

            var newOpen = openTag
            if !newOpen.contains("data-dreader-para") {
                newOpen = newOpen.replacingOccurrences(of: ">", with: " data-dreader-para=\"\(idx)\">")
            }

            var bilingualBlock = ""
            if let trans = translations?[idx], !trans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bilingualBlock = """
                <div class="dreader-bilingual-trans" data-para-index="\(idx)">
                    <div class="dreader-bilingual-header">
                        <span class="dreader-bilingual-tag">译</span>
                        <span class="dreader-bilingual-agent">\(agentName) 译文</span>
                    </div>
                    <div class="dreader-bilingual-body">\(trans)</div>
                </div>
                """
            } else {
                bilingualBlock = """
                <div class="dreader-bilingual-slot" id="dreader-trans-slot-\(idx)" data-para-index="\(idx)">
                    <button class="dreader-bilingual-translate-btn" onclick="window.dreaderTranslateParagraph(\(idx), this)">
                        <span class="dreader-bilingual-icon">🌐</span>
                        <span>AI 伴读翻译</span>
                    </button>
                </div>
                """
            }

            let newSnippet = "\(newOpen)\(innerContent)\(closeTag)\(bilingualBlock)"
            result = (result as NSString).replacingCharacters(in: match.range, with: newSnippet)
        }

        return result
    }

    /// Extracts clean text of all paragraphs in the HTML for batch chapter translation
    static func extractParagraphsFromHTML(_ rawHTML: String) -> [(index: Int, text: String)] {
        let pPattern = "(?i)<p\\b[^>]*>([\\s\\S]*?)</p>"
        guard let regex = try? NSRegularExpression(pattern: pPattern, options: []) else { return [] }
        let ns = rawHTML as NSString
        let matches = regex.matches(in: rawHTML, options: [], range: NSRange(location: 0, length: ns.length))

        var results: [(index: Int, text: String)] = []
        for (idx, m) in matches.enumerated() {
            if m.numberOfRanges >= 2 {
                let inner = ns.substring(with: m.range(at: 1))
                let plain = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if plain.count >= 2 {
                    results.append((index: idx, text: plain))
                }
            }
        }
        return results
    }

    /// Intelligent Typesetting & Cleansing Engine for Chinese and public domain EPUBs:
    /// 1. Strips Project Gutenberg legal notices, headers, and footers.
    /// 2. Merges artificial 70-column hard newlines in CJK text to restore smooth, fluid paragraphs.
    /// 3. Replaces fullwidth period dots `．` with standard Chinese `。`.
    /// 4. Replaces long ASCII dashes `————` with typographic dividers.
    /// 5. Automatically detects and elevates chapter title paragraphs (`第一回...`) into elegant headings.
    static func sanitizeAndElevateLayout(_ html: String) -> String {
        var content = html

        // 1. Strip Project Gutenberg boilerplate containers
        let pgPattern = "(?i)<div[^>]*(?:class=[\"'][^\"']*pg-boilerplate[^\"']*[\"']|id=[\"']pg-(?:header|footer|machine-header|start-separator|end-separator)[\"'])[^>]*>[\\s\\S]*?<\\/div>"
        if let regex = try? NSRegularExpression(pattern: pgPattern, options: []) {
            content = regex.stringByReplacingMatches(in: content, options: [], range: NSRange(content.startIndex..., in: content), withTemplate: "")
        }

        // 2. Strip Project Gutenberg text banners if any left
        let bannerPattern = "\\*\\*\\*\\s*START OF (?:THE|THIS) PROJECT GUTENBERG[\\s\\S]*?\\*\\*\\*"
        if let regex = try? NSRegularExpression(pattern: bannerPattern, options: [.caseInsensitive]) {
            content = regex.stringByReplacingMatches(in: content, options: [], range: NSRange(content.startIndex..., in: content), withTemplate: "")
        }

        // 3. Remove long raw ASCII dashes (e.g. ————————————————————————————————-)
        let dashPattern = "[-—_~*]{8,}"
        if let regex = try? NSRegularExpression(pattern: dashPattern, options: []) {
            content = regex.stringByReplacingMatches(in: content, options: [], range: NSRange(content.startIndex..., in: content), withTemplate: "<div class=\"dreader-classic-divider\">❦</div>")
        }

        // 4. Merge artificial CJK linebreaks inside paragraphs
        // When a Chinese character is followed by a newline and another Chinese character, join them
        let cjkLinebreakPattern = "([\\u4e00-\\u9fa5\\u3000-\\u303f\\uff00-\\uffef])\\r?\\n\\s*([\\u4e00-\\u9fa5\\u3000-\\u303f\\uff00-\\uffef])"
        if let regex = try? NSRegularExpression(pattern: cjkLinebreakPattern, options: []) {
            content = regex.stringByReplacingMatches(in: content, options: [], range: NSRange(content.startIndex..., in: content), withTemplate: "$1$2")
        }

        // 5. Normalize archaic fullwidth period dot `．` to standard Chinese `。`
        content = content.replacingOccurrences(of: "．", with: "。")

        // 6. Elevate Chinese chapter headings (e.g. `<p id="...">第一回　甄士隱夢幻識通靈　賈雨村風塵怀閨秀</p>`)
        let headingPattern = "(?i)<p\\b[^>]*>\\s*(第[0-9一二三四五六七八九十百千]+[回章节卷部][^<]{0,60})\\s*<\\/p>"
        if let regex = try? NSRegularExpression(pattern: headingPattern, options: []) {
            let template = "<div class=\"dreader-chapter-title-container\"><h2 class=\"dreader-auto-chapter-heading\">$1</h2><div class=\"dreader-classic-divider\">✦ ❦ ✦</div></div>"
            content = regex.stringByReplacingMatches(in: content, options: [], range: NSRange(content.startIndex..., in: content), withTemplate: template)
        }

        // 7. Tag every substantive paragraph with a stable `data-dreader-para` index (in
        //    lockstep with EPUBThemeExtractor.extractParagraphs) so AI citations and other
        //    features can target paragraphs precisely without the bilingual mode being on.
        //    NOTE: every <p> consumes an index slot (matching the bilingual injector's
        //    enumeration scheme); only substantive ones actually receive the attribute.
        if let regex = try? NSRegularExpression(pattern: "(?i)(<p\\b[^>]*>)", options: []) {
            let ns = content as NSString
            var runningIndex = 0
            // Collect open tags first, then apply replacements in reverse order.
            var edits: [(range: NSRange, tag: String)] = []
            regex.enumerateMatches(in: content, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let paraIdx = runningIndex
                runningIndex += 1
                let openTag = ns.substring(with: match.range(at: 1))
                // Look ahead: is this paragraph substantive? Find the matching close tag cheaply.
                let remainingLength = ns.length - match.range.location
                if remainingLength <= 0 { return }
                let lookaheadRange = NSRange(location: match.range.location, length: min(remainingLength, 8000))
                let inner = ns.substring(with: lookaheadRange)
                guard let closeIdx = inner.range(of: "</p>", options: .caseInsensitive) else { return }
                let innerContent = String(inner[..<closeIdx.lowerBound])
                let plainText = innerContent
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard plainText.count >= 2 else { return }
                guard !openTag.contains("data-dreader-para") else { return }
                let attributedTag = openTag.replacingOccurrences(of: ">", with: " data-dreader-para=\"\(paraIdx)\">")
                edits.append((match.range(at: 1), attributedTag))
            }
            for edit in edits.reversed() {
                if edit.range.location != NSNotFound, edit.range.location + edit.range.length <= ns.length {
                    content = (content as NSString).replacingCharacters(in: edit.range, with: edit.tag)
                }
            }
        }

        return content
    }

    static func extractBodyContent(from rawHTML: String) -> String {
        if let bodyOpenRange = rawHTML.range(of: "<body", options: .caseInsensitive) {
            let rest = rawHTML[bodyOpenRange.lowerBound...]
            if let tagEnd = rest.range(of: ">") {
                let contentStart = tagEnd.upperBound
                if let bodyCloseRange = rawHTML.range(of: "</body>", options: .caseInsensitive, range: contentStart..<rawHTML.endIndex) {
                    return String(rawHTML[contentStart..<bodyCloseRange.lowerBound])
                } else {
                    return String(rawHTML[contentStart...])
                }
            }
        }
        return rawHTML
    }

    static func extractHeadElements(from rawHTML: String) -> String {
        var headStuff = ""
        let pattern = "(?i)(<style[\\s\\S]*?</style>|<link[^>]+rel=[\"']stylesheet[\"'][^>]*>)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = rawHTML as NSString
            let matches = regex.matches(in: rawHTML, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                headStuff += nsString.substring(with: match.range) + "\n"
            }
        }
        return headStuff
    }

    static func generateEndCardHTML(
        hasNextChapter: Bool,
        nextChapterTitle: String?,
        theme: ReaderTheme,
        bookTitle: String = "",
        chapterTitle: String = "",
        chapterIndex: Int = 0
    ) -> String {
        let briefing = ChapterBriefingService.shared.getBriefing(
            bookTitle: bookTitle,
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex
        )
        let socraticQuestion = briefing.socraticQuestions.first ?? "本章作者的核心论述，对你当前的认知带来了怎样的反思与启示？"
        let escapedQuestion = socraticQuestion
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")

        let socraticBlock = """
        <div class="dreader-socratic-container">
            <div class="dreader-socratic-badge">✦ 苏格拉底之问 · 章末启发思辨</div>
            <p class="dreader-socratic-question">“\(socraticQuestion)”</p>
            <div class="dreader-socratic-actions">
                <button class="dreader-socratic-thought-btn" onclick="window.dreaderAskAISocratic('\(escapedQuestion)')">
                    💬 与 AI 探讨此问题
                </button>
                <button class="dreader-socratic-write-btn" onclick="window.dreaderWriteSocraticThought('\(escapedQuestion)')">
                    ✍️ 记录我的思考与答案
                </button>
            </div>
        </div>
        """

        if hasNextChapter {
            let nextTitle = nextChapterTitle ?? "下一章节"
            return """
            <div class="dreader-chapter-end-container">
                \(socraticBlock)
                <div class="dreader-end-ornament">❦ ❦ ❦</div>
                <p class="dreader-end-title">本章阅读完成</p>
                <div class="dreader-end-buttons">
                    <button class="dreader-end-btn" onclick="window.dreaderGoNextChapter()">
                        <span>继续翻入下一章：\(nextTitle) ➔</span>
                    </button>
                </div>
            </div>
            """
        } else {
            return """
            <div class="dreader-chapter-end-container">
                \(socraticBlock)
                <div class="dreader-end-ornament">✦ ✦ ✦</div>
                <p class="dreader-end-title">🎉 全书已阅读完毕</p>
            </div>
            """
        }
    }

    static func generateCSS(settings: ReaderSettings) -> String {
        let theme = settings.theme
        let align = settings.isJustified ? "justify" : "left"
        let isSpread = settings.pageLayout == .spread
        // 双页对开走书页式右起（direction:rtl 列序，先读右页），与竖排互斥
        let isSpreadRTL = isSpread && !settings.isVertical
        let computedMaxWidth = isSpreadRTL ? 1920.0 : (isSpread ? 1160.0 : settings.maxWidth)
        let ruleColor = theme.isDark ? "rgba(255, 255, 255, 0.08)" : "rgba(0, 0, 0, 0.08)"

        let fontOverrideCSS: String
        if settings.fontFamily == .original || settings.fontFamily.cssFontFamily.isEmpty {
            fontOverrideCSS = ""
        } else {
            fontOverrideCSS = """
            html, body,
            #dreader-chapter-body,
            #dreader-chapter-body *:not(pre):not(code):not(kbd):not(samp):not(.dreader-code),
            #dreader-chapter-body p,
            #dreader-chapter-body div,
            #dreader-chapter-body span,
            #dreader-chapter-body li,
            #dreader-chapter-body a,
            #dreader-chapter-body blockquote,
            #dreader-chapter-body section,
            #dreader-chapter-body article,
            #dreader-chapter-body dd,
            #dreader-chapter-body dt,
            #dreader-chapter-body h1,
            #dreader-chapter-body h2,
            #dreader-chapter-body h3,
            #dreader-chapter-body h4,
            #dreader-chapter-body h5,
            #dreader-chapter-body h6,
            #dreader-chapter-body em,
            #dreader-chapter-body strong,
            #dreader-chapter-body b,
            #dreader-chapter-body i {
                font-family: \(settings.fontFamily.cssFontFamily) !important;
            }
            """
        }

        // 竖排（中文古籍）与横排共用主题色与字体，但排版轴整个旋转：
        // writing-mode: vertical-rl — 文字竖走、列从右到左、滚动变横向。
        let verticalCSS: String
        if settings.isVertical {
            let columnWidth = min(settings.maxWidth, 640.0)
            verticalCSS = """
            html {
                overflow-y: hidden !important;
                overflow-x: auto !important;
            }

            body {
                writing-mode: vertical-rl !important;
                -webkit-writing-mode: vertical-rl !important;
                height: 100vh !important;
                max-height: none !important;
                max-width: none !important;
                width: auto !important;
                margin: 0 !important;
                padding: \(settings.isZenMode ? "60px 48px 60px 120px" : "40px 32px 40px 96px") !important;
                box-sizing: border-box !important;
                word-break: normal !important;
            }

            /* 每列（即横排意义的"行"）宽度 = 版心高度感；行距 = 列间距 */
            #dreader-chapter-body {
                column-width: auto !important;
                line-height: \(max(settings.lineHeight, 1.7)) !important;
                height: 100% !important;
            }

            #dreader-chapter-body p,
            p {
                margin-top: 0 !important;
                margin-right: \(settings.paragraphSpacing)em !important;
                margin-bottom: 0 !important;
                text-indent: 2em !important;
                text-align: \(align == "justify" ? "justify" : "start") !important;
            }

            /* 标题：竖排下也保持右侧起始、纵向居中感 */
            #dreader-chapter-body h1, #dreader-chapter-body h2, #dreader-chapter-body h3,
            #dreader-chapter-body h4, #dreader-chapter-body h5, #dreader-chapter-body h6 {
                margin-top: 0 !important;
                margin-right: 1.2em !important;
                margin-bottom: 0 !important;
                text-align: start !important;
                letter-spacing: 0.18em !important;
            }

            /* 划线边线由 border-block-end 逻辑属性自动换向（调色板已统一），此处无需覆盖 */

            blockquote {
                border-left: none !important;
                border-right: 3px solid \(theme.accentColorHex) !important;
                padding-left: 0 !important;
                padding-right: 1.2em !important;
            }

            img, svg {
                max-height: 60vh !important;
                max-width: none !important;
            }

            /* 注入的章末卡片与脚注弹层保持横排可读 */
            .dreader-chapter-end-container,
            .dreader-socratic-container {
                writing-mode: horizontal-tb !important;
                -webkit-writing-mode: horizontal-tb !important;
                position: relative !important;
                margin-top: 3em !important;
            }

            ::-webkit-scrollbar { height: 10px; width: 10px; }
            ::-webkit-scrollbar-thumb { background: rgba(127,127,127,0.35); border-radius: 5px; }
            """
        } else if isSpreadRTL {
            // 双页对开（书页式右起）：滚动原点右置、列横向向左溢出续页，一屏正好两页；
            // 先读右页再读左页，与翻书同序。子级行文回归 LTR，只有容器 direction 决定列序。
            verticalCSS = """
            html {
                overflow-y: hidden !important;
                overflow-x: auto !important;
                direction: rtl !important;
            }

            body {
                height: 100vh !important;
                max-height: none !important;
                max-width: none !important;
                width: auto !important;
                margin: 0 !important;
                padding: 48px 32px !important;
                box-sizing: border-box !important;
            }

            #dreader-chapter-body {
                direction: rtl !important;
                height: 100% !important;
                column-count: 2 !important;
                column-gap: 64px !important;
                column-fill: auto !important;
                column-rule: 1px solid \(ruleColor) !important;
            }

            #dreader-chapter-body :where(p, div, span, h1, h2, h3, h4, h5, h6,
                li, ul, ol, blockquote, section, article, dd, dt, figure, figcaption, img, table, td) {
                direction: ltr !important;
            }

            ::-webkit-scrollbar { height: 10px; width: 10px; }
            ::-webkit-scrollbar-thumb { background: rgba(127,127,127,0.35); border-radius: 5px; }
            """
        } else {
            verticalCSS = ""
        }

        return """
        html {
            -webkit-overflow-scrolling: touch !important;
            overflow-y: scroll !important;
        }

        html, body {
            background-color: \(theme.backgroundColorHex) !important;
            color: \(theme.textColorHex) !important;
            margin: 0 !important;
            padding: 0 !important;
            -webkit-text-size-adjust: 100% !important;
        }

        body {
            font-size: \(settings.fontSize)px !important;
            line-height: \(settings.lineHeight) !important;
            max-width: \(computedMaxWidth)px !important;
            margin-left: auto !important;
            margin-right: auto !important;
            padding: \(settings.isZenMode ? "60px 48px 160px 48px" : "48px 32px 140px 32px") !important;
            text-rendering: optimizeSpeed !important;
            -webkit-font-smoothing: antialiased !important;
            word-break: break-word !important;
            hyphens: auto !important;
        }

        \(verticalCSS)

        /* High-Performance Virtualization for Large Chapters (竖排下禁用：横向分栏与 content-visibility 冲突) */
        #dreader-chapter-body > p,
        #dreader-chapter-body > div:not(.dreader-bilingual-trans):not(.dreader-bilingual-slot),
        #dreader-chapter-body > section,
        #dreader-chapter-body > blockquote {
            \(settings.isVertical || isSpreadRTL ? "content-visibility: visible;" : """
            content-visibility: auto;
            contain-intrinsic-size: 0 44px;
            """)
        }

        \(fontOverrideCSS)

        #dreader-chapter-body,
        #dreader-chapter-body p,
        #dreader-chapter-body div:not([class*="ornament"]):not([class*="btn"]):not([class*="container"]),
        #dreader-chapter-body li,
        #dreader-chapter-body blockquote,
        #dreader-chapter-body section,
        #dreader-chapter-body article,
        #dreader-chapter-body dd,
        #dreader-chapter-body dt {
            font-size: \(settings.fontSize)px !important;
            line-height: \(settings.lineHeight) !important;
            color: \(theme.textColorHex) !important;
        }

        #dreader-chapter-body span:not(.dreader-thought-dot) {
            color: inherit !important;
        }

        #dreader-chapter-body {
            transform: translateZ(0); /* Hardware accelerated compositing */
            will-change: scroll-position;
            \(isSpread ? """
            column-count: 2 !important;
            column-gap: 56px !important;
            column-rule: 1px solid \(ruleColor) !important;
            """ : "")
        }

        #dreader-chapter-body p,
        p {
            margin-top: 0 !important;
            margin-bottom: \(settings.paragraphSpacing)em !important;
            text-align: \(align) !important;
            text-indent: 2em !important;
        }

        #dreader-chapter-body h1, #dreader-chapter-body h2, #dreader-chapter-body h3, #dreader-chapter-body h4, #dreader-chapter-body h5, #dreader-chapter-body h6,
        h1, h2, h3, h4, h5, h6 {
            color: \(theme.textColorHex) !important;
            font-weight: 600 !important;
            line-height: 1.35 !important;
            margin-top: 2.2em !important;
            margin-bottom: 0.9em !important;
            text-indent: 0 !important;
            text-align: left !important;
        }

        #dreader-chapter-body h1, h1 { font-size: \(settings.fontSize * 1.65)px !important; }
        #dreader-chapter-body h2, h2 { font-size: \(settings.fontSize * 1.38)px !important; }
        #dreader-chapter-body h3, h3 { font-size: \(settings.fontSize * 1.2)px !important; }

        a {
            color: \(theme.accentColorHex) !important;
            text-decoration: none !important;
            border-bottom: 1px dotted \(theme.accentColorHex) !important;
        }

        blockquote {
            border-left: 3px solid \(theme.accentColorHex) !important;
            padding-left: 1.2em !important;
            margin: 1.5em 0 !important;
            color: \(theme.secondaryTextColorHex) !important;
            font-style: italic !important;
            text-indent: 0 !important;
        }

        img {
            max-width: 100% !important;
            height: auto !important;
            border-radius: 6px !important;
            display: block !important;
            margin: 1.8em auto !important;
            box-shadow: 0 4px 14px rgba(0,0,0,0.08) !important;
        }

        svg {
            max-width: 100% !important;
            height: auto !important;
            display: block !important;
            margin: 1.5em auto !important;
        }

        svg image {
            max-width: 100% !important;
            height: auto !important;
        }

        ::selection {
            background-color: \(theme.selectionColorHex) !important;
        }

        mark.dreader-highlight {
            display: inline !important;
            border-radius: 2px !important;
            padding: 1px 2px !important;
            margin: 0 1px !important;
            cursor: pointer !important;
            transition: all 0.15s ease !important;
            text-decoration: none !important;
            color: inherit !important;
        }

        /* 5 Distinctive Highlighting Palettes (WeChat Read style)
           border-block-end 逻辑属性：横排=下边线，竖排(vertical-rl)=左侧竖线，一套代码两向适配 */
        mark.dreader-highlight[data-color="#FFE066"],
        mark.dreader-highlight:not([data-color]) {
            background-color: rgba(255, 224, 102, 0.35) !important;
            border-block-end: 2.5px solid #FFE066 !important;
        }

        mark.dreader-highlight[data-color="#99E9F2"] {
            background-color: rgba(153, 233, 242, 0.35) !important;
            border-block-end: 2.5px solid #99E9F2 !important;
        }

        mark.dreader-highlight[data-color="#A5D8FF"] {
            background-color: rgba(165, 216, 255, 0.35) !important;
            border-block-end: 2.5px solid #A5D8FF !important;
        }

        mark.dreader-highlight[data-color="#E599F7"] {
            background-color: rgba(229, 153, 247, 0.35) !important;
            border-block-end: 2.5px solid #E599F7 !important;
        }

        mark.dreader-highlight[data-color="#FFC078"] {
            background-color: rgba(255, 192, 120, 0.35) !important;
            border-block-end: 2.5px solid #FFC078 !important;
        }

        mark.dreader-highlight:hover {
            filter: brightness(0.92) !important;
            box-shadow: 0 2px 6px rgba(0,0,0,0.15) !important;
        }

        .dreader-thought-dot {
            display: inline-block !important;
            font-size: 13px !important;
            line-height: 1 !important;
            margin-block-start: 3px !important;
            margin-block-end: 2px !important;
            cursor: pointer !important;
            filter: drop-shadow(0 1px 2px rgba(0,0,0,0.3)) !important;
            transition: transform 0.15s ease !important;
        }

        .dreader-thought-dot:hover {
            transform: scale(1.3) !important;
        }

        /* End of Chapter Transition Card */
        .dreader-chapter-end-container {
            margin-top: 60px !important;
            padding: 30px 20px 80px 20px !important;
            text-align: center !important;
            border-top: 1px dashed rgba(128, 128, 128, 0.2) !important;
        }

        /* Socratic Companion Card */
        .dreader-socratic-container {
            max-width: 620px !important;
            margin: 0 auto 36px auto !important;
            padding: 22px 26px !important;
            background: rgba(147, 51, 234, 0.05) !important;
            border: 1px solid rgba(147, 51, 234, 0.22) !important;
            border-radius: 14px !important;
            text-align: left !important;
            box-shadow: 0 4px 18px rgba(0, 0, 0, 0.04) !important;
        }

        .dreader-socratic-badge {
            display: inline-block !important;
            font-size: 11px !important;
            font-weight: 700 !important;
            letter-spacing: 0.5px !important;
            color: #9333ea !important;
            background: rgba(147, 51, 234, 0.12) !important;
            padding: 3px 8px !important;
            border-radius: 6px !important;
            margin-bottom: 12px !important;
        }

        .dreader-socratic-question {
            font-size: 14.5px !important;
            line-height: 1.6 !important;
            color: inherit !important;
            font-style: italic !important;
            margin: 0 0 16px 0 !important;
            text-indent: 0 !important;
        }

        .dreader-socratic-actions {
            display: flex !important;
            gap: 10px !important;
            flex-wrap: wrap !important;
        }

        .dreader-socratic-thought-btn {
            display: inline-flex !important;
            align-items: center !important;
            gap: 6px !important;
            padding: 7px 15px !important;
            font-size: 12px !important;
            font-weight: 600 !important;
            color: #ffffff !important;
            background-color: #9333ea !important;
            border: none !important;
            border-radius: 20px !important;
            cursor: pointer !important;
            transition: all 0.18s ease !important;
        }

        .dreader-socratic-thought-btn:hover {
            transform: translateY(-1px) !important;
            box-shadow: 0 3px 10px rgba(147, 51, 234, 0.3) !important;
        }

        .dreader-socratic-write-btn {
            display: inline-flex !important;
            align-items: center !important;
            gap: 6px !important;
            padding: 7px 15px !important;
            font-size: 12px !important;
            font-weight: 500 !important;
            color: #9333ea !important;
            background-color: rgba(147, 51, 234, 0.08) !important;
            border: 1px solid rgba(147, 51, 234, 0.25) !important;
            border-radius: 20px !important;
            cursor: pointer !important;
            transition: all 0.18s ease !important;
        }

        .dreader-socratic-write-btn:hover {
            background-color: rgba(147, 51, 234, 0.15) !important;
        }

        .dreader-end-ornament {
            font-size: 16px !important;
            letter-spacing: 8px !important;
            color: \(theme.accentColorHex) !important;
            opacity: 0.6 !important;
            margin-bottom: 12px !important;
        }

        .dreader-end-title {
            font-size: 14px !important;
            color: \(theme.secondaryTextColorHex) !important;
            margin-bottom: 24px !important;
            text-indent: 0 !important;
            text-align: center !important;
        }

        .dreader-end-btn {
            display: inline-flex !important;
            align-items: center !important;
            justify-content: center !important;
            gap: 8px !important;
            padding: 12px 28px !important;
            font-size: 14px !important;
            font-weight: 600 !important;
            color: #ffffff !important;
            background-color: \(theme.accentColorHex) !important;
            border: none !important;
            border-radius: 24px !important;
            cursor: pointer !important;
            box-shadow: 0 4px 16px rgba(0,0,0,0.12) !important;
            transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1) !important;
        }

        .dreader-end-btn:hover {
            transform: translateY(-2px) scale(1.02) !important;
            box-shadow: 0 6px 20px rgba(0,0,0,0.18) !important;
        }

        .dreader-end-btn:active {
            transform: translateY(0) scale(0.98) !important;
        }

        /* Bilingual Interlinear Typography (Apple Books Style) */
        .dreader-bilingual-trans {
            display: block !important;
            margin: 8px 0 20px 0 !important;
            padding: 10px 14px !important;
            background-color: \(theme.isDark ? "rgba(255, 255, 255, 0.05)" : "rgba(0, 0, 0, 0.028)") !important;
            border-left: 3px solid \(theme.accentColorHex) !important;
            border-radius: 6px !important;
            font-size: 0.9em !important;
            line-height: 1.68 !important;
            color: \(theme.secondaryTextColorHex) !important;
            transition: all 0.2s ease-in-out !important;
            animation: dreader-bilingual-appear 0.25s ease-out !important;
        }

        @keyframes dreader-bilingual-appear {
            0% { opacity: 0; transform: translateY(-4px); }
            100% { opacity: 1; transform: translateY(0); }
        }

        .dreader-bilingual-header {
            display: flex !important;
            align-items: center !important;
            gap: 6px !important;
            margin-bottom: 5px !important;
            user-select: none !important;
        }

        .dreader-bilingual-tag {
            display: inline-flex !important;
            align-items: center !important;
            justify-content: center !important;
            width: 15px !important;
            height: 15px !important;
            font-size: 9.5px !important;
            font-weight: 700 !important;
            color: #ffffff !important;
            background: linear-gradient(135deg, #4F46E5, #7C3AED) !important;
            border-radius: 3px !important;
        }

        .dreader-bilingual-agent {
            font-size: 10.5px !important;
            font-weight: 500 !important;
            color: \(theme.accentColorHex) !important;
            opacity: 0.9 !important;
        }

        .dreader-bilingual-body {
            font-size: inherit !important;
            color: inherit !important;
            line-height: inherit !important;
            text-indent: 0 !important;
        }

        .dreader-bilingual-slot {
            display: flex !important;
            align-items: center !important;
            margin: 4px 0 16px 0 !important;
        }

        .dreader-bilingual-translate-btn {
            display: inline-flex !important;
            align-items: center !important;
            gap: 5px !important;
            padding: 3.5px 11px !important;
            font-size: 11px !important;
            font-weight: 500 !important;
            color: \(theme.accentColorHex) !important;
            background-color: \(theme.isDark ? "rgba(255, 255, 255, 0.06)" : "rgba(0, 0, 0, 0.035)") !important;
            border: 1px solid \(theme.accentColorHex)40 !important;
            border-radius: 12px !important;
            cursor: pointer !important;
            transition: all 0.18s ease !important;
        }

        .dreader-bilingual-translate-btn:hover {
            background-color: \(theme.accentColorHex)20 !important;
            border-color: \(theme.accentColorHex)90 !important;
            transform: translateY(-1px) !important;
        }

        .dreader-bilingual-translate-btn:disabled {
            opacity: 0.65 !important;
            cursor: default !important;
        }

        /* Apple Books Style Search Match Glowing Halo */
        .dreader-search-halo {
            background-color: #FFE066 !important;
            color: #1a1a1a !important;
            padding: 2px 4px !important;
            border-radius: 4px !important;
            box-shadow: 0 0 0 3px rgba(255, 215, 0, 0.65), 0 0 16px rgba(255, 180, 0, 0.5) !important;
            animation: dreader-search-pulse 1.6s infinite alternate ease-in-out !important;
        }

        @keyframes dreader-search-pulse {
            0% {
                box-shadow: 0 0 0 2px rgba(255, 215, 0, 0.4), 0 0 8px rgba(255, 180, 0, 0.3);
            }
            100% {
                box-shadow: 0 0 0 5px rgba(255, 215, 0, 0.8), 0 0 22px rgba(255, 180, 0, 0.6);
            }
        }

        /* Classical Chinese & Clean Typesetting Engine Rules */
        .dreader-chapter-title-container {
            text-align: center !important;
            margin-top: 2.8em !important;
            margin-bottom: 2em !important;
        }

        .dreader-auto-chapter-heading {
            text-align: center !important;
            font-size: 1.55em !important;
            font-weight: 700 !important;
            line-height: 1.45 !important;
            margin: 0 !important;
            text-indent: 0 !important;
            letter-spacing: 0.1em !important;
            color: \(theme.textColorHex) !important;
        }

        .dreader-classic-divider {
            text-align: center !important;
            color: \(theme.secondaryTextColorHex) !important;
            opacity: 0.65 !important;
            margin: 1.2em auto !important;
            font-size: 1.05em !important;
            letter-spacing: 0.3em !important;
            user-select: none !important;
        }

        .dreader-poem-block {
            text-align: center !important;
            margin: 1.8em auto !important;
            padding: 1.2em 2em !important;
            background: \(theme.isDark ? "rgba(255,255,255,0.03)" : "rgba(0,0,0,0.02)") !important;
            border-radius: 8px !important;
        }

        /* Hide all Project Gutenberg and raw OCR boilerplate disclaimers */
        .pg-boilerplate,
        #pg-header,
        #pg-footer,
        #pg-start-separator,
        #pg-end-separator,
        [id*="pg-header"],
        [id*="pg-footer"] {
            display: none !important;
            visibility: hidden !important;
            height: 0 !important;
            overflow: hidden !important;
        }
        """
    }

    static func generateJS() -> String {
        return """
        (function() {
            // 模板和 WKUserScript 都会加载此脚本，只注册一套事件监听。
            if (window.dreaderReaderReady) return;
            let lastSelectedText = '';

            function notifySelection() {
                const sel = window.getSelection();
                if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
                    if (lastSelectedText !== '') {
                        lastSelectedText = '';
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                            window.webkit.messageHandlers.selectionBridge.postMessage({
                                type: 'clear'
                            });
                        }
                    }
                    return;
                }

                const text = sel.toString().trim();
                if (text.length === 0) return;

                lastSelectedText = text;
                const range = sel.getRangeAt(0);
                const rect = range.getBoundingClientRect();

                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                    window.webkit.messageHandlers.selectionBridge.postMessage({
                        type: 'selection',
                        text: text,
                        x: rect.x + (rect.width / 2),
                        y: rect.y,
                        bottomY: rect.bottom,
                        width: rect.width,
                        height: rect.height
                    });
                }
            }

            document.addEventListener('mouseup', function(e) {
                setTimeout(notifySelection, 20);
            });

            document.addEventListener('keyup', function(e) {
                setTimeout(notifySelection, 50);
            });

            // Smooth Page Scrolling Function (vertical-rl 古籍竖排时滚动轴为横向 scrollLeft)
            window.dreaderIsVertical = function() {
                return document.body && (getComputedStyle(document.body).writingMode || '').startsWith('vertical');
            };

            // 双页对开（横排文字 + direction:rtl 的列序，右页先读）：与竖排共用横轴负 scrollLeft
            window.dreaderIsSpreadRTL = function() {
                if (window.dreaderIsVertical()) return false;
                return document.body && getComputedStyle(document.body).direction === 'rtl';
            };

            // WebKit 的 vertical-rl 从 0 向负 scrollLeft 前进，统一转换为正的阅读距离。
            window.dreaderScrollMetrics = function() {
                const vertical = window.dreaderIsVertical();
                const rtlH = window.dreaderIsSpreadRTL();
                const horizontal = vertical || rtlH;
                const root = document.scrollingElement || document.documentElement;
                const maxScroll = horizontal
                    ? Math.max(0, root.scrollWidth - window.innerWidth)
                    : Math.max(0, root.scrollHeight - window.innerHeight);
                const rawScroll = horizontal ? root.scrollLeft : root.scrollTop;
                const currentScroll = Math.max(0, Math.min(maxScroll, horizontal ? -rawScroll : rawScroll));
                return { vertical: vertical, rtlH: rtlH, horizontal: horizontal, currentScroll: currentScroll, maxScroll: maxScroll };
            };

            window.dreaderScrollToStart = function() {
                window.scrollTo({ left: 0, top: 0, behavior: 'instant' });
            };

            // 阅读位置按正比例恢复；竖排/双页从右向左的负 scrollLeft 与普通横排共用同一进度。
            window.dreaderScrollToProgress = function(progress) {
                if (!Number.isFinite(progress)) return false;
                const metrics = window.dreaderScrollMetrics();
                const clamped = Math.max(0, Math.min(1, progress));
                const distance = clamped * metrics.maxScroll;
                const horizontal = metrics.horizontal;
                window.scrollTo({
                    left: horizontal ? -distance : 0,
                    top: horizontal ? 0 : distance,
                    behavior: 'instant'
                });
                return true;
            };

            window.dreaderScrollPage = function(direction) {
                if (direction === 0) { window.dreaderScrollToStart(); return; }
                const metrics = window.dreaderScrollMetrics();
                const horizontal = metrics.horizontal;
                const vertical = metrics.vertical;
                // 竖排保持 0.82 的重读重叠；双页对开一屏正好两页，整屏推进才是翻书的感觉
                const pageAdvance = vertical
                    ? window.innerWidth * 0.82
                    : (metrics.rtlH ? window.innerWidth : window.innerHeight);
                const currentScroll = metrics.currentScroll;
                const maxScroll = metrics.maxScroll;

                if (direction > 0) {
                    if (currentScroll >= maxScroll - 30) {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                            window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'nextChapter' });
                        }
                        return;
                    }
                    if (horizontal) {
                        // 竖排/双页对开从右向左读：前进 = 向左滚动
                        window.scrollBy({ left: -pageAdvance, behavior: 'smooth' });
                    } else {
                        window.scrollBy({ top: pageAdvance, behavior: 'smooth' });
                    }
                } else {
                    if (currentScroll <= 30) {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                            window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'prevChapter' });
                        }
                        return;
                    }
                    if (horizontal) {
                        window.scrollBy({ left: pageAdvance, behavior: 'smooth' });
                    } else {
                        window.scrollBy({ top: -pageAdvance, behavior: 'smooth' });
                    }
                }
            };

            // 仿真翻页规划：到页内边界时返回本次滚动偏移（足够滑满一屏）；
            // willTurn=false 表示还在页中（普通平滑滚动即可）或需要翻章（走 DOM 切换，不套平移动画）
            window.dreaderPageTurnPlan = function(direction) {
                const metrics = window.dreaderScrollMetrics();
                const vertical = metrics.vertical;
                const horizontal = metrics.horizontal;
                // 竖排 0.82 重读重叠；双页对开一屏正好两页（offset 由 Swift 快照动画配合平移）
                const pageSize = vertical
                    ? window.innerWidth * 0.82
                    : (metrics.rtlH ? window.innerWidth : window.innerHeight);
                const currentScroll = metrics.currentScroll;
                const maxScroll = metrics.maxScroll;
                const atEnd = direction > 0
                    ? currentScroll >= maxScroll - 30
                    : currentScroll <= 30;
                if (atEnd) {
                    return { willTurn: false }; // 边界 → 翻章，走既有 DOM 切换路径
                }
                // 页内整页跳：偏移取页长，但不超过边界（避免跳过头露白）；余量太小则不做整页翻（滑出一整页却只挪了几十像素很怪）
                let offset = pageSize;
                if ((direction > 0 ? (maxScroll - currentScroll) : currentScroll) < 40) {
                    return { willTurn: false };
                }
                if (direction > 0) {
                    offset = Math.min(pageSize, maxScroll - currentScroll);
                } else {
                    offset = Math.min(pageSize, currentScroll);
                }
                return { willTurn: true, offset: offset, vertical: vertical, rtlH: metrics.rtlH, axis: horizontal ? 'x' : 'y' };
            };

            window.dreaderGoNextChapter = function() {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                    window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'nextChapter' });
                }
            };

            window.dreaderGoPrevChapter = function() {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                    window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'prevChapter' });
                }
            };

            window.dreaderAskAISocratic = function(question) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                    window.webkit.messageHandlers.selectionBridge.postMessage({
                        type: 'socraticAI',
                        question: question
                    });
                }
            };

            window.dreaderWriteSocraticThought = function(question) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                    window.webkit.messageHandlers.selectionBridge.postMessage({
                        type: 'socraticThought',
                        question: question
                    });
                }
            };

            // ===== Line Guide 行引导线（Apple Books 同款：跟随视线的一条淡线防长行串行）=====
            // 横排：淡横线吸附到鼠标所在文本行底线 + 该行轻微提亮；竖排（vertical-rl）：淡竖线跟随所在列。
            let dreaderGuideState = { enabled: false, color: '#888888' };

            window.dreaderSetLineGuide = function(enabled, colorHex) {
                dreaderGuideState.enabled = !!enabled;
                dreaderGuideState.color = colorHex || '#888888';
                const line = document.getElementById('dreader-line-guide');
                const row = document.getElementById('dreader-line-guide-row');
                if (!dreaderGuideState.enabled) {
                    if (line) line.remove();
                    if (row) row.remove();
                    document.removeEventListener('mousemove', dreaderGuideOnMove, true);
                    return;
                }
                if (!line) {
                    const l = document.createElement('div');
                    l.id = 'dreader-line-guide';
                    const r = document.createElement('div');
                    r.id = 'dreader-line-guide-row';
                    document.body.appendChild(r);
                    document.body.appendChild(l);
                }
                document.removeEventListener('mousemove', dreaderGuideOnMove, true);
                document.addEventListener('mousemove', dreaderGuideOnMove, true);
            };

            function dreaderGuideOnMove(e) {
                if (!dreaderGuideState.enabled) return;
                const line = document.getElementById('dreader-line-guide');
                const row = document.getElementById('dreader-line-guide-row');
                if (!line || !row) return;

                const vertical = window.dreaderIsVertical ? window.dreaderIsVertical() : false;
                // 选区标注时不画（干扰划线手势）
                const sel = window.getSelection();
                if (sel && !sel.isCollapsed) {
                    line.style.opacity = '0';
                    row.style.opacity = '0';
                    return;
                }

                const range = document.caretRangeFromPoint(e.clientX, e.clientY);
                if (!range || !range.startContainer) {
                    line.style.opacity = '0'; row.style.opacity = '0'; return;
                }
                let el = range.startContainer;
                if (el.nodeType === 3) el = el.parentElement;
                if (!el || !(el instanceof Element) || el.closest('#dreader-line-guide, #dreader-line-guide-row')) {
                    line.style.opacity = '0'; row.style.opacity = '0'; return;
                }

                // 用整个元素的 Range 得到逐行矩形，找鼠标命中的那一行
                const rng = document.createRange();
                rng.selectNodeContents(el);
                const rects = Array.from(rng.getClientRects()).filter(function(r) { return r.height > 0 && r.width > 0; });
                if (!rects.length) { line.style.opacity = '0'; row.style.opacity = '0'; return; }

                let hit = null;
                for (const r of rects) {
                    if (e.clientY >= r.top && e.clientY <= r.bottom && e.clientX >= r.left - 2 && e.clientX <= r.right + 2) { hit = r; break; }
                }
                if (!hit) {
                    hit = rects.reduce(function(best, r) {
                        const dR = Math.abs(r.top + r.height / 2 - e.clientY) + Math.abs(r.left + r.width / 2 - e.clientX);
                        const dB = best ? (Math.abs(best.top + best.height / 2 - e.clientY) + Math.abs(best.left + best.width / 2 - e.clientX)) : 1e9;
                        return dR < dB ? r : best;
                    }, null);
                }
                if (!hit) { line.style.opacity = '0'; row.style.opacity = '0'; return; }

                const c = dreaderGuideState.color;
                if (vertical) {
                    // 竖排：列框 + 列右缘竖线（阅读起始侧）
                    row.style.cssText = 'position:fixed;pointer-events:none;z-index:9997;border-radius:2px;' +
                        'left:' + hit.left + 'px;top:' + hit.top + 'px;width:' + hit.width + 'px;height:' + hit.height + 'px;' +
                        'background:rgba(128,128,128,0.06);opacity:1;transition:opacity .18s;';
                    line.style.cssText = 'position:fixed;pointer-events:none;z-index:9998;' +
                        'left:' + (hit.right - 1) + 'px;top:' + hit.top + 'px;width:1px;height:' + hit.height + 'px;' +
                        'background:' + c + ';opacity:0.22;transition:opacity .18s,left .06s,top .06s,height .06s;';
                } else {
                    // 横排：行框 + 行底线下 3px 的横线
                    row.style.cssText = 'position:fixed;pointer-events:none;z-index:9997;border-radius:2px;' +
                        'left:' + hit.left + 'px;top:' + hit.top + 'px;width:' + hit.width + 'px;height:' + hit.height + 'px;' +
                        'background:rgba(128,128,128,0.06);opacity:1;transition:opacity .18s;';
                    line.style.cssText = 'position:fixed;pointer-events:none;z-index:9998;' +
                        'left:' + hit.left + 'px;top:' + (hit.bottom + 2) + 'px;width:' + hit.width + 'px;height:1px;' +
                        'background:' + c + ';opacity:0.22;transition:opacity .18s,left .06s,top .06s,width .06s;';
                }
            };

            // Keyboard Shortcuts for Space, PageDown, PageUp, Arrow Keys
            document.addEventListener('keydown', function(e) {
                if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable) return;

                if (e.key === ' ' || e.code === 'Space') {
                    e.preventDefault();
                    window.dreaderScrollPage(e.shiftKey ? -1 : 1);
                } else if (e.key === 'PageDown') {
                    e.preventDefault();
                    window.dreaderScrollPage(1);
                } else if (e.key === 'PageUp') {
                    e.preventDefault();
                    window.dreaderScrollPage(-1);
                } else if (e.key === 'ArrowRight') {
                    e.preventDefault();
                    // 竖排（vertical-rl）下向左是前进，向右是后退；横排相反
                    const vertical = window.dreaderIsVertical ? window.dreaderIsVertical() : false;
                    if (vertical) {
                        window.dreaderScrollPage(-1);
                    } else {
                        window.dreaderGoNextChapter();
                    }
                } else if (e.key === 'ArrowLeft') {
                    e.preventDefault();
                    const vertical = window.dreaderIsVertical ? window.dreaderIsVertical() : false;
                    if (vertical) {
                        window.dreaderScrollPage(1);
                    } else {
                        window.dreaderGoPrevChapter();
                    }
                } else if (e.key === 'ArrowDown') {
                    const vertical = window.dreaderIsVertical ? window.dreaderIsVertical() : false;
                    if (vertical) { e.preventDefault(); window.dreaderScrollPage(1); }
                } else if (e.key === 'ArrowUp') {
                    const vertical = window.dreaderIsVertical ? window.dreaderIsVertical() : false;
                    if (vertical) { e.preventDefault(); window.dreaderScrollPage(-1); }
                } else if ((e.key === 'h' || e.key === 'H') && !e.metaKey && !e.ctrlKey && !e.altKey) {
                    // 键盘标注流：H = 高亮选区（webview 聚焦时 here 生效；SwiftUI onKeyPress 是另一条兜底路径）
                    e.preventDefault();
                    const sel = window.getSelection();
                    if (sel && !sel.isCollapsed) {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                            window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'keyboardHighlight' });
                        }
                    } else {
                        // 无选区不静默：交给 Swift 侧弹轻提示
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                            window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'keyboardHighlight', noSelection: true });
                        }
                    }
                } else if ((e.key === 'n' || e.key === 'N') && !e.metaKey && !e.ctrlKey && !e.altKey) {
                    // N = 高亮并写想法
                    e.preventDefault();
                    const sel = window.getSelection();
                    if (sel && !sel.isCollapsed) {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                            window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'keyboardThought' });
                        }
                    } else {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                            window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'keyboardThought', noSelection: true });
                        }
                    }
                }
            });

            // 合并滚动上报；窗口被遮挡时 WebKit 会暂停动画帧，定时器仍能回传进度。
            let scrollReportDelay = 80;
            let scrollReportTimer = null;
            let lastReportedPct = -1.0;
            window.addEventListener('scroll', function() {
                if (scrollReportTimer !== null) return;
                scrollReportTimer = setTimeout(function() {
                    scrollReportTimer = null;
                    const metrics = window.dreaderScrollMetrics();
                    const pct = metrics.currentScroll / Math.max(1, metrics.maxScroll);
                    // Only send IPC bridge message if progress changed by at least 1% (or reached boundaries)
                    if (Math.abs(pct - lastReportedPct) >= 0.01 || (pct === 0 && lastReportedPct !== 0) || (pct === 1 && lastReportedPct !== 1)) {
                        lastReportedPct = pct;
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                            window.webkit.messageHandlers.selectionBridge.postMessage({
                                type: 'scrollProgress',
                                progress: pct
                            });
                        }
                    }
                }, scrollReportDelay);
            }, { passive: true });

            // Instant Client-Side Highlight Function
            window.dreaderApplyHighlight = function(colorHex, highlightId, note) {
                const sel = window.getSelection();
                if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return false;

                const range = sel.getRangeAt(0);
                const mark = document.createElement('mark');
                mark.className = 'dreader-highlight';
                mark.setAttribute('data-id', highlightId || '');
                mark.setAttribute('data-color', colorHex || '#FFE066');
                mark.style.setProperty('background-color', (colorHex || '#FFE066') + '40', 'important');
                mark.style.setProperty('border-block-end', '2.5px solid ' + (colorHex || '#FFE066'), 'important');
                mark.onclick = function(e) {
                    window.dreaderClickHighlight(highlightId, e);
                };

                try {
                    const contents = range.extractContents();
                    mark.appendChild(contents);
                    if (note && note.trim().length > 0) {
                        const dot = document.createElement('span');
                        dot.className = 'dreader-thought-dot';
                        dot.innerText = '💭';
                        dot.title = '查看想法';
                        mark.appendChild(dot);
                    }
                    range.insertNode(mark);
                    sel.removeAllRanges();
                    notifySelection();
                    return true;
                } catch(e) {
                    console.error('Highlight error:', e);
                    return false;
                }
            };

            // Update color in real-time
            window.dreaderUpdateHighlightColor = function(id, colorHex) {
                const el = document.querySelector('mark[data-id="' + id + '"]');
                if (el) {
                    el.setAttribute('data-color', colorHex);
                    el.style.setProperty('background-color', colorHex + '40', 'important');
                    el.style.setProperty('border-block-end', '2.5px solid ' + colorHex, 'important');
                }
            };

            // Update thought bubble in real-time
            window.dreaderUpdateHighlightThought = function(id, note) {
                const el = document.querySelector('mark[data-id="' + id + '"]');
                if (!el) return;
                let dot = el.querySelector('.dreader-thought-dot');
                if (note && note.trim().length > 0) {
                    if (!dot) {
                        dot = document.createElement('span');
                        dot.className = 'dreader-thought-dot';
                        dot.innerText = '💭';
                        dot.title = '查看想法';
                        el.appendChild(dot);
                    }
                } else {
                    if (dot) dot.remove();
                }
            };

            // Remove highlight and unwrap text
            window.dreaderRemoveHighlight = function(id) {
                const el = document.querySelector('mark[data-id="' + id + '"]');
                if (!el) return;
                const dot = el.querySelector('.dreader-thought-dot');
                if (dot) dot.remove();
                const parent = el.parentNode;
                if (!parent) return;
                while (el.firstChild) {
                    parent.insertBefore(el.firstChild, el);
                }
                parent.removeChild(el);
                parent.normalize();
            };

            // Highlight arbitrary text in the rendered DOM (Robust matching for reopening / switching)
            window.dreaderHighlightTextInDOM = function(searchText, id, colorHex, note) {
                if (!searchText) return;
                const bodyEl = document.getElementById('dreader-chapter-body') || document.body;
                if (document.querySelector('mark[data-id="' + id + '"]')) return;

                function normalize(s) {
                    return (s || '').replace(/\\s+/g, ' ').trim();
                }
                const normTarget = normalize(searchText);
                if (!normTarget) return;

                const walker = document.createTreeWalker(bodyEl, NodeFilter.SHOW_TEXT, null, false);
                let node;
                const textNodes = [];
                while (node = walker.nextNode()) {
                    const p = node.parentElement;
                    if (p && (p.tagName === 'SCRIPT' || p.tagName === 'STYLE' || p.closest('mark.dreader-highlight'))) {
                        continue;
                    }
                    textNodes.push(node);
                }

                function wrapRange(range) {
                    const mark = document.createElement('mark');
                    mark.className = 'dreader-highlight';
                    mark.setAttribute('data-id', id);
                    mark.setAttribute('data-color', colorHex);
                    mark.style.setProperty('background-color', colorHex + '40', 'important');
                    mark.style.setProperty('border-block-end', '2.5px solid ' + colorHex, 'important');
                    mark.onclick = function(e) { window.dreaderClickHighlight(id, e); };
                    try {
                        mark.appendChild(range.extractContents());
                        if (note && note.trim().length > 0) {
                            const dot = document.createElement('span');
                            dot.className = 'dreader-thought-dot';
                            dot.innerText = '💭';
                            dot.title = '查看想法';
                            mark.appendChild(dot);
                        }
                        range.insertNode(mark);
                        return true;
                    } catch(e) {
                        return false;
                    }
                }

                // 1. Single text node exact match
                for (let i = 0; i < textNodes.length; i++) {
                    const tn = textNodes[i];
                    const val = tn.nodeValue || '';
                    const idx = val.indexOf(searchText);
                    if (idx !== -1) {
                        const range = document.createRange();
                        range.setStart(tn, idx);
                        range.setEnd(tn, idx + searchText.length);
                        if (wrapRange(range)) return;
                    }
                }

                // 2. Single text node flexible whitespace match
                for (let i = 0; i < textNodes.length; i++) {
                    const tn = textNodes[i];
                    const val = tn.nodeValue || '';
                    const normVal = normalize(val);
                    if (normVal.indexOf(normTarget) !== -1) {
                        const escaped = normTarget.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\s+/g, '\\\\s+');
                        const regex = new RegExp(escaped, 'i');
                        const match = regex.exec(val);
                        if (match) {
                            const range = document.createRange();
                            range.setStart(tn, match.index);
                            range.setEnd(tn, match.index + match[0].length);
                            if (wrapRange(range)) return;
                        }
                    }
                }

                // 3. Multi-node matching across inline tags
                let fullText = '';
                const nodeMap = [];
                for (let i = 0; i < textNodes.length; i++) {
                    const tn = textNodes[i];
                    const start = fullText.length;
                    fullText += (tn.nodeValue || '');
                    nodeMap.push({ node: tn, start: start, end: fullText.length });
                }

                let matchStart = fullText.indexOf(searchText);
                let matchEnd = (matchStart !== -1) ? (matchStart + searchText.length) : -1;

                if (matchStart === -1) {
                    const escaped = normTarget.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\s+/g, '\\\\s+');
                    const re = new RegExp(escaped, 'i');
                    const m = re.exec(fullText);
                    if (m) {
                        matchStart = m.index;
                        matchEnd = m.index + m[0].length;
                    }
                }

                if (matchStart !== -1 && matchEnd !== -1) {
                    let startNodeInfo = null, endNodeInfo = null;
                    for (let i = 0; i < nodeMap.length; i++) {
                        const entry = nodeMap[i];
                        if (!startNodeInfo && matchStart >= entry.start && matchStart < entry.end) {
                            startNodeInfo = entry;
                        }
                        if (matchEnd > entry.start && matchEnd <= entry.end) {
                            endNodeInfo = entry;
                            break;
                        }
                    }

                    if (startNodeInfo && endNodeInfo) {
                        const range = document.createRange();
                        range.setStart(startNodeInfo.node, matchStart - startNodeInfo.start);
                        range.setEnd(endNodeInfo.node, matchEnd - endNodeInfo.start);
                        wrapRange(range);
                    }
                }
            };

            // Restore all highlights passed as JSON array
            window.dreaderRestoreHighlights = function(items) {
                if (!items || !Array.isArray(items) || items.length === 0) return;
                for (let i = 0; i < items.length; i++) {
                    const it = items[i];
                    if (!it || !it.id || !it.text) continue;
                    window.dreaderHighlightTextInDOM(it.text, it.id, it.colorHex || '#FFE066', it.note);
                }
            };

            // Existing highlight click handler (WeChat Read style)
            window.dreaderClickHighlight = function(id, event) {
                if (event) {
                    event.stopPropagation();
                    event.preventDefault();
                }
                const el = document.querySelector('mark[data-id="' + id + '"]');
                if (!el) return;
                const rect = el.getBoundingClientRect();
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                    window.webkit.messageHandlers.selectionBridge.postMessage({
                        type: 'highlightClicked',
                        id: id,
                        x: rect.x + (rect.width / 2),
                        y: rect.y,
                        bottomY: rect.bottom,
                        width: rect.width,
                        height: rect.height
                    });
                }
            };

            // 页边批注：枚举当前章所有划线元素的逐行矩形碎片（Swift 拉取式轮询用）
            // 单一 getBoundingClientRect 在 spread 跨栏 / 滚动边界 / content-visibility:auto 下不可靠，
            // 这里输出碎片数组，锚点裁决在 Swift 纯函数层做。
            window.dreaderCollectHighlightRects = function() {
                const dprNormalized = [];
                const normRect = function(r) {
                    const left = Math.max(0, r.x);
                    const top = Math.max(0, r.y);
                    const right = Math.min(document.documentElement.clientWidth, r.right);
                    const bottom = Math.min(document.documentElement.clientHeight, r.bottom);
                    const w = right - left;
                    const h = bottom - top;
                    return (w > 0 && h > 0) ? [left, top, w, h] : null;
                };
                const bodyRect = normRect(document.body.getBoundingClientRect());
                const marks = document.querySelectorAll('mark.dreader-highlight[data-id]');
                const items = [];
                for (let i = 0; i < marks.length; i++) {
                    const el = marks[i];
                    const raws = el.getClientRects();
                    const frags = [];
                    for (let k = 0; k < raws.length; k++) {
                        const f = raws[k];
                        // 零尺寸碎片 = content-visibility:auto 的视口外代理，直接剔除
                        if (!(f.width > 0 && f.height > 0)) continue;
                        let merged = false;
                        for (let g = 0; g < frags.length; g++) {
                            // 相邻碎片纵向贴合（<4px 缝隙）合并为一段（打散的同一行）
                            if (Math.abs(frags[g][1] + frags[g][3] - f.y) < 4 &&
                                Math.abs(frags[g][0] - f.x) < 2) {
                                const newBottom = Math.max(frags[g][1] + frags[g][3], f.bottom);
                                frags[g][3] = newBottom - frags[g][1];
                                merged = true;
                                break;
                            }
                        }
                        if (!merged) frags.push([f.x, f.y, f.width, f.height]);
                    }
                    if (frags.length > 0) {
                        items.push({ id: el.getAttribute('data-id'), f: frags });
                    }
                }
                return {
                    // decodeURIComponent 后与 Swift fileURL.path 同形（file 地址可能被 percent 编码）
                    chapterKey: (() => { try { return decodeURIComponent(location.pathname); } catch (err) { return location.pathname; } })(),
                    bodyRect: bodyRect,
                    vw: document.documentElement.clientWidth,
                    vh: document.documentElement.clientHeight,
                    items: items
                };
            };

            // Dismiss highlight card when clicking blank areas
            document.addEventListener('click', function(e) {
                if (!e.target.closest('mark.dreader-highlight')) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                        window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'dismissHighlightCard' });
                    }
                }

                // Footnote reference interception: pop the footnote body in-page instead of navigating away
                const anchor = e.target.closest('a');
                if (anchor) {
                    const href = anchor.getAttribute('href') || '';
                    const match = href.match(/#(foot[-_]?\\d+|fn\\d+|note\\d+|nt\\d+)$/i) || (anchor.className && anchor.className.indexOf('ref') !== -1 && href.match(/#(.+)$/));
                    if (match && !e.metaKey && !e.ctrlKey) {
                        const targetId = match[1];
                        let target = document.getElementById(targetId);
                        if (!target) {
                            try { target = document.getElementById(decodeURIComponent(targetId)); } catch (err) {}
                        }
                        if (target) {
                            e.preventDefault();
                            e.stopPropagation();
                            let rawText = (target.innerText || target.textContent || '').trim();
                            // Trim leading reference markers like "1." or "[1]"
                            rawText = rawText.replace(/^\\s*\\[?\\d+\\]?[.、）)]?\\s*/, '');
                            if (rawText.length > 4000) rawText = rawText.slice(0, 4000) + '…';
                            const rect = anchor.getBoundingClientRect();
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                                window.webkit.messageHandlers.selectionBridge.postMessage({
                                    type: 'footnote',
                                    text: rawText,
                                    x: rect.x + (rect.width / 2),
                                    y: rect.y,
                                    bottomY: rect.bottom,
                                    width: rect.width,
                                    height: rect.height
                                });
                            }
                            return;
                        }
                    }
                }
            });

            // In-place ultra-fast DOM chapter swapping function called from Swift
            window.dreaderSetChapterContent = function(payload) {
                if (!payload) return false;
                const bodyEl = document.getElementById('dreader-chapter-body');
                if (!bodyEl) return false;

                // 换章后立即可见，避免窗口被遮挡时动画帧暂停而一直透明。
                bodyEl.style.opacity = '1';

                if (payload.baseURL) {
                    const baseEl = document.getElementById('dreader-chapter-base');
                    if (baseEl) baseEl.href = payload.baseURL;
                }
                if (payload.styles !== undefined) {
                    const stylesEl = document.getElementById('dreader-chapter-styles');
                    if (stylesEl) stylesEl.innerHTML = payload.styles;
                }

                if (payload.body !== undefined) {
                    if (window.dreaderClearReadAloudSegments) window.dreaderClearReadAloudSegments();
                    bodyEl.innerHTML = payload.body;
                }

                if (payload.highlights && Array.isArray(payload.highlights)) {
                    window.dreaderRestoreHighlights(payload.highlights);
                }

                if (payload.endCard !== undefined) {
                    const endEl = document.getElementById('dreader-end-container');
                    if (endEl) endEl.innerHTML = payload.endCard;
                }

                // Instant scroll to top (horizontal for vertical-rl typesetting: origin is rightmost column)
                window.dreaderScrollToStart();

                // Clear any leftover selection
                const sel = window.getSelection();
                if (sel) sel.removeAllRanges();

                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                    lastReportedPct = 0.0;
                    window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'clear' });
                    window.webkit.messageHandlers.selectionBridge.postMessage({ type: 'scrollProgress', progress: 0.0 });
                }

                return true;
            };

            // In-place DOM content update preserving exact scroll position (for script mode or theme updates)
            window.dreaderSetChapterContentPreservingScroll = function(payload) {
                if (!payload) return false;
                const bodyEl = document.getElementById('dreader-chapter-body');
                if (!bodyEl) return false;

                const currentScrollX = window.scrollX;
                const currentScrollY = window.scrollY;

                if (payload.baseURL) {
                    const baseEl = document.getElementById('dreader-chapter-base');
                    if (baseEl) baseEl.href = payload.baseURL;
                }
                if (payload.styles !== undefined) {
                    const stylesEl = document.getElementById('dreader-chapter-styles');
                    if (stylesEl) stylesEl.innerHTML = payload.styles;
                }

                if (payload.body !== undefined) {
                    if (window.dreaderClearReadAloudSegments) window.dreaderClearReadAloudSegments();
                    bodyEl.innerHTML = payload.body;
                }

                if (payload.highlights && Array.isArray(payload.highlights)) {
                    window.dreaderRestoreHighlights(payload.highlights);
                }

                if (payload.endCard !== undefined) {
                    const endEl = document.getElementById('dreader-end-container');
                    if (endEl) endEl.innerHTML = payload.endCard;
                }

                window.scrollTo({ left: currentScrollX, top: currentScrollY, behavior: 'instant' });

                return true;
            };

            // 搜索定位由 ReaderTextScripts 提供，与朗读共用同一份 DOM 文本映射。

            // Scroll directly to a highlight and pulse ripple glow
            window.dreaderScrollToHighlight = function(id) {
                if (!id) return false;
                const el = document.querySelector('mark.dreader-highlight[data-id="' + id + '"]');
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    const origBoxShadow = el.style.boxShadow;
                    const origTransition = el.style.transition;
                    el.style.transition = 'box-shadow 0.25s ease-out, transform 0.25s ease-out';
                    el.style.boxShadow = '0 0 0 6px rgba(168, 85, 247, 0.45)';
                    el.style.borderRadius = '3px';
                    setTimeout(function() {
                        el.style.boxShadow = origBoxShadow || 'none';
                        setTimeout(function() {
                            el.style.transition = origTransition || '';
                        }, 300);
                    }, 1400);
                    return true;
                }
                return false;
            };

            // Bilingual Paragraph Translation Trigger
            window.dreaderTranslateParagraph = function(index, btn) {
                if (btn) {
                    btn.disabled = true;
                    btn.innerHTML = '<span style="display:inline-block;animation:dreader-spin 1s infinite linear;">⏳</span> <span>正在调用 AI 伴读翻译...</span>';
                }
                const paraElem = document.querySelector('[data-dreader-para="' + index + '"]');
                const text = paraElem ? paraElem.innerText.trim() : '';
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionBridge) {
                    window.webkit.messageHandlers.selectionBridge.postMessage({
                        type: 'translateParagraph',
                        index: index,
                        text: text
                    });
                }
            };

            // In-place Real-Time DOM Translation Replacement
            window.dreaderUpdateTranslation = function(index, transText, agentName) {
                const slot = document.getElementById('dreader-trans-slot-' + index);
                if (!slot) return;
                const div = document.createElement('div');
                div.className = 'dreader-bilingual-trans';
                div.setAttribute('data-para-index', index);
                div.innerHTML = '<div class="dreader-bilingual-header"><span class="dreader-bilingual-tag">译</span><span class="dreader-bilingual-agent">' + (agentName || 'AI 伴读') + ' 译文</span></div><div class="dreader-bilingual-body">' + transText + '</div>';
                slot.parentNode.replaceChild(div, slot);
            };
            \(ReaderTextScripts.source)

            window.dreaderReaderReady = true;
        })();
        """
    }
}
