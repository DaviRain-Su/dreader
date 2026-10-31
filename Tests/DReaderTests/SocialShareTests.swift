import XCTest
@testable import DReader

/// 划线分享纯文本模板与 X 发帖 URL 构造的回归测试。
final class SocialShareTests: XCTestCase {
    private let quote = "没有共同的上帝就没有共同的人类"
    private let thought = "这里像是在说共同体成立的前提"

    private func makeHighlight(
        note: String? = nil,
        bookTitle: String = "卡拉马佐夫兄弟",
        chapterTitle: String = "宗教大法官",
        source: String? = nil,
        wechatAuthor: String? = nil
    ) -> Highlight {
        Highlight(
            bookId: UUID(),
            bookTitle: bookTitle,
            chapterIndex: 0,
            chapterTitle: chapterTitle,
            text: quote,
            colorHex: "#FFE066",
            createdAt: Date(),
            note: note,
            source: source,
            wechatAuthor: wechatAuthor
        )
    }

    private func makeBook(author: String = "陀思妥耶夫斯基") -> EPUBBook {
        EPUBBook(
            title: "卡拉马佐夫兄弟",
            author: author,
            fileURL: URL(fileURLWithPath: "/tmp/demo.epub"),
            unzippedDirectory: URL(fileURLWithPath: "/tmp/demo"),
            opfDirectory: URL(fileURLWithPath: "/tmp/demo")
        )
    }

    // MARK: - composeText

    func testQuoteOnlyFormat() {
        let text = ShareTextComposer.composeText(
            format: .quoteOnly,
            highlight: makeHighlight(),
            book: makeBook()
        )
        XCTAssertEqual(text, "“\(quote)”\n—— 《卡拉马佐夫兄弟》 · 陀思妥耶夫斯基 · 宗教大法官")
    }

    func testQuoteWithThoughtPlacesSourceLast() {
        let text = ShareTextComposer.composeText(
            format: .quoteWithThought,
            highlight: makeHighlight(note: thought),
            book: makeBook()
        )
        XCTAssertTrue(text.hasPrefix("“\(quote)”\n\n💭 我的思考：\(thought)"))
        XCTAssertTrue(text.hasSuffix("—— 《卡拉马佐夫兄弟》 · 陀思妥耶夫斯基 · 宗教大法官"))
    }

    func testThoughtFirstLeadsWithThought() {
        let text = ShareTextComposer.composeText(
            format: .thoughtFirst,
            highlight: makeHighlight(note: thought),
            book: makeBook()
        )
        XCTAssertTrue(text.hasPrefix("💭 我的思考：\(thought)\n\n“\(quote)”"))
        XCTAssertTrue(text.hasSuffix("—— 《卡拉马佐夫兄弟》 · 陀思妥耶夫斯基 · 宗教大法官"))
    }

    func testThoughtFirstFallsBackToQuoteWhenNoThought() {
        let local = ShareTextComposer.composeText(
            format: .thoughtFirst,
            highlight: makeHighlight(note: nil),
            book: makeBook()
        )
        let quoteOnly = ShareTextComposer.composeText(
            format: .quoteOnly,
            highlight: makeHighlight(note: nil),
            book: makeBook()
        )
        XCTAssertEqual(local, quoteOnly)
    }

    func testWeChatSourceAddsViaAndAuthorFallback() {
        let text = ShareTextComposer.composeText(
            format: .quoteOnly,
            highlight: makeHighlight(source: "wechat_read", wechatAuthor: "郭家申"),
            book: nil
        )
        XCTAssertTrue(text.hasSuffix("· 宗教大法官（via 微信读书）"))
        XCTAssertTrue(text.contains("郭家申"))
    }

    func testLocalBookAuthorWinsOverWeChatAuthor() {
        let text = ShareTextComposer.composeText(
            format: .quoteOnly,
            highlight: makeHighlight(source: "wechat_read", wechatAuthor: "郭家申"),
            book: makeBook(author: "耿济之")
        )
        XCTAssertTrue(text.contains("耿济之"))
        XCTAssertFalse(text.contains("郭家申"))
        XCTAssertTrue(text.contains("（via 微信读书）"))
    }

    func testTitleAndChapterFallbacks() {
        // bookTitle 为空时回退 EPUBBook 元数据；章节为空时不出该段
        let text = ShareTextComposer.composeText(
            format: .quoteOnly,
            highlight: makeHighlight(bookTitle: "", chapterTitle: ""),
            book: makeBook()
        )
        XCTAssertEqual(text, "“\(quote)”\n—— 《卡拉马佐夫兄弟》 · 陀思妥耶夫斯基")

        // 双双为空时保底「未知书目」
        var bare = makeHighlight(bookTitle: "", chapterTitle: "")
        bare.source = nil
        let textNoBook = ShareTextComposer.composeText(
            format: .quoteOnly,
            highlight: bare,
            book: nil
        )
        XCTAssertEqual(textNoBook, "“\(quote)”\n—— 《未知书目》")
    }

    // MARK: - truncateForX

    func testTruncateForXPassesShortTextThrough() {
        let short = String(repeating: "读书", count: 50) // 100 汉字 = 200 weighted，未超限
        XCTAssertEqual(ShareTextComposer.truncateForX(short), short)
    }

    func testTruncateForXRespectsWeightedLimitWithEllipsis() {
        let long = String(repeating: "读", count: 200) // 400 weighted，超 278
        let truncated = ShareTextComposer.truncateForX(long)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertLessThanOrEqual(ShareTextComposer.weightedLength(truncated), 278)
        // 截断保序：前缀都是原文
        XCTAssertTrue(truncated.dropLast().allSatisfy { $0 == "读" })
    }

    func testTruncateForXHandlesASCII() {
        let ascii = String(repeating: "a", count: 400)
        let truncated = ShareTextComposer.truncateForX(ascii)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertLessThanOrEqual(ShareTextComposer.weightedLength(truncated), 278)
    }

    // MARK: - xPostURL

    func testXPostURLShape() throws {
        let url = try XCTUnwrap(ShareTextComposer.xPostURL(text: "读书"))
        XCTAssertEqual(url.host, "x.com")
        XCTAssertEqual(url.path, "/intent/post")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(comps.queryItems)
        XCTAssertEqual(items.first?.name, "text")
        XCTAssertEqual(items.first?.value, "读书")
    }

    func testXPostURLEncodesNewlinesAndQuotesRoundtrip() throws {
        let body = "“读书”\n💭 我的思考：共读\n——《书》"
        let url = try XCTUnwrap(ShareTextComposer.xPostURL(text: body))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.queryItems?.first?.value, body)
    }

    func testXPostURLTruncatesBeforeEncoding() throws {
        let long = String(repeating: "读", count: 300)
        let url = try XCTUnwrap(ShareTextComposer.xPostURL(text: long))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let value = try XCTUnwrap(comps.queryItems?.first?.value)
        XCTAssertTrue(value.hasSuffix("…"))
        XCTAssertLessThanOrEqual(ShareTextComposer.weightedLength(value), 278)
    }
}
