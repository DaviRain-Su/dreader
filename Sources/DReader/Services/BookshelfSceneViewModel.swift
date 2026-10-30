import SwiftUI

/// 长廊只保存展示状态；书籍、封面和进入阅读仍由现有书架与 ReaderViewModel 提供。
@MainActor
@Observable
final class BookshelfSceneViewModel {
    struct Item: Identifiable {
        let virtualIndex: Int
        let book: EPUBBook
        let relative: Double
        var id: Int { virtualIndex }
    }

    private(set) var books: [EPUBBook] = []
    private(set) var position: Double = 0
    private(set) var target: Double = 0
    private(set) var selectedID: UUID?
    var detailID: UUID?
    var hoveredID: UUID?
    private(set) var isDragging = false
    private var dragOrigin: Double = 0
    private var snapTask: Task<Void, Never>?

    var reduceMotion = false {
        didSet {
            guard reduceMotion else { return }
            snapTask?.cancel()
            isDragging = false
            position = target
        }
    }

    var isLooping: Bool { books.count >= 5 }
    var selectedBook: EPUBBook? {
        books.first(where: { $0.id == selectedID }) ?? books.first
    }
    var detailBook: EPUBBook? {
        books.first(where: { $0.id == detailID })
    }

    static func wrapped(_ index: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    func updateBooks(_ newBooks: [EPUBBook]) {
        snapTask?.cancel()
        isDragging = false
        let oldIndex = selectedBookIndex ?? Int(target.rounded())
        let selected = selectedID
        books = newBooks
        if let detailID, !books.contains(where: { $0.id == detailID }) {
            self.detailID = nil
        }
        if let hoveredID, !books.contains(where: { $0.id == hoveredID }) {
            self.hoveredID = nil
        }
        guard !books.isEmpty else {
            selectedID = nil
            detailID = nil
            hoveredID = nil
            position = 0
            target = 0
            return
        }
        if let selected, let index = books.firstIndex(where: { $0.id == selected }) {
            selectedID = selected
            target = nearestTarget(index: index)
        } else {
            let index = min(max(oldIndex, 0), books.count - 1)
            selectedID = books[index].id
            target = Double(index)
        }
        position = target
    }

    private var selectedBookIndex: Int? {
        books.firstIndex(where: { $0.id == selectedID })
    }

    private func nearestTarget(index: Int) -> Double {
        guard isLooping else { return Double(index) }
        let count = books.count
        let base = (target / Double(count)).rounded()
        let candidates = [base - 1, base, base + 1].map { Double(index) + $0 * Double(count) }
        return candidates.min { abs($0 - target) < abs($1 - target) } ?? Double(index)
    }

    func select(_ book: EPUBBook) {
        if selectedID == book.id {
            detailID = book.id
        } else {
            select(book.id)
        }
    }

    func select(_ id: UUID) {
        snapTask?.cancel()
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        selectedID = id
        target = nearestTarget(index: index)
        updatePosition()
    }

    func move(by offset: Int) {
        snapTask?.cancel()
        guard books.count > 1, offset != 0 else { return }
        target = target.rounded() + Double(offset)
        if !isLooping {
            target = min(max(target, 0), Double(books.count - 1))
        }
        selectedID = books[Self.wrapped(Int(target.rounded()), books.count)].id
        updatePosition()
    }

    func openSelected() {
        if let selectedBook { detailID = selectedBook.id }
    }

    func dismissDetail() {
        detailID = nil
    }

    func startDragging() {
        guard books.count > 1 else { return }
        snapTask?.cancel()
        isDragging = true
        dragOrigin = position
        target = position
    }

    func dragChanged(translation: CGFloat, step: CGFloat) {
        guard isDragging, step > 0 else { return }
        var next = dragOrigin - Double(translation) / Double(step)
        if !isLooping, books.count > 1 {
            next = min(max(next, 0), Double(books.count - 1))
        }
        position = next
        target = next
        selectedID = books[Self.wrapped(Int(next.rounded()), books.count)].id
    }

    func endDragging() {
        guard isDragging else { return }
        isDragging = false
        target = target.rounded()
        selectedID = books[Self.wrapped(Int(target), books.count)].id
        updatePosition()
    }

    func scrollBy(_ delta: Double) {
        guard books.count > 1, delta != 0 else { return }
        target += delta
        if !isLooping {
            target = min(max(target, 0), Double(books.count - 1))
        }
        selectedID = books[Self.wrapped(Int(target.rounded()), books.count)].id
        updatePosition()
        snapTask?.cancel()
        snapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self?.snapScrolling()
        }
    }

    func snapScrolling() {
        guard books.count > 1 else { return }
        target = position.rounded()
        if !isLooping {
            target = min(max(target, 0), Double(books.count - 1))
        }
        selectedID = books[Self.wrapped(Int(target), books.count)].id
        updatePosition()
    }

    private func updatePosition() {
        normalizeLoopIfNeeded()
        if reduceMotion {
            position = target
        } else {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                position = target
            }
        }
    }

    private func normalizeLoopIfNeeded() {
        guard isLooping, abs(target) >= Double(books.count * 4) else { return }
        let shift = (target / Double(books.count)).rounded() * Double(books.count)
        target -= shift
        position -= shift
    }

    /// 仅返回当前位置附近的可见项；大量书籍不复制数据，也不创建全量视图。
    func visibleItems(radius: Int = 8) -> [Item] {
        guard !books.isEmpty else { return [] }
        if isLooping {
            let lower = Int(position.rounded(.down)) - radius
            let upper = Int(position.rounded(.up)) + radius
            return (lower...upper).compactMap { virtual in
                let relative = Double(virtual) - position
                guard abs(relative) <= Double(radius) else { return nil }
                return Item(virtualIndex: virtual,
                            book: books[Self.wrapped(virtual, books.count)], relative: relative)
            }
        }
        return books.indices.compactMap { index in
            let relative = Double(index) - position
            guard abs(relative) <= Double(radius) else { return nil }
            return Item(virtualIndex: index, book: books[index], relative: relative)
        }
    }

    func openness(for relative: Double) -> Double {
        if reduceMotion { return abs(relative) < 0.5 ? 1 : 0 }
        let value = max(0, 1 - abs(relative))
        return value * value * (3 - 2 * value)
    }

    /// 当前封面逐渐占据额外宽度，邻居平滑让位，不在切换瞬间跳动。
    static func xOffset(relative: Double, spineWidth: CGFloat,
                        coverWidth: CGFloat, gap: CGFloat) -> CGFloat {
        let clamped = min(max(relative, -1), 1)
        let spread = abs(relative) < 1
            ? (clamped + sin(Double.pi * clamped) / Double.pi) / 2
            : (relative < 0 ? -0.5 : 0.5)
        return CGFloat(relative) * (spineWidth + gap)
            + (coverWidth - spineWidth + 1.6 * gap) * CGFloat(spread)
    }
}
