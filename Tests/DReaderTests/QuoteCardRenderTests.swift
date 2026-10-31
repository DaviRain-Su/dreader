import XCTest
import SwiftUI
@testable import DReader

/// 金句卡导出保真度与竖排断列工具的回归测试。
final class QuoteCardRenderTests: XCTestCase {
    // MARK: - QuoteCardImageRenderer（导出保真）

    @MainActor
    func testRenderProducesThreeTimesScaleBitmap() throws {
        let image = try XCTUnwrap(
            QuoteCardImageRenderer.render(
                Rectangle().fill(Color.red).frame(width: 40, height: 30)
            )
        )
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 120)   // 40pt × 3x
        XCTAssertEqual(cg.height, 90)   // 30pt × 3x
        XCTAssertEqual(image.size, NSSize(width: 40, height: 30))
    }

    @MainActor
    func testFillColorSurvivesFlattenPipelineOpaque() throws {
        // 三个容忍点：像素精确（3x 分辨率）、纯色不被 TIFF/色彩空间往返染色、alpha 全不透明（白底分享无脏边）
        let image = try XCTUnwrap(
            QuoteCardImageRenderer.render(
                Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 20, height: 20)
            )
        )
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bytes = [UInt8](try XCTUnwrap(cg.dataProvider?.data) as Data)
        let offset = cg.bytesPerRow * 30 + 30 * 4   // 中心像素（60×60 位图）
        XCTAssertLessThan(abs(Int(bytes[offset]) - 255), 4)
        XCTAssertLessThan(abs(Int(bytes[offset + 1])), 4)
        XCTAssertLessThan(abs(Int(bytes[offset + 2])), 4)
        XCTAssertEqual(bytes[offset + 3], 255)
    }

    // MARK: - QuoteCardLayout（竖排断列/截断）

    func testVerticalColumnsChunksRightToLeft() {
        XCTAssertEqual(
            QuoteCardLayout.verticalColumns("一二三四五六七八九", capacity: 4),
            ["一二三四", "五六七八", "九"]
        )
    }

    func testVerticalColumnsEmptyAndCapacityGuards() {
        XCTAssertTrue(QuoteCardLayout.verticalColumns("", capacity: 4).isEmpty)
        XCTAssertTrue(QuoteCardLayout.verticalColumns("abc", capacity: 0).isEmpty)
    }

    func testTruncateAddsEllipsisOnlyWhenNeeded() {
        XCTAssertEqual(QuoteCardLayout.truncate("一二三四五", maxLength: 3), "一二三…")
        XCTAssertEqual(QuoteCardLayout.truncate("一二三", maxLength: 3), "一二三")
        XCTAssertEqual(QuoteCardLayout.truncate("书", maxLength: 2), "书")
    }
}
