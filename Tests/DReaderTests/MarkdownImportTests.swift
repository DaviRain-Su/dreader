import XCTest
@testable import DReader

/// Markdown 导入管线：frontmatter → 标题切章 → cmark 转 HTML → EPUB 组装复解析。
final class MarkdownImportTests: XCTestCase {

    private func tempMD(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-import-\(UUID().uuidString).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFrontmatterExtractsTitleAndAuthor() throws {
        let url = try tempMD("""
        ---
        title: 重构笔记
        author: Davirain
        ---
        # 第一章

        正文内容。
        """)
        let parsed = try MarkdownImporter.parse(fileURL: url)
        XCTAssertEqual(parsed.title, "重构笔记")
        XCTAssertEqual(parsed.author, "Davirain")
        XCTAssertGreaterThanOrEqual(parsed.chapters.count, 1)
    }

    func testFirstH1BecomesTitleWithoutFrontmatter() throws {
        let url = try tempMD("""
        # 设计模式手记

        前言内容。

        ## 工厂模式

        章节正文。

        ## 观察者模式

        章节正文。
        """)
        let parsed = try MarkdownImporter.parse(fileURL: url)
        XCTAssertEqual(parsed.title, "设计模式手记")
        XCTAssertEqual(parsed.chapters.count, 3)
        XCTAssertEqual(parsed.chapters[0].title, "设计模式手记")
        XCTAssertEqual(parsed.chapters[1].title, "工厂模式")
        XCTAssertEqual(parsed.chapters[2].title, "观察者模式")
    }

    func testHeadingInsideFenceDoesNotSplit() throws {
        let url = try tempMD("""
        # 外部章

        ```swift
        # 这不是标题
        ```
        """)
        let parsed = try MarkdownImporter.parse(fileURL: url)
        XCTAssertEqual(parsed.chapters.count, 1)
    }

    func testCmarkConvertsCommonBlocks() {
        let html = MarkdownImporter.markdownToHTML("""
        ## 标题
        **加粗** 与 *斜体*。

        - 列表一
        - 列表二

        > 引用块

        ```swift
        let x = 1
        ```
        """)
        print("[cmark] \(html)")
        XCTAssertTrue(html.contains("<h2>"), "应含 h2，实际：\(html.prefix(200))")
        XCTAssertTrue(html.contains("<strong>"), "应含 strong")
        XCTAssertTrue(html.contains("<li>"), "应含列表项")
        XCTAssertTrue(html.contains("<blockquote>"), "应含引用块")
        XCTAssertTrue(html.contains("<code"), "应含代码块")
    }

    func testTableRenders() {
        let html = MarkdownImporter.markdownToHTML("""
        | A | B |
        |---|---|
        | 1 | 2 |
        """)
        print("[cmark table] \(html)")
        XCTAssertTrue(html.contains("<table"), "应含 table，实际：\(html.prefix(200))")
    }

    func testFullPipelineToEPUBParser() async throws {
        let url = try tempMD("""
        ---
        title: 工程手册
        author: Claude
        ---

        ## 概览

        架构说明正文。

        - 要点一
        - 要点二

        ## 实现

        详细实现说明。
        """)
        let parsed = try MarkdownImporter.parse(fileURL: url)
        XCTAssertEqual(parsed.title, "工程手册")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-epub-\(UUID().uuidString).epub")
        try EpubAssembler.assemble(book: parsed, outputURL: output)
        defer { try? FileManager.default.removeItem(at: output) }

        let book = try await EPUBParser.shared.parse(fileURL: output)
        XCTAssertEqual(book.title, "工程手册")
        XCTAssertEqual(book.author, "Claude")
        XCTAssertGreaterThanOrEqual(book.chapters.count, 2)
    }

    func testMarkdownFileDetection() throws {
        let url = try tempMD("# t\n")
        XCTAssertTrue(MarkdownImporter.isMarkdown(fileURL: url))
        XCTAssertFalse(MarkdownImporter.isMarkdown(fileURL: url.appendingPathExtension("epub")))
    }
}
