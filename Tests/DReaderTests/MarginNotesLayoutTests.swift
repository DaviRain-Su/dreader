import XCTest
import SwiftUI
@testable import DReader

/// 页边批注（Margin Notes）布局纯函数回归：锚点合并 / 跨栏选片 / 左右分配 / 重叠下推 / 溢出裁剪。
final class MarginNotesLayoutTests: XCTestCase {

    private let bodyRect = CGRect(x: 300, y: 0, width: 600, height: 900) // 正文盒居中 600 宽
    private let viewport = CGSize(width: 1200, height: 900)

    // MARK: - resolveAnchor

    func testResolveAnchorRejectsEmptyAndZeroSizeFrags() {
        XCTAssertNil(MarginNotesLayout.resolveAnchor(frags: [], viewportHeight: 900))
        // 零尺寸碎片（content-visibility 剔除）不留锚点；有实碎片时被过滤掉
        XCTAssertNil(MarginNotesLayout.resolveAnchor(frags: [CGRect(x: 10, y: 10, width: 0, height: 20)], viewportHeight: 900))
        let anchor = MarginNotesLayout.resolveAnchor(
            frags: [CGRect(x: 10, y: 10, width: 0, height: 20), CGRect(x: 10, y: 30, width: 200, height: 20)],
            viewportHeight: 900
        )
        XCTAssertEqual(anchor, CGRect(x: 10, y: 30, width: 200, height: 20))
    }

    func testResolveAnchorUnionsMultiLineFragmentsSameColumn() {
        // 同栏多行：三片横向相接 → union bounding
        let anchor = MarginNotesLayout.resolveAnchor(
            frags: [
                CGRect(x: 100, y: 100, width: 200, height: 20),
                CGRect(x: 100, y: 122, width: 200, height: 22),
                CGRect(x: 100, y: 146, width: 180, height: 20)
            ],
            viewportHeight: 900
        )
        XCTAssertEqual(anchor, CGRect(x: 100, y: 100, width: 200, height: 66))
    }

    func testResolveAnchorPicksLargestVisibleFragmentWhenCrossColumn() {
        // 跨栏（横向差 >40px）：取可视面积最大的片（右栏片更高），union 会横跨中缝不可用
        let anchor = MarginNotesLayout.resolveAnchor(
            frags: [
                CGRect(x: 100, y: 300, width: 300, height: 20),
                CGRect(x: 640, y: 280, width: 300, height: 60)
            ],
            viewportHeight: 900
        )
        XCTAssertEqual(anchor, CGRect(x: 640, y: 280, width: 300, height: 60))
    }

    func testResolveAnchorPicksLargestFragmentWhenManyLongLines() {
        // ≥4 片（长段落中继多行）：走最大可视单片，不做多行 union
        let anchor = MarginNotesLayout.resolveAnchor(
            frags: [
                CGRect(x: 100, y: 100, width: 200, height: 20),
                CGRect(x: 100, y: 122, width: 200, height: 20),
                CGRect(x: 100, y: 144, width: 200, height: 20),
                CGRect(x: 100, y: 166, width: 200, height: 60)
            ],
            viewportHeight: 900
        )
        XCTAssertEqual(anchor, CGRect(x: 100, y: 166, width: 200, height: 60))
    }

    func testResolveAnchorVisibleBandIgnoresFarFragments() {
        // 视口带外（±64px）碎片不参与；带内单片稳定输出
        let anchor = MarginNotesLayout.resolveAnchor(
            frags: [
                CGRect(x: 100, y: -900, width: 200, height: 20),
                CGRect(x: 100, y: 400, width: 200, height: 20)
            ],
            viewportHeight: 900
        )
        XCTAssertEqual(anchor, CGRect(x: 100, y: 400, width: 200, height: 20))
    }

    // MARK: - place 左右分配

    func testPlaceSplitsLeftAndRightByBodyMidX() {
        // 双栏对开：正文盒中线 600 → 左栏锚点出左卡，右栏锚点出右卡（贴各自栏侧）
        let idLeft = UUID()
        let idRight = UUID()
        let anchors: [UUID: CGRect] = [
            idLeft: CGRect(x: 320, y: 200, width: 200, height: 20),
            idRight: CGRect(x: 700, y: 200, width: 220, height: 20)
        ]
        let (placements, droppedLeft, droppedRight) = MarginNotesLayout.place(
            anchors: anchors, bodyRect: bodyRect, viewport: viewport, cardHeights: [:]
        )
        XCTAssertEqual(droppedLeft + droppedRight, 0)
        XCTAssertEqual(placements.count, 2)
        let left = placements.first(where: { $0.id == idLeft })
        let right = placements.first(where: { $0.id == idRight })
        XCTAssertEqual(left?.side, .left)
        XCTAssertEqual(right?.side, .right)
        // 左卡右缘贴正文盒左缘减 10px；右卡左缘贴正文盒右缘加 10px
        if let left, let right {
            XCTAssertEqual(left.centerX, bodyRect.minX - MarginNotesLayout.cardEdgeInsets - left.width / 2, accuracy: 0.5)
            XCTAssertEqual(right.centerX, bodyRect.maxX + MarginNotesLayout.cardEdgeInsets + right.width / 2, accuracy: 0.5)
        } else {
            XCTFail("左右两张卡都应被排布")
        }
    }

    // MARK: - place 重叠 / 预留 / 溢出 / 窄留白

    func testPlacePushesOverlappingCardsDownWithGap() {
        // 同侧两张卡 anchor 重叠 → 后卡下推到前卡 bottom + 8
        let id1 = UUID()
        let id2 = UUID()
        let anchors: [UUID: CGRect] = [
            id1: CGRect(x: 320, y: 200, width: 200, height: 20),
            id2: CGRect(x: 320, y: 210, width: 200, height: 20)
        ]
        let heights: [UUID: CGFloat] = [id1: 120, id2: 90]
        let (placements, _, _) = MarginNotesLayout.place(
            anchors: anchors, bodyRect: bodyRect, viewport: viewport, cardHeights: heights
        )
        XCTAssertEqual(placements.count, 2)
        let tops = placements.sorted { $0.top < $1.top }
        XCTAssertEqual(tops[0].top, 200)
        XCTAssertEqual(tops[1].top, 200 + 120 + MarginNotesLayout.cardGap)
    }

    func testPlaceReservesTopPaddingForDogEar() {
        // 划线贴视口顶部 → 卡 top 钳到 72（避 DogEar 书签角标）
        let id = UUID()
        let anchors: [UUID: CGRect] = [id: CGRect(x: 320, y: 20, width: 200, height: 20)]
        let (placements, _, _) = MarginNotesLayout.place(
            anchors: anchors, bodyRect: bodyRect, viewport: viewport, cardHeights: [id: 100]
        )
        XCTAssertEqual(placements.first?.top, MarginNotesLayout.topPadding)
    }

    func testPlaceDropsCardsOverflowingViewportBottom() {
        // 卡整体放不进视口剩余空间 → 裁掉计 dropped，不置回
        let id = UUID()
        let anchors: [UUID: CGRect] = [id: CGRect(x: 320, y: 880, width: 200, height: 20)]
        let heights: [UUID: CGFloat] = [id: 120]
        let (placements, droppedLeft, _) = MarginNotesLayout.place(
            anchors: anchors, bodyRect: bodyRect, viewport: viewport, cardHeights: heights
        )
        XCTAssertTrue(placements.isEmpty)
        XCTAssertEqual(droppedLeft, 1)
    }

    func testPlaceSkipsSideWhenZoneTooNarrow() {
        // 该侧留白 < 180 → 整侧不排卡、不计 dropped
        let narrowBody = CGRect(x: 155, y: 0, width: 240, height: 900) // 左 zone = 155-10 = 145
        let id = UUID()
        let anchors: [UUID: CGRect] = [id: CGRect(x: 170, y: 200, width: 100, height: 20)]
        let (placements, droppedLeft, _) = MarginNotesLayout.place(
            anchors: anchors, bodyRect: narrowBody, viewport: viewport, cardHeights: [id: 100]
        )
        XCTAssertTrue(placements.isEmpty)
        XCTAssertEqual(droppedLeft, 0)
    }

    func testPlaceIndependentSidesDoNotCascadeEachOther() {
        // 左右两侧各自汇流，不互相下推
        let idLeft1 = UUID()
        let idLeft2 = UUID()
        let idRight = UUID()
        let anchors: [UUID: CGRect] = [
            idLeft1: CGRect(x: 320, y: 200, width: 200, height: 20),
            idLeft2: CGRect(x: 320, y: 230, width: 200, height: 20),
            idRight: CGRect(x: 700, y: 230, width: 220, height: 20)
        ]
        let heights: [UUID: CGFloat] = [idLeft1: 100, idLeft2: 100, idRight: 100]
        let (placements, _, _) = MarginNotesLayout.place(
            anchors: anchors, bodyRect: bodyRect, viewport: viewport, cardHeights: heights
        )
        XCTAssertEqual(placements.count, 3)
        // 右卡只剩一张，不因左侧两张而下推
        let right = placements.first(where: { $0.id == idRight })
        XCTAssertEqual(right?.top, 230)
        // 左二卡接左一卡之下
        let left2 = placements.first(where: { $0.id == idLeft2 })
        XCTAssertEqual(left2?.top, 200 + 100 + MarginNotesLayout.cardGap)
    }
}
