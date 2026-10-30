import Foundation
import Cmark

/// Markdown 文档 → 结构化书籍内容（章 = H1/H2 标题切分），交给通用 EpubAssembler。
enum MarkdownImporter {
    static func isMarkdown(fileURL: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(fileURL.pathExtension.lowercased())
    }

    static func parse(fileURL: URL) throws -> ParsedBook {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MOBIParseError.fileNotFound
        }
        let raw = try Data(contentsOf: fileURL)
        guard let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) else {
            throw MOBIParseError.loadFailed("Markdown 文件不是可识别的文本编码")
        }

        var body = text
        var frontTitle: String?
        var frontAuthor: String?
        (body, frontTitle, frontAuthor) = stripFrontmatter(body)
        // 按标题切分 markdown 源文本；无标题则整体一章。
        let sections = splitByHeadings(body)
        var chapters: [BookChapterData] = sections.enumerated().map { _, section -> BookChapterData in
            let html = markdownToHTML(section.body)
            return BookChapterData(title: section.title, utf8Fragment: Data(html.utf8), isWholeDocument: false)
        }
        guard !chapters.isEmpty else {
            throw MOBIParseError.rawmlFailed("Markdown 文件没有可用内容")
        }

        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let hunked = ChapterSplitter.split(chapters)
        return ParsedBook(
            title: frontTitle ?? sections.first?.title ?? fileName,
            author: frontAuthor ?? "未知作者",
            language: "zh",
            chapters: hunked,
            resources: [:],
            coverUID: nil,
            cssUIDs: []
        )
    }

    // MARK: frontmatter

    /// 剥 `---` YAML 头，取 title/author 字段（子集解析：取行首 key: value）。
    static func stripFrontmatter(_ text: String) -> (body: String, title: String?, author: String?) {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            return (text, nil, nil)
        }
        lines.removeFirst()
        var title: String?
        var author: String?
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." {
                // 头结构结束；剩余正文。
                let rest = Array(lines[(index + 1)...]).joined(separator: "\n")
                return (rest, title, author)
            }
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if key == "title", title == nil { title = value.isEmpty ? nil : value }
                if (key == "author" || key == "authors"), author == nil { author = value.isEmpty ? nil : value }
            }
            index += 1
        }
        // 没有闭合 `---`：整篇当作正文（防御式，不误吞）。
        return (text, title, author)
    }

    // MARK: 标题切章

    struct Section {
        let title: String?
        let body: String
    }

    static func splitByHeadings(_ text: String) -> [Section] {
        let lines = text.components(separatedBy: "\n")
        var sections: [Section] = []
        var currentTitle: String?
        var bodyLines: [String] = []
        var inFence = false
        var fenceMark = ""
        var sawFirstH1 = false

        func flush() {
            let body = bodyLines.joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sections.append(Section(title: currentTitle, body: body))
            bodyLines = []
        }

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if !inFence, trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                inFence = true
                fenceMark = String(trimmedLine.prefix(3))
            } else if inFence, trimmedLine.hasPrefix(fenceMark) {
                inFence = false
            }
            guard !inFence else {
                bodyLines.append(line)
                continue
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            _ = range
            if let hashesText = headingPrefix(in: line) {
                let level = hashesText.count
                if level == 1 && !sawFirstH1 {
                    // 文档首个 H1 当书名行，不单独开章。
                    sawFirstH1 = true
                    currentTitle = cleanHeadingTitle(line)
                    continue
                }
                flush()
                currentTitle = cleanHeadingTitle(line)
                continue
            }
            bodyLines.append(line)
        }
        flush()
        return sections
    }

    /// 行首 1~2 个 `#` 后接空白（0-3 空格缩进容差）；返回 `#` 数量对应的字符串。
    private static func headingPrefix(in line: String) -> String? {
        var spaces = 0
        let chars = Array(line)
        while spaces < chars.count, chars[spaces] == " " { spaces += 1 }
        if spaces > 3 { return nil }
        var i = spaces
        var hashes = 0
        while i < chars.count, chars[i] == "#" {
            hashes += 1
            i += 1
            if hashes > 2 { return nil }
        }
        guard hashes >= 1, i < chars.count, chars[i] == " " || chars[i] == "\t" else { return nil }
        return String(repeating: "#", count: hashes)
    }

    private static func cleanHeadingTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let idx = trimmed.firstIndex(of: " ") ?? trimmed.firstIndex(of: "\t") else { return trimmed }
        var title = String(trimmed[trimmed.index(after: idx)...])
        // 尾部锚点与强调符号清理。
        title = title.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// cmark（CommonMark 参考实现）转 HTML，保持 SAFE 模式（导入的第三方文件
    /// 不允许 raw HTML/script 直通 WKWebView）。入口统一做 GFM 表格预处理：
    /// 表格块换成占位符走 cmark，转换完成后再把占位符替换为受控构造的表格 HTML
    /// （cell 内容全部转义，标签由本函数生成）。
    static func markdownToHTML(_ markdown: String) -> String {
        let preprocessed = preprocessGFMTables(markdown)
        var html = preprocessed.text.withCString { cBuffer in
            guard let out = cmark_markdown_to_html(cBuffer, preprocessed.text.utf8.count, 0) else { return "" }
            defer { free(out) }
            return String(cString: out)
        }
        for (index, table) in preprocessed.tables.enumerated() {
            html = html.replacingOccurrences(of: tableMarker(index), with: table)
        }
        return html
    }

    private static func tableMarker(_ index: Int) -> String {
        "DREADER-TABLE-MARKER-\(index)-ZK"
    }

    // MARK: GFM 表格预处理

    struct PreprocessedMarkdown {
        let text: String
        /// index → 占位符位置的表格 HTML（由本模块构造，cell 内容已转义）。
        let tables: [String]
    }

    /// GFM 表格（| --- |）→ 占位符 + 表格清单；cmark SAFE 模式下占位符以段落形式通过转换，
    /// 转换后由调用方二次替换为受控表格 HTML。
    private static func preprocessGFMTables(_ text: String) -> PreprocessedMarkdown {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var tables: [String] = []
        var index = 0
        var inFence = false
        var fenceMark = ""

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inFence, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMark = String(trimmed.prefix(3))
                output.append(line)
                index += 1
                continue
            }
            if inFence {
                if trimmed.hasPrefix(fenceMark) { inFence = false }
                output.append(line)
                index += 1
                continue
            }

            // 表格 = 头行 + 分隔行 + 0+ 数据行；头行已被 append，回退重组。
            if isTableDivider(trimmed), output.last != nil,
               isTableRow(lastAppended(for: lines, at: index, output: output)) {
                let header = parseTableRow(output.removeLast())
                index += 1 // 越过分隔行
                var rows: [[String]] = [header]
                while index < lines.count, isTableRow(lines[index]) {
                    rows.append(parseTableRow(lines[index]))
                    index += 1
                }
                output.append(tableMarker(tables.count))
                output.append("")
                tables.append(renderTable(rows: rows))
                continue
            }
            output.append(line)
            index += 1
        }
        return PreprocessedMarkdown(text: output.joined(separator: "\n"), tables: tables)
    }

    private static func isTableRow(_ s: String) -> Bool {
        s.hasPrefix("|") || s.hasSuffix("|")
    }

    private static func lastAppended(for lines: [String], at index: Int, output: [String]) -> String {
        guard let last = output.last else { return "" }
        return last.trimmingCharacters(in: .whitespaces)
    }

    private static func isTableDivider(_ s: String) -> Bool {
        // GFM 分隔行：| - | - | 或 :---: 形式。
        guard s.contains("-") else { return false }
        let cleaned = s.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "|", with: "")
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "- \t")).isEmpty && s.contains("|")
    }

    private static func parseTableRow(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { cell in
            escapeHTML(cell.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func renderTable(rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        var html = "<table><thead><tr>"
        for cell in header { html += "<th>\(cell)</th>" }
        html += "</tr></thead><tbody>"
        for row in rows.dropFirst() {
            html += "<tr>"
            for cell in row { html += "<td>\(cell)</td>" }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
