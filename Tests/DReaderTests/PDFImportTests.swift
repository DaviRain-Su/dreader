import XCTest
import PDFKit
@testable import DReader

/// PDF 导入管线：文字层探测 → 文本重排（清洗/切章）或原版式页面图 → EPUB 组装复解析。
/// fixture 用 CoreGraphics 程序化生成，不存二进制样张。
final class PDFImportTests: XCTestCase {

    // MARK: - fixture 工具

    /// 按 pages 的行文本逐页绘制文字层 PDF；可选页脚页码行（供噪声清洗验证）。
    private func writeTextPDF(pages: [[String]], title: String? = nil, pageNumbers: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-text-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try writePDF(url: url, pageCount: pages.count, title: title) { context, pageIndex in
            guard pageIndex < pages.count else { return }
            var y: CGFloat = 720
            for line in pages[pageIndex] {
                draw(line, font: NSFont.systemFont(ofSize: 12), at: CGPoint(x: 72, y: y), in: context)
                y -= 22
            }
            if pageNumbers {
                draw("- \(pageIndex + 1) -",
                     font: NSFont.systemFont(ofSize: 10),
                     at: CGPoint(x: 300, y: 30),
                     in: context)
            }
        }
        return url
    }

    /// 生成无文字层 PDF：每页只画一张灰度图形（模拟扫描图页）。
    private func writeImagePDF(pageCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-image-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        ) else {
            throw MOBIParseError.loadFailed("测试位图生成失败")
        }
        rep.setColor(NSColor.darkGray, atX: 0, y: 0)
        rep.setColor(NSColor.gray, atX: 1, y: 0)
        rep.setColor(NSColor.lightGray, atX: 0, y: 1)
        guard let pixels = rep.representation(using: .png, properties: [:]),
              let source = CGImageSourceCreateWithData(pixels as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MOBIParseError.loadFailed("测试图形数据生成失败")
        }
        try writePDF(url: url, pageCount: pageCount, title: nil) { context, _ in
            context.draw(cgImage, in: CGRect(x: 60, y: 110, width: 492, height: 640))
        }
        return url
    }

    private func writePDF(
        url: URL, pageCount: Int, title: String?,
        page: (CGContext, Int) -> Void
    ) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let auxiliary: CFDictionary? = title.map { [kCGPDFContextTitle as String: $0] as CFDictionary }
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, auxiliary) else {
            throw MOBIParseError.loadFailed("测试无法创建 PDF context")
        }
        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            page(context, pageIndex)
            context.endPDFPage()
        }
        context.closePDF()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MOBIParseError.loadFailed("测试 PDF 未生成")
        }
    }

    private func draw(_ text: String, font: NSFont, at point: CGPoint, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    // MARK: - 标题判定

    func testHeadingTitlePatterns() {
        XCTAssertEqual(PDFImporter.headingTitle("第一章 综述"), "第一章 综述")
        XCTAssertEqual(PDFImporter.headingTitle("第3章 架构设计"), "第3章 架构设计")
        XCTAssertEqual(PDFImporter.headingTitle("Chapter 1 Introduction"), "Chapter 1 Introduction")
        XCTAssertEqual(PDFImporter.headingTitle("1.2 系统架构"), "1.2 系统架构")
        XCTAssertNil(PDFImporter.headingTitle("这句话里提到第一章三个字不代表标题。"))
        XCTAssertNil(PDFImporter.headingTitle("2. 苹果，梨，桃。"))
        XCTAssertNil(PDFImporter.headingTitle(""))
    }

    // MARK: - 清洗

    func testMergeParagraphs() {
        let noise: Set<String> = ["某书页眉"]
        let pageLines: [[String]] = [
            ["某书页眉", "第一章 综述", "正文第一段内容开始于上方标题之后。", "续接同一句话的下半行。", "", "  缩进开启的第二段。"],
            ["某书页眉", "Hello wor-", "ld and more text here.", "- 2 -"],
        ]
        let paragraphs = PDFImporter.mergeParagraphs(pageLines: pageLines, noise: noise)
        XCTAssertTrue(paragraphs.contains("第一章 综述"))
        XCTAssertTrue(paragraphs.contains("正文第一段内容开始于上方标题之后。续接同一句话的下半行。"))
        XCTAssertTrue(paragraphs.contains("缩进开启的第二段。"))
        XCTAssertTrue(paragraphs.contains("Hello world and more text here."))
        XCTAssertFalse(paragraphs.contains("某书页眉"))
        XCTAssertFalse(paragraphs.contains("- 2 -"))
    }

    func testHeaderFooterNoiseDetection() {
        let pageLines: [[String]] = (1...6).map { page in
            ["统一页眉 \(2025)", "第 \(page) 页的正文正文正文。", "统一页脚", "\(page)"]
        }
        let noise = PDFImporter.headerFooterNoise(in: pageLines)
        XCTAssertTrue(noise.contains("统一页眉 \(2025)"))
        XCTAssertTrue(noise.contains("统一页脚"))
        XCTAssertFalse(noise.contains("第 1 页的正文正文正文。"), "各页不同的正文行不是噪声")
        XCTAssertFalse(noise.contains("1"), "每页不同的页码行交给页码规则删除，不进噪声集")
    }

    /// 回归：真实书存在无文字页（封面/夹图页 page.string 为空字符串），其页内只剩一行空串；
    /// 尾行统计区间小页时曾越界崩溃（Range requires lowerBound <= upperBound）。
    func testHeaderFooterNoiseWithBlankPages() {
        let pageLines: [[String]] = (1...5).map { page in
            switch page {
            case 3: return [""]                       // 无文字页：提取结果只剩空串
            case 4: return ["统一页眉"]                // 单行页
            default: return ["统一页眉", "第 \(page) 页的正文行，内容不同，不是页眉。"]
            }
        }
        let noise = PDFImporter.headerFooterNoise(in: pageLines)
        XCTAssertTrue(noise.contains("统一页眉"), "跨页重复的页眉应命中噪声")
        XCTAssertFalse(noise.contains(""), "空串不应进入噪声集")
        _ = PDFImporter.mergeParagraphs(pageLines: pageLines, noise: noise)
    }

    // MARK: - 文字层探测与重排端到端

    func testTextPDFEndToEnd() throws {
        let titles = ["第一章 综述", "第二章 方法", "第三章 结果"]
        let url = try writeTextPDF(
            pages: titles.map { title in
                [title,
                 "正文段落行一，这是用来填充文字层数据的。",
                 "正文段落行二，同一段落延续到这里。"]
            },
            title: "合成文本书",
            pageNumbers: true
        )
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(PDFImporter.hasDominantTextLayer(document: document))

        let parsed = try PDFImporter.parse(fileURL: url)
        XCTAssertEqual(parsed.title, url.deletingPathExtension().lastPathComponent, "第一版标题回退文件名")
        XCTAssertGreaterThanOrEqual(parsed.chapters.count, 2)
        // 页脚页码与重复页眉被清洗，不进入正文段；标题段独立成章。
        for (index, chapter) in parsed.chapters.enumerated() {
            let text = String(data: chapter.utf8Fragment, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("<p>"), "重排正文应为段落 HTML")
            XCTAssertFalse(text.contains(titles[index]), "标题行不重复出现在正文里")
        }
        XCTAssertTrue(parsed.chapters[0].title?.hasPrefix("第一章") ?? false)
    }

    // MARK: - 原版式页面图

    func testImagePDFBecomesPageChapters() throws {
        let url = try writeImagePDF(pageCount: 3)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertFalse(PDFImporter.hasDominantTextLayer(document: document))

        let parsed = try PDFImporter.parse(fileURL: url)
        XCTAssertEqual(parsed.chapters.count, 3)
        XCTAssertEqual(parsed.chapters[1].title, "第 2 页")
        for chapter in parsed.chapters {
            let text = String(data: chapter.utf8Fragment, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("<img src=\"resource"), "页面图章节应为 img 引用：\(text.prefix(120))")
        }
        let cover = try XCTUnwrap(parsed.resources[parsed.coverUID ?? -1])
        XCTAssertTrue(cover.isImage)
        XCTAssertGreaterThan(cover.data.count, 1000, "封面页应渲染成可用位图")
    }

    func testImagePipelineAssembleReparse() async throws {
        let url = try writeImagePDF(pageCount: 3)
        let parsed = try PDFImporter.parse(fileURL: url)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-epub-\(UUID().uuidString).epub")
        try EpubAssembler.assemble(book: parsed, outputURL: output)
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }

        let book = try await EPUBParser.shared.parse(fileURL: output)
        XCTAssertEqual(book.title, url.deletingPathExtension().lastPathComponent, "无元数据时回退文件名")
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertNotNil(book.coverImageURL)
    }

    func testPDFFileDetection() {
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent("x.pdf")
        XCTAssertTrue(PDFImporter.isPDF(fileURL: stub))
        XCTAssertFalse(PDFImporter.isPDF(fileURL: stub.appendingPathExtension("mobi")))
    }

    /// 真实 PDF 验收（本机不走 CI）：DREADER_PDF_REAL_FILE=<路径>，转换→组装→复解析全链计时。
    func testRealPDFTargetEndToEnd() async throws {
        guard let rawPath = ProcessInfo.processInfo.environment["DREADER_PDF_REAL_FILE"],
              !rawPath.isEmpty else {
            throw XCTSkip("设 DREADER_PDF_REAL_FILE=<pdf 路径> 跑真实书验收")
        }
        let url = URL(fileURLWithPath: rawPath)
        let start = DispatchTime.now()
        let parsed = try PDFImporter.parse(fileURL: url)
        let parseMs = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let sizes = parsed.chapters.map { $0.utf8Fragment.count }
        print("[pdf-real] title=\(parsed.title) chapters=\(parsed.chapters.count) cover=\(parsed.coverUID != nil) parseMs=\(parseMs)")
        print("[pdf-real] chapterTextKB total=\(sizes.reduce(0, +) / 1024) biggest=\((sizes.max() ?? 0) / 1024) smallest=\((sizes.min() ?? 0) / 1024)")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-pdf-\(UUID().uuidString).epub")
        let assembleStart = DispatchTime.now()
        try EpubAssembler.assemble(book: parsed, outputURL: output)
        let assembleMs = (DispatchTime.now().uptimeNanoseconds - assembleStart.uptimeNanoseconds) / 1_000_000
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }
        print("[pdf-real] assembleMs=\(assembleMs) size=\((try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0)")
        printLargestEPUBEntries(output, limit: 5)

        let book = try await EPUBParser.shared.parse(fileURL: output)
        XCTAssertEqual(book.title, parsed.title)
        XCTAssertEqual(book.chapters.count, parsed.chapters.count)
        print("[pdf-real] reparse done, all green")
    }

    /// 体积排障：zip 成员按大小降序打印前 limit 个（含所有 >1MB 的条目总数）。
    private func printLargestEPUBEntries(_ url: URL, limit: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-l", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let rows = text.split(separator: "\n").compactMap { line -> (Int, String)? in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 8,
                  let size = Int(String(columns[3]), radix: 10),
                  columns[2].contains("-20") else { return nil }   // zipinfo 表格行：日期列在 size 之后
            return (size, columns[7].count > 2 ? String(columns.dropLast(3).joined(separator: "")) : "??")
        }.sorted { $0.0 > $1.0 }
        for (size, name) in rows.prefix(limit) {
            print("[pdf-real] \(size / 1024)KB  \(name)")
        }
        print("[pdf-real] entries >1MB: \(rows.filter { $0.0 > 1_000_000 }.count)")
    }
}
