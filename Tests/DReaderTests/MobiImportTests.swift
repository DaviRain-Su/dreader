import XCTest
@testable import DReader

/// MOBI/AZW3 导入管线回归：解析 → DRM 检测 → 章切分 → EPUB 组装 → EPUBParser 复解析。
final class MobiImportTests: XCTestCase {

    private func fixture(_ name: String, ext: String = "mobi") throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/MOBI")
        XCTAssertNotNil(url, "fixture \(name).\(ext) 缺失")
        return try XCTUnwrap(url)
    }

    private func tempOutput(_ suffix: String = "epub") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobi-test-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDRMSampleThrowsProtectedError() throws {
        let fixtureURL = try fixture("sample-drm-v1")
        XCTAssertThrowsError(try MOBIParser.parse(fileURL: fixtureURL)) { error in
            guard let mobiError = error as? MOBIParseError else {
                return XCTFail("期望 MOBIParseError，实际 \(error)")
            }
            if case .drmProtected = mobiError {} else {
                XCTFail("期望 drmProtected，实际 \(mobiError)")
            }
        }
    }

    func testNCXSampleProducesChapters() throws {
        let parsed = try MOBIParser.parse(fileURL: try fixture("sample-ncx"))
        XCTAssertGreaterThanOrEqual(parsed.chapters.count, 2,
                                    "KF8 NCX 样例应切出多章，实际 \(parsed.chapters.count)")
    }

    func testCompressedTextSampleParses() throws {
        let parsed = try MOBIParser.parse(fileURL: try fixture("sample-textread"))
        XCTAssertGreaterThanOrEqual(parsed.chapters.count, 1)
        let body = String(data: parsed.chapters[0].utf8Fragment, encoding: .utf8) ?? ""
        XCTAssertFalse(body.isEmpty)
    }

    func testAssembledEPUBReparsableByEPUBParser() async throws {
        let parsed = try MOBIParser.parse(fileURL: try fixture("sample-unicode-uncompressed"))
        let output = tempOutput()
        try EpubAssembler.assemble(book: parsed, outputURL: output)
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let book = try await EPUBParser.shared.parse(fileURL: output)
        XCTAssertEqual(book.title, "Libmobi test sample")
        XCTAssertEqual(book.author, "Bartek Fabiszewski")
        XCTAssertGreaterThanOrEqual(book.chapters.count, 1)
        XCTAssertNotNil(book.coverImageURL, "含图片的样例应解析出封面")
    }

    func testCorruptZipRelativeNotKindle() {
        // 扩展名命中 Kindle 白名单才走转换；普通 .epub 文件不受影响。
        let doc = FileManager.default.temporaryDirectory.appendingPathComponent("not-kindle-\(UUID()).epub")
        defer { try? FileManager.default.removeItem(at: doc) }
        try? Data("not a book".utf8).write(to: doc)
        XCTAssertFalse(ReaderViewModel.isKindleStream(doc))
    }

    func testKindleMagicDetection() {
        // 二进制头命中 "BOOK"（PalmDB type 字段，偏移 0x3C）也应识别为 Kindle 流。
        let doc = FileManager.default.temporaryDirectory.appendingPathComponent("magic-\(UUID()).epub")
        defer { try? FileManager.default.removeItem(at: doc) }
        var data = Data(count: 0x40)
        data.replaceSubrange(0x3C..<0x40, with: Data("BOOK".utf8))
        try? data.write(to: doc)
        XCTAssertTrue(ReaderViewModel.isKindleStream(doc))
    }

    /// 真实书端到端（本机环境变量 DREADER_MOBI_REAL_BOOKS 列出绝对路径时才执行，CI 默认 skip）。
    func testRealBooksEndToEnd() async throws {
        guard let list = ProcessInfo.processInfo.environment["DREADER_MOBI_REAL_BOOKS"], !list.isEmpty else {
            throw XCTSkip("未提供 DREADER_MOBI_REAL_BOOKS，跳过真实书验证")
        }
        let paths = list.split(separator: ";").map(String.init).filter {
            FileManager.default.fileExists(atPath: $0)
        }
        try XCTSkipUnless(!paths.isEmpty, "所列路径均不存在")
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let t0 = DispatchTime.now()
            let parsed = try MOBIParser.parse(fileURL: url)
            let t1 = DispatchTime.now()
            XCTAssertGreaterThan(parsed.title.count, 0, "\(path) 标题非空")
            XCTAssertGreaterThanOrEqual(parsed.chapters.count, 1, "\(path) 至少一章")
            let output = tempOutput()
            try EpubAssembler.assemble(book: parsed, outputURL: output)
            let t2 = DispatchTime.now()
            let book = try await EPUBParser.shared.parse(fileURL: output)
            let t3 = DispatchTime.now()
            func ms(_ a: DispatchTime, _ b: DispatchTime) -> Int {
                Int(Double(b.uptimeNanoseconds - a.uptimeNanoseconds) / 1_000_000)
            }
            print("[perf] \(url.lastPathComponent): parse=\(ms(t0, t1))ms assemble=\(ms(t1, t2))ms reparse=\(ms(t2, t3))ms chapters=\(parsed.chapters.count)")
            XCTAssertEqual(book.title, parsed.title, "\(path) 书名一致性")
            XCTAssertGreaterThanOrEqual(book.chapters.count, 1, "\(path) 复解析出章")
            try? FileManager.default.removeItem(at: output)
        }
    }
}
