import XCTest
@testable import DReader

@MainActor
final class BookshelfGalleryTests: XCTestCase {
    private func makeBooks(_ count: Int) -> [EPUBBook] {
        (0..<count).map { index in
            let chapter = EPUBChapter(id: "c\(index)", title: "第一章",
                                      fileURL: URL(fileURLWithPath: "/tmp/book-\(index).xhtml"), orderIndex: 0)
            return EPUBBook(title: "第 \(index) 本书", author: "作者 \(index)",
                            fileURL: URL(fileURLWithPath: "/tmp/book-\(index).epub"),
                            unzippedDirectory: URL(fileURLWithPath: "/tmp"),
                            opfDirectory: URL(fileURLWithPath: "/tmp"), chapters: [chapter])
        }
    }

    private func makeModel(count: Int) -> BookshelfSceneViewModel {
        let model = BookshelfSceneViewModel()
        model.reduceMotion = true
        model.updateBooks(makeBooks(count))
        return model
    }

    func testSelectionAndDetailOnlyOpenForCurrentBook() {
        let model = makeModel(count: 3)
        let first = try! XCTUnwrap(model.selectedBook)
        model.select(first)
        XCTAssertEqual(model.detailID, first.id)
        model.dismissDetail()
        let second = model.books[1]
        model.select(second)
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertNil(model.detailID)
        model.openSelected()
        XCTAssertEqual(model.detailID, second.id)
    }

    func testSmallLibrariesClampInsteadOfWrappingPastEitherEnd() {
        for count in 1...4 {
            let model = makeModel(count: count)
            model.move(by: -1)
            XCTAssertEqual(model.target, 0)
            model.move(by: 100)
            XCTAssertEqual(model.target, Double(count - 1))
            XCTAssertEqual(model.selectedID, model.books.last?.id)
            model.move(by: 100)
            XCTAssertEqual(model.target, Double(count - 1))
            model.move(by: -100)
            XCTAssertEqual(model.target, 0)
        }
    }

    func testLoopUsesIDsWithoutCopyingTheBookArray() {
        let model = makeModel(count: 12)
        let last = model.books.last!
        model.move(by: -1)
        XCTAssertEqual(model.selectedID, last.id)
        XCTAssertEqual(model.target, -1)
        XCTAssertEqual(model.books.count, 12)
        XCTAssertTrue(model.isLooping)
        XCTAssertLessThanOrEqual(model.visibleItems().count, 17)
        XCTAssertTrue(model.visibleItems().contains { $0.book.id == last.id })
    }

    func testVisibleWindowIsBoundedForLargeLibraries() {
        let model = makeModel(count: 1000)
        model.select(model.books[500].id)
        let items = model.visibleItems()
        XCTAssertLessThanOrEqual(items.count, 17)
        XCTAssertEqual(model.books.count, 1000)
        XCTAssertTrue(items.allSatisfy { abs($0.relative) <= 8 })
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    func testReconcileKeepsValidIDAndChoosesNeighborAfterDeletion() {
        let model = makeModel(count: 12)
        let selected = model.books[5]
        model.select(selected)
        model.updateBooks(Array(model.books[3...8]))
        XCTAssertEqual(model.selectedID, selected.id)
        model.openSelected()
        model.updateBooks(model.books.filter { $0.id != selected.id })
        XCTAssertNotEqual(model.selectedID, selected.id)
        XCTAssertNil(model.detailID)
        model.updateBooks([])
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.target, 0)
        XCTAssertTrue(model.visibleItems().isEmpty)
    }

    func testDragAndWheelHaveDeterministicSnapBehavior() {
        let model = makeModel(count: 8)
        model.startDragging()
        model.dragChanged(translation: -240, step: 120)
        model.endDragging()
        XCTAssertEqual(model.target, 2)
        model.scrollBy(0.4)
        model.snapScrolling()
        XCTAssertEqual(model.target, 2)
        model.scrollBy(0.6)
        model.snapScrolling()
        XCTAssertEqual(model.target, 3)
        XCTAssertEqual(model.selectedID, model.books[3].id)
    }

    func testReducedMotionSkipsInterpolatedOpenness() {
        let model = makeModel(count: 3)
        model.select(model.books[2].id)
        XCTAssertEqual(model.position, 2)
        XCTAssertEqual(model.openness(for: 0), 1)
        XCTAssertEqual(model.openness(for: 1), 0)
    }

    func testCoverOffsetIsContinuousAndNeighborsMakeRoom() {
        let center = BookshelfSceneViewModel.xOffset(relative: 0, spineWidth: 30, coverWidth: 150, gap: 6)
        let left = BookshelfSceneViewModel.xOffset(relative: -1, spineWidth: 30, coverWidth: 150, gap: 6)
        let right = BookshelfSceneViewModel.xOffset(relative: 1, spineWidth: 30, coverWidth: 150, gap: 6)
        XCTAssertEqual(center, 0)
        XCTAssertLessThan(left, 0)
        XCTAssertGreaterThan(right, 0)
        XCTAssertEqual(right, -left, accuracy: 0.0001)
    }

    func testDetailProvidesRealBookForReadingCallback() {
        let model = makeModel(count: 1)
        model.openSelected()
        let detail = try! XCTUnwrap(model.detailBook)
        var received: EPUBBook?
        let onSelectBook: (EPUBBook) -> Void = { received = $0 }
        onSelectBook(detail)
        XCTAssertEqual(received?.id, model.books[0].id)
    }
}
