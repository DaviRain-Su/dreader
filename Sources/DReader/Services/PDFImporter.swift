import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// PDF 导入：文字层探测 → 文本重排 / 原版式页面图两条管线，产物统一 `ParsedBook`，
/// 交给 `EpubAssembler` 复用 EPUB 导入管线。
///
/// - 文字层占主导（按几页采样判定）：提取文本 → 清洗（页眉/页脚/页码去重、硬连字拼接、
///   断行合并段落）→ 标题模式切章 → `<p>` 段落流。内嵌图片本版不提取。
/// - 无文字层（扫描件）：不重排，每页渲染成整页图作为 image-only 章节，目录按页序展示。
///   本版不做 OCR，不做双栏读序分析。
enum PDFImporter {
    static func isPDF(fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() == "pdf"
    }

    // MARK: - 入口

    static func parse(fileURL: URL) throws -> ParsedBook {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MOBIParseError.fileNotFound
        }
        guard let document = PDFDocument(url: fileURL), document.pageCount > 0 else {
            throw MOBIParseError.loadFailed("PDF 无法读取，可能已损坏或被加密")
        }
        // 第一版元数据从简：标题取文件名（PDF 内嵌 Info 字典的键没有稳定的 Swift 桥接）。
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }

        let book = hasDominantTextLayer(document: document)
            ? buildReflowBook(pages: pages, title: fileName, author: "未知作者")
            : buildImagePageBook(pages: pages, title: fileName, author: "未知作者")
        guard !book.chapters.isEmpty else {
            throw MOBIParseError.rawmlFailed("PDF 没有可导入的内容")
        }
        return book
    }

    // MARK: - 文字层探测

    /// 采样页面（最多 12 页步进）：去空白后 ≥20 个字符算"有文字页"，占比过半走重排。
    static func hasDominantTextLayer(document: PDFDocument) -> Bool {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return false }
        let stride = max(1, pageCount / min(12, pageCount))
        var sampled = 0
        var textPages = 0
        var index = 0
        while index < pageCount, let page = document.page(at: index) {
            sampled += 1
            let characters = (page.string ?? "").filter { !$0.isWhitespace }
            if characters.count >= 20 { textPages += 1 }
            index += stride
        }
        guard sampled > 0 else { return false }
        return Double(textPages) >= Double(sampled) * 0.5
    }

    // MARK: - 文本重排管线

    private static func buildReflowBook(pages: [PDFPage], title: String, author: String) -> ParsedBook {
        // 行首只 trim 半角空白，保留全角空格缩进当段落起始信号。
        let pageLines = pages.map { bodyLines(of: $0) }
        let noise = headerFooterNoise(in: pageLines)
        let paragraphs = mergeParagraphs(pageLines: pageLines, noise: noise)
        var resources: [Int: BookResource] = [:]
        var coverUID: Int?
        if let cover = coverResource(page: pages.first, uid: 1) {
            resources[1] = cover
            coverUID = 1
        }
        return ParsedBook(
            title: title,
            author: author,
            language: "zh",
            chapters: chapters(fromParagraphs: paragraphs),
            resources: resources,
            coverUID: coverUID,
            cssUIDs: []
        )
    }

    private static func bodyLines(of page: PDFPage) -> [String] {
        (page.string ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")) }
    }

    /// 跨整本高频出现的首/尾候选行（页眉、页脚型）——超过 34% 页重复即判噪声行。
    /// 兼容空行页/单行页（尾段区间下界不得越过 available 行数，否则 Range 陷阱崩溃）。
    static func headerFooterNoise(in pageLines: [[String]]) -> Set<String> {
        var counts: [String: Int] = [:]
        let depth = 2
        for lines in pageLines {
            guard !lines.isEmpty else { continue }
            for index in 0..<min(depth, lines.count) {
                counts[lines[index], default: 0] += 1
            }
            for index in max(lines.count - depth, min(depth, lines.count))..<lines.count {
                counts[lines[index], default: 0] += 1
            }
        }
        let threshold = max(3, Int(Double(pageLines.count) * 0.34))
        return Set(counts.filter { $0.value >= threshold && !$0.key.isEmpty }.map(\.key))
    }

    private static func isPageNumber(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let match = pageNumberRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) {
            _ = match
            return true
        }
        return false
    }

    /// 纯页码行（含细语种罗马字页码/装饰符）；中文型"第 N 页"页码单独一条。
    private static let pageNumberRegex = try! NSRegularExpression(
        pattern: #"^[·•・\-–—_—\s]*([0-9]{1,4}|[ivxlcm]{1,6})[·•・\-–—_—\s]*$"#
    )

    /// 清洗后的段落流：
    /// - 噪声行 / 纯页码行删除；
    /// - 标题行独立成段；
    /// - 行首缩进（全角空格或两个半角空格）开启新段；
    /// - 西文行尾连字与下行首拼接去连字符；中文首尾直接续接；其余空格续接（西文断行）。
    /// 该函数为纯文本静态函数，供直接单测。
    static func mergeParagraphs(pageLines: [[String]], noise: Set<String>) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        var hasOpen = false

        func flushParagraph() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
            hasOpen = false
        }

        for lines in pageLines {
            for line in lines where !line.isEmpty {
                let bare = line.trimmingCharacters(in: .whitespaces)
                if noise.contains(bare) || isPageNumber(line) { continue }
                if let heading = headingTitle(line) {
                    flushParagraph()
                    paragraphs.append(heading)
                    continue
                }
                let startsIndented = line.hasPrefix("　") || line.hasPrefix("  ")
                if startsIndented && hasOpen { flushParagraph() }
                if hasOpen {
                    if current.hasSuffix("-"), firstCharacter(line).isASCII, firstCharacter(line).isLetter {
                        current.removeLast()
                        current += line
                    } else if isFinalCJKText(current) != isInitialCJK(line) {
                        // 中西文块交替：不同文字体系不续接，开新段。
                        flushParagraph()
                        current = line
                        hasOpen = true
                    } else if isFinalCJKText(current), isInitialCJK(line) {
                        current += line
                    } else {
                        current += " " + line
                    }
                } else {
                    current = line
                    hasOpen = true
                }
            }
        }
        flushParagraph()
        return paragraphs
    }

    // MARK: 标题切章

    /// 标题模式（行级判定，用于切章）——全部锚定行首与行尾，正文长行不会误判：
    /// - `第X章/节/回/卷/部/篇`（可带章题，≤30 字）；
    /// - `Chapter N`（含罗马数字）；
    /// - 编号短标题（`1.2 系统架构`，内容不得含句读，防列表行误切）。
    /// 返回清洗后的标题文本；非标题返回 nil。
    static func headingTitle(_ line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return nil }
        if trimmed.hasSuffix("。") { trimmed = String(trimmed.dropLast()) }
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        if let cjkPattern = try? NSRegularExpression(pattern: #"^第\s*[0-9一二三四五六七八九十百千万零〇]{1,7}\s*[章节回卷部篇][^。！？?！]{0,30}$"#) {
            if cjkPattern.firstMatch(in: trimmed, range: range) != nil { return trimmed }
        }
        if let latinPattern = try? NSRegularExpression(pattern: #"(?i)^chapter\s+([0-9]{1,4}|[ivxlcm]{1,8})[^。！？?！]{0,28}$"#) {
            if latinPattern.firstMatch(in: trimmed, range: range) != nil { return trimmed }
        }
        if let numberedPattern = try? NSRegularExpression(pattern: #"^\d{1,3}\s*[\.．、]\s*[\p{Han}A-Z0-9][^。！？?！,，;；:：]{1,28}$"#) {
            if numberedPattern.firstMatch(in: trimmed, range: range) != nil { return trimmed }
        }
        return nil
    }

    /// 段落流 → 章：标题段开新章，其余并入当前章；无任何标题则为单章。
    static func chapters(fromParagraphs paragraphs: [String]) -> [BookChapterData] {
        var sections: [(title: String?, body: [String])] = []
        for paragraph in paragraphs {
            if let heading = headingTitle(paragraph) {
                sections.append((title: heading, body: []))
            } else {
                if sections.isEmpty { sections.append((title: nil, body: [])) }
                sections[sections.count - 1].body.append(paragraph)
            }
        }
        // 空正文段（连续标题）不保留；末章若只剩标题也不保留，避免空章。
        var result = sections.filter { !$0.body.isEmpty }
        if result.isEmpty, let first = sections.first {
            // 全书只有标题没有正文段的极端情况：首个标题当章。
            result = [(title: first.title, body: [])]
        }
        return result.map { section in
            let html = section.body
                .map { "<p>\(escapeHTML($0))</p>" }
                .joined(separator: "\n")
            return BookChapterData(title: section.title, utf8Fragment: Data(html.utf8), isWholeDocument: false)
        }
    }

    // MARK: - 原版式页面图管线

    private static func buildImagePageBook(pages: [PDFPage], title: String, author: String) -> ParsedBook {
        var resources: [Int: BookResource] = [:]
        var chapters: [BookChapterData] = []
        var coverUID: Int?
        var uid = 0
        for (pageIndex, page) in pages.enumerated() {
            uid += 1
            let name = String(format: "resource%05d.jpg", uid)
            let label = escapeHTML("\(title) 第 \(pageIndex + 1) 页")
            let fragment = "<div class=\"pdf-page\"><img src=\"\(name)\" alt=\"\(label)\"/></div>"
            chapters.append(BookChapterData(title: "第 \(pageIndex + 1) 页", utf8Fragment: Data(fragment.utf8), isWholeDocument: false))
            guard let data = jpegData(for: page, targetWidth: 1400) else { continue }
            resources[uid] = BookResource(uid: uid, ext: "jpg", mediaType: "image/jpeg", data: data, isImage: true)
            if pageIndex == 0 { coverUID = uid }
        }
        return ParsedBook(
            title: title,
            author: author,
            language: "zh",
            chapters: chapters,
            resources: resources,
            coverUID: coverUID,
            cssUIDs: []
        )
    }

    // MARK: - 渲染与编码

    private static func coverResource(page: PDFPage?, uid: Int) -> BookResource? {
        guard let page, let data = jpegData(for: page, targetWidth: 1000) else { return nil }
        return BookResource(uid: uid, ext: "jpg", mediaType: "image/jpeg", data: data, isImage: true)
    }

    /// 整页渲染（白底 mediaBox 位图）→ JPEG。PDF 文档线程安全，导入跑在后台。
    private static func jpegData(for page: PDFPage, targetWidth: CGFloat) -> Data? {
        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0, targetWidth.isFinite, targetWidth > 0 else { return nil }
        let scale = targetWidth / mediaBox.width
        let pixelWidth = max(1, Int(targetWidth))
        let pixelHeight = max(1, Int(mediaBox.height * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        guard let rendered = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, rendered, [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - 文本小工具

    private static func firstCharacter(_ s: String) -> Character {
        s.first ?? " "
    }

    /// 中文（混排首末字符判断；含 CJK 标点/全角符号——句号 `。`、省略号、全角问号也是"中文尾"）。
    private static func isCJKText(_ s: String) -> Bool {
        guard let scalar = s.first?.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3000...0x303F).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }

    private static func isInitialCJK(_ s: String) -> Bool {
        isCJKText(s)
    }

    private static func isFinalCJKText(_ s: String) -> Bool {
        guard let scalar = s.last?.unicodeScalars.first else { return false }
        return isCJKText(String(scalar))
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
