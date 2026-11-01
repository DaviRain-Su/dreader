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

    func testFullBookScheduleKeepsPendingQueueIntact() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, _ in false }
        queue.translateHandler = { _, index in
            try? await Task.sleep(for: .milliseconds(200))
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "接力书2", chapterCount: 6, fromIndex: 0)
        try await waitUntil(queue.activeIndex == 0) // 明确 0 在翻
        queue.requestFullBook(fromIndex: 0) // pending=[1..5]
        try await waitUntil(recorder.snapshotIndices.contains(0))
        // 0 翻出后切章:schedule 不得把全书模式降级——否则余列被静默清空,
        // 后台接力整条失联且永不恢复
        queue.schedule(bookKey: "接力书2", chapterCount: 6, fromIndex: 2)
        try await waitUntil(!queue.hasPendingWork)
        XCTAssertEqual(Set(recorder.snapshotIndices), Set(0..<6),
                       "全书接力中切章,其余未译章必须保持队列在场(已翻章重复允许)")
        queue.cancel(forKey: nil)
    }

    func testReprioritizeBackToActiveChapterClearsStalePending() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, _ in false }
        queue.translateHandler = { _, index in
            try? await Task.sleep(for: .milliseconds(80))
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "残列书", chapterCount: 4, fromIndex: 0)
        try await waitUntil(recorder.snapshotIndices.contains(0)) // 0 翻完(单章模式排空即停)
        queue.reprioritize(fromIndex: 2)
        try await waitUntil(queue.activeIndex == 2)
        queue.reprioritize(fromIndex: 3) // 切走:pending=[3](2 还在翻)
        queue.reprioritize(fromIndex: 2) // 切回正在翻的 2:残留的 3 必须被清
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(recorder.snapshotIndices, [0, 2],
                       "切回在翻章时旧 pending 不得在其完成后白翻")
        queue.cancel(forKey: nil)
        try await waitUntil(!queue.hasPendingWork)
    }

    func testFullBookReprioritizesAroundTranslatedTarget() async throws {
        let queue = BilingualChapterQueue()
        let recorder = TranslationRecorder()
        queue.isTranslated = { _, index in index == 5 }
        queue.translateHandler = { _, index in
            try? await Task.sleep(for: .milliseconds(150))
            recorder.append(index)
            return true
        }
        queue.schedule(bookKey: "转向书", chapterCount: 6, fromIndex: 0)
        try await waitUntil(queue.activeIndex == 0)
        queue.requestFullBook(fromIndex: 0)
        try await waitUntil(recorder.snapshotIndices.contains(1)) // 0、1 依次完成,2 起翻
        // 切到已译章 5:全书模式不得因「目标已译」放弃围绕新目标重排。
        // 重排生效的核心标志:先排完 pending 队首 4(围绕 5 的辐射序),旧的 3 退居其后
        queue.reprioritize(fromIndex: 5)
        try await waitUntil(!queue.hasPendingWork)
        let seq = recorder.snapshotIndices
        if let slot2 = seq.firstIndex(of: 2),
           let slot3 = seq.firstIndex(of: 3),
           let slot4 = seq.firstIndex(of: 4) {
            XCTAssertLessThan(slot2, slot3, "在翻的章不受重排打断")
            XCTAssertLessThan(slot4, slot3, "已译目标(5)不阻断重排:转向后 4 先于旧序 3")
        } else {
            XCTFail("重排后 2/3/4 都应被翻(仅 5 已译不翻),实际序:\(seq)")
        }
        queue.cancel(forKey: nil)
    }
}
