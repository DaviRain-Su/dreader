import XCTest
@testable import DReader

/// 章接力队列:辐射序 / 跳已译 / 插队 / 全书 / 取消
final class BilingualChapterQueueTests: XCTestCase {

    private func waitUntil(
        _ condition: @autoclosure @escaping () -> Bool,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("等待队列条件超时")
    }

    func testRadiatingOrderExpandsAroundCurrent() {
        XCTAssertEqual(BilingualChapterQueue.radiatingOrder(current: 2, count: 5), [2, 3, 1, 4, 0])
        XCTAssertEqual(BilingualChapterQueue.radiatingOrder(current: 0, count: 5), [0, 1, 2, 3, 4])
        XCTAssertEqual(BilingualChapterQueue.radiatingOrder(current: 4, count: 5), [4, 3, 2, 1, 0])
        XCTAssertEqual(BilingualChapterQueue.radiatingOrder(current: 0, count: 1), [0])
        XCTAssertEqual(BilingualChapterQueue.radiatingOrder(current: 3, count: 0), [])
    }

    func testScheduleTranslatesCurrentFirst() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, _ in false }
        queue.translateHandler = { _, index in
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "接力书", chapterCount: 6, fromIndex: 2)
        // 当前章必须最先开始翻
        try await waitUntil(!recorder.snapshotIndices.isEmpty)
        XCTAssertEqual(recorder.snapshotIndices.first, 2, "开双语先翻当前章")
        queue.cancel(forKey: nil)
        try await waitUntil(!queue.hasPendingWork)
    }

    func testScheduleTranslatesCurrentOnly() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, _ in false }
        queue.translateHandler = { _, index in
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "单章书", chapterCount: 8, fromIndex: 3)
        try await waitUntil(recorder.snapshotIndices.contains(3))
        // 当前章翻完即停:相邻章(2/4)不得自动开翻(用户口径:开双语只翻当前章)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(recorder.snapshotIndices, [3], "开双语只翻当前章,不辐射相邻章")
        // 切章到未译的新章:单章模式继续只排新章
        queue.reprioritize(fromIndex: 6)
        try await waitUntil(recorder.snapshotIndices.contains(6))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(recorder.snapshotIndices, [3, 6], "切章只补翻新当前章")
        queue.cancel(forKey: nil)
        try await waitUntil(!queue.hasPendingWork)
    }

    func testScheduleSkipsAlreadyTranslatedChapters() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, index in index == 0 }
        queue.translateHandler = { _, index in
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "跳译书", chapterCount: 4, fromIndex: 1)
        // 辐射序 1,2,3,0 → 已译的第 0 章跳过
        queue.requestFullBook(fromIndex: 1)
        try await waitUntil(recorder.snapshotIndices.count >= 3)
        queue.cancel(forKey: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.snapshotIndices, [1, 2, 3], "已译章必须整章跳过")
    }

    func testReprioritizePutsNewChapterFirst() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, _ in false }
        queue.translateHandler = { _, index in
            try? await Task.sleep(for: .milliseconds(30))
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "插队书", chapterCount: 6, fromIndex: 0)
        // 当前章(0)翻出后再切到第 4 章:4 必须立即起翻(或紧随不打断的在翻章),
        // 排在旧队列的下家 5 之前(辐射重排生效)
        try await waitUntil(recorder.snapshotIndices.count >= 1)
        queue.reprioritize(fromIndex: 4)
        try await waitUntil(recorder.snapshotIndices.count >= 2 && recorder.snapshotIndices.contains(4))
        try await waitUntil(!queue.hasPendingWork)
        let seq = recorder.snapshotIndices
        XCTAssertEqual(seq.first, 0)
        if let slot4 = seq.firstIndex(of: 4), let slot5 = seq.firstIndex(of: 5) {
            XCTAssertLessThan(slot4, slot5, "切章后 4 必须排在旧邻 5 之前(辐射重排生效)")
        }
        queue.cancel(forKey: nil)
        try await waitUntil(!queue.hasPendingWork)
    }

    func testRequestFullBookQueuesAllUntranslated() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, index in index == 0 }
        queue.translateHandler = { _, index in
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "全书书", chapterCount: 5, fromIndex: 2)
        queue.requestFullBook(fromIndex: 2)
        try await waitUntil(recorder.snapshotIndices.count >= 4)
        try await Task.sleep(for: .milliseconds(60))
        queue.cancel(forKey: nil)
        try await waitUntil(!queue.hasPendingWork)
        XCTAssertEqual(
            Set(recorder.snapshotIndices), Set(1..<5),
            "全书把所有未译章排进队列;已译的第 0 章由过滤机制跳过"
        )
    }

    func testCancelStopsTheLoopImmediately() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, _ in false }
        queue.translateHandler = { _, index in
            try? await Task.sleep(for: .milliseconds(40))
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "取消书", chapterCount: 12, fromIndex: 0)
        try await waitUntil(!recorder.snapshotIndices.isEmpty)
        queue.cancel(forKey: "取消书")
        // cancel 时已开始的章会拖一个尾(被取消Task的 sleep 提前返回,不再排队新章)——先让尾巴落地
        try await Task.sleep(for: .milliseconds(250))
        let snapshot = recorder.snapshotIndices.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(recorder.snapshotIndices.count, snapshot, "cancel 后队列不得继续翻新章")
        XCTAssertFalse(queue.isTranslating)

        // cancel 传别的 key 不清当前队列
        queue.schedule(bookKey: "另一本", chapterCount: 3, fromIndex: 0)
        queue.cancel(forKey: "对的key不匹配")
        XCTAssertTrue(queue.hasPendingWork, "cancel 传别的 key 不清当前队列")
        queue.cancel(forKey: "另一本")
        try await waitUntil(!queue.hasPendingWork)
    }
}
