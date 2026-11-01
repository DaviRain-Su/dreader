import XCTest
@testable import DReader

/// 章级批翻:切包边界 / 宽容解析 / 调度兜底链
final class BatchTranslationTests: XCTestCase {

    // MARK: - 切包规划

    func testPlanChapterBatchesRespectsBudgetAndParagraphCap() {
        // 每段 100 字,预算 500 → 每包最多 5 段
        let paragraphs = (0..<12).map { (index: $0, text: String(repeating: "字", count: 100)) }
        let batches = AIAgentService.planChapterBatches(paragraphs, charBudget: 500)
        XCTAssertEqual(batches.count, 3)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 5 })
        XCTAssertEqual(batches.flatMap { $0.map(\.index) }, Array(0..<12), "切包不得丢段或改序")

        // 段数上限 60 优先(段小预算大时)
        let small = (0..<70).map { (index: $0, text: "文") }
        let capped = AIAgentService.planChapterBatches(small, charBudget: 100_000)
        XCTAssertEqual(capped.count, 2)
        XCTAssertEqual(capped.first?.count, AIAgentService.batchMaxParagraphs)
    }

    func testPlanChapterBatchesSplitsHugeParagraphIntoOneBatch() {
        // 超硬顶巨段:按句边界拆块,同编号多行必须进同一个包(跨包会互相覆盖丢前半译文)
        let longText = (0..<1200).map { _ in "这是一句很长的测试句子。" }.joined()
        XCTAssertGreaterThan(longText.count, AIAgentService.batchHardSegmentLimit)
        let batches = AIAgentService.planChapterBatches([(index: 3, text: longText)])
        XCTAssertEqual(batches.count, 1, "巨段拆块后同编号多行必须进同一个包")
        let mega = batches.first ?? []
        XCTAssertGreaterThan(mega.count, 1, "巨段应被拆成多个子块")
        XCTAssertTrue(mega.allSatisfy { $0.index == 3 })
        XCTAssertEqual(
            mega.map(\.text).joined(), longText,
            "拆块拼接后必须完整还原原文"
        )
    }

    func testPlanChapterBatchesFiltersEmptyAndKeepsSmallParagraphAlone() {
        let batches = AIAgentService.planChapterBatches([
            (index: 0, text: ""),
            (index: 1, text: "   \n\t "),
            (index: 2, text: String(repeating: "短", count: AIAgentService.batchHardSegmentLimit + 10)),
            (index: 3, text: "正常段"),
        ])
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches.contains { $0.map(\.index) == [2] }, "巨段独占包")
        XCTAssertTrue(batches.contains { $0.map(\.index) == [3] }, "巨段后的正常段另起包")
    }

    // MARK: - 宽容解析

    func testParseBatchResponseAcceptsCanonicalItemsShape() {
        let raw = #"{"items":[{"i":1,"t":"甲"},{"i":2,"t":"乙"}]}"#
        let parsed = AIAgentService.parseBatchResponse(raw, validIndices: [1, 2])
        XCTAssertEqual(parsed[1], "甲")
        XCTAssertEqual(parsed[2], "乙")
    }

    func testParseBatchResponseAcceptsAlternateShapesAndAliases() {
        // 顶层 map 形态
        let mapShape = AIAgentService.parseBatchResponse(#"{"1":"甲转换","2":"乙转换"}"#, validIndices: [1, 2])
        XCTAssertEqual(mapShape[1], "甲转换")
        XCTAssertEqual(mapShape[2], "乙转换")
        // 顶层数组 + 键名别名
        let arrayShape = AIAgentService.parseBatchResponse(
            #"[{"index":"4","translation":"四"},{"n":5,"text":"五"}]"#, validIndices: Set(1..<10))
        XCTAssertEqual(arrayShape[4], "四")
        XCTAssertEqual(arrayShape[5], "五")
        let itemsAlias = AIAgentService.parseBatchResponse(
            #"{"translations":[{"i":6,"zh":"陆"}]}"#, validIndices: [6])
        XCTAssertEqual(itemsAlias[6], "陆")
    }

    func testParseBatchResponseStripsFencesAndPrecedingNoise() {
        let raw = """
        好的,以下是译文:
        ```json
        {"items":[{"i":1,"t":"围栏甲"}]}
        ```
        """
        let parsed = AIAgentService.parseBatchResponse(raw, validIndices: [1])
        XCTAssertEqual(parsed[1], "围栏甲")
    }

    func testParseBatchResponseIgnoresForeignIndicesAndEmptyText() {
        let raw = #"{"items":[{"i":1,"t":""},{"i":99,"t":"不属于本包"},{"i":2,"t":"乙"}]}"#
        let parsed = AIAgentService.parseBatchResponse(raw, validIndices: [1, 2])
        XCTAssertEqual(parsed[1], nil, "空译文不能顶替兜底")
        XCTAssertEqual(parsed[99], nil)
        XCTAssertEqual(parsed[2], "乙")
    }

    func testParseBatchResponseMergesSameIndexPartsInOrder() {
        // 超巨段拆块:同编号多条目按行序拼接
        let raw = #"{"items":[{"i":7,"t":"上半段"},{"i":7,"t":"下半段"}]}"#
        let parsed = AIAgentService.parseBatchResponse(raw, validIndices: [7])
        XCTAssertEqual(parsed[7], "上半段下半段")
    }

    // MARK: - 批翻调度链路

    private func makeTempCacheDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dreader-batching-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testBatchTranslationPersistsCacheAndPublishesEveryParagraph() async throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        // 批翻 override 直接返回全量 map
        let agent = AIAgentService(testBatchDriverOverride: { items in
            Dictionary(items.map { ($0.index, "译\($0.index)") }, uniquingKeysWith: { a, _ in a })
        })
        let recorder = TranslationRecorder()
        await service.translateChapterBatch(
            paragraphs: [(0, "甲段原文"), (1, "乙段原文"), (2, "丙段原文")],
            bookTitle: "批翻测试书",
            chapterTitle: "第一章",
            chapterIndex: 5,
            agentService: agent,
            onParagraphTranslated: { idx, trans in recorder.append(idx, trans) }
        )
        let published = recorder.snapshotDict
        XCTAssertEqual(published.count, 3)
        XCTAssertEqual(published[0], "译0")
        // 缓存已落:
        let cached = service.getCachedTranslations(bookTitle: "批翻测试书", chapterIndex: 5)
        XCTAssertEqual(cached?[0], "译0")
        XCTAssertEqual(cached?[2], "译2")
        // 进度必达 1.0
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(service.currentProgressRatio, 1.0, accuracy: 0.0001)
    }

    func testBatchTranslationFallsBackPerParagraphWhenAgentFails() async throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        let recorder = TranslationRecorder()
        let agent = AIAgentService(testBatchDriverOverride: { _ in
            recorder.recordFailure()
            throw AIAgentService.BatchTranslationError.emptyResponse
        })
        // 兜底逐段走 agent.translate:切到 embedded 预设,避免测试拉起真实 CLI 子进程
        if let embedded = ACPAgentPreset.allPresets.first(where: { $0.driverType == .embedded }) {
            agent.selectPreset(embedded)
        }
        let publishRecorder = TranslationRecorder()
        await service.translateChapterBatch(
            paragraphs: [(0, "兜底段一"), (1, "兜底段二")],
            bookTitle: "批翻兜底书",
            chapterTitle: "第一章",
            chapterIndex: 0,
            agentService: agent,
            onParagraphTranslated: { idx, trans in publishRecorder.append(idx, trans) }
        )
        // 两次批翻尝试(并发 ×2)后逐段兜底:每段都有回调,进度必达 1.0
        XCTAssertEqual(publishRecorder.snapshotDict.count, 2, "批翻两连败必须逐段兜底完成")
        XCTAssertGreaterThanOrEqual(recorder.failureCount, 1, "批翻失败至少触发一次驱动调用")
        XCTAssertGreaterThanOrEqual(service.currentProgressRatio, 1.0)
        _ = service
    }

    func testBatchTranslationStopsEarlyWhenCancelled() async throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        let agent = AIAgentService(testBatchDriverOverride: { items in
            try await Task.sleep(for: .milliseconds(50))
            return Dictionary(items.map { ($0.index, "译\($0.index)") }, uniquingKeysWith: { a, _ in a })
        })
        let recorder = TranslationRecorder()
        await service.translateChapterBatch(
            paragraphs: (0..<30).map { (index: $0, text: "段落\($0)") },
            bookTitle: "批翻取消书",
            chapterTitle: "第一章",
            chapterIndex: 0,
            agentService: agent,
            onParagraphTranslated: { idx, trans in recorder.append(idx, trans) },
            isCancelled: { !recorder.snapshotTexts.isEmpty }
        )
        // 已取消路径仍必须收尾(进度复位 1.0、无崩溃)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(service.currentProgressRatio, 1.0, accuracy: 0.0001)
    }

    func testDescribeRangesCoalescesConsecutiveParagraphs() {
        XCTAssertEqual(
            BilingualTranslationService.describeRanges([3, 4, 5, 8, 12]),
            "正在翻译 P3–P5、P8、P12")
        XCTAssertEqual(BilingualTranslationService.describeRanges([]), "")
        XCTAssertEqual(BilingualTranslationService.describeRanges([7]), "正在翻译 P7")
        XCTAssertEqual(BilingualTranslationService.describeRanges([9, 10]), "正在翻译 P9–P10")
    }

    func testBatchStartedNotifiesMergedInFlightSet() async throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        let agent = AIAgentService(testBatchDriverOverride: { items in
            try await Task.sleep(for: .milliseconds(30))
            return Dictionary(items.map { ($0.index, "译\($0.index)") }, uniquingKeysWith: { a, _ in a })
        })
        let recorder = TranslationRecorder()
        // 65 段(超 60 段/包上限)→ 至少两包,并发执行时批次开始通知必须是
        // 合并后的在飞全集(页面提示是「全清重画」,单批通知会清掉另一批的提示)
        let startNotifications = BatchStartRecorder()
        await service.translateChapterBatch(
            paragraphs: (0..<65).map { (index: $0, text: "并发合并段落原文\($0)") },
            bookTitle: "批翻合并通知书",
            chapterTitle: "第一章",
            chapterIndex: 1,
            agentService: agent,
            onParagraphTranslated: { idx, trans in recorder.append(idx, trans) },
            onBatchStarted: { indices in startNotifications.record(indices) }
        )
        let snapshots = startNotifications.all()
        XCTAssertFalse(snapshots.isEmpty, "每包开始必须有通知")
        XCTAssertGreaterThanOrEqual(
            snapshots.map(\.count).max() ?? 0, 60,
            "通知必须为合并后的在飞全集(含并发另一包的段),而非单批段号")
        // 所有通知在各自时刻已是升序(页面画序稳定)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot, snapshot.sorted(), "通知必须升序")
        }
    }

    // MARK: - 回声假翻译闸门(参考 empty InlineNoteQuality)

    func testEchoGateRejectsOriginalAnUntranslatedLatin() {
        let original = "The quick brown fox jumps over the lazy dog near the river."
        XCTAssertTrue(BilingualTranslationService.isEchoTranslation(
            source: original,
            translated: original), "原样回吐必须拒绝")
        XCTAssertTrue(BilingualTranslationService.isEchoTranslation(
            source: original,
            translated: "The quick brown fox jumps over the lazy dog near the river.  ",
            ), "仅空白差异也算回吐")
        XCTAssertTrue(BilingualTranslationService.isEchoTranslation(
            source: original,
            translated: "Another fine text entirely in latin letters, still untranslated."),
            "英文原文未翻(仍纯拉丁长文本)必须拒绝")
        XCTAssertFalse(BilingualTranslationService.isEchoTranslation(
            source: original,
            translated: "敏捷的棕色狐狸跳过了河边那条懒狗。"),
            "正常中文译文放行")
        XCTAssertFalse(BilingualTranslationService.isEchoTranslation(
            source: original,
            translated: "Famous quote: “Mise en abyme” — 属于部分专名照抄,但整句已有中文"),
            "含中文的正常译文放行")
        XCTAssertFalse(BilingualTranslationService.isEchoTranslation(
            source: "中文原文整段内容。", translated: "中文原文整段内容的其他译文。"),
            "中文目标语言下不判拉丁规则")
    }

    // MARK: - 章指纹(抽段/改版后旧缓存作废,参考 empty 稳定哈希键)

    func testChapterFingerprintInvalidatesStaleCache() async throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        let agent = AIAgentService(testBatchDriverOverride: { items in
            Dictionary(items.map { ($0.index, "译\($0.index)") }, uniquingKeysWith: { a, _ in a })
        })
        let first = [(index: 0, text: "第一段原文。"), (index: 1, text: "第二段原文。")]
        await service.translateChapterBatch(
            paragraphs: first,
            bookTitle: "指纹书",
            chapterTitle: "第一章",
            chapterIndex: 0,
            agentService: agent,
            onParagraphTranslated: { _, _ in }
        )
        let fpA = BilingualTranslationService.chapterFingerprint(paragraphs: first)
        XCTAssertGreaterThan(fpA.count, 0)
        // 同版抽段:缓存继续有效
        XCTAssertTrue(service.chapterCacheMatchesFingerprint(
            bookTitle: "指纹书", chapterIndex: 0, fingerprint: fpA))
        XCTAssertEqual(service.getCachedTranslations(bookTitle: "指纹书", chapterIndex: 0)?[0], "译0")

        // 改版(同段号不同文本)→ 指纹不同 → 整章缓存作废,读不到旧译文
        let second: [(index: Int, text: String)] = [(0, "第一段原文。"), (1, "改版后的全新文本。")]
        let fpB = BilingualTranslationService.chapterFingerprint(paragraphs: second)
        XCTAssertNotEqual(fpA, fpB, "文本变化必须改变章指纹")
        XCTAssertFalse(service.chapterCacheMatchesFingerprint(
            bookTitle: "指纹书", chapterIndex: 0, fingerprint: fpB),
            "指纹不符的旧缓存必须作废")
        // 滞留写盘任务(含判废竞态后的补偿删除)需要一点调度时间收尾
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(service.getCachedTranslations(bookTitle: "指纹书", chapterIndex: 0),
                     "作废后的旧译文不得再被读到(防张冠李戴)")
    }

    func testChapterFingerprintKeepsLegacyCacheWithoutSidecar() throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        let dir = service.testCacheDirectory
        // 直接落一个「旧版本」缓存文件(无 sidecar)
        let legacy: [String: String] = ["0": "旧版译文"]
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: dir.appendingPathComponent("旧版书_ch2.json"))
        let cached = service.getCachedTranslations(bookTitle: "旧版书", chapterIndex: 2)
        XCTAssertEqual(cached?[0], "旧版译文")
        // 无 sidecar(legacy):指纹校验不得作废旧缓存
        XCTAssertTrue(service.chapterCacheMatchesFingerprint(
            bookTitle: "旧版书", chapterIndex: 2,
            fingerprint: BilingualTranslationService.chapterFingerprint(
                paragraphs: [(index: 0, text: "抽段后的原文")]))
        )
        XCTAssertEqual(service.getCachedTranslations(bookTitle: "旧版书", chapterIndex: 2)?[0],
                       "旧版译文", "legacy 缓存不无故作废")
    }

    // MARK: - 单车道排队 / 收尾完整性 / 兜底记账(评审回归)

    func testSecondBatchWaitsOnLaneInsteadOfBeingRejected() async throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        let agent = AIAgentService(testBatchDriverOverride: { items in
            try await Task.sleep(for: .milliseconds(60))
            return Dictionary(items.map { ($0.index, "译\($0.index)") }, uniquingKeysWith: { a, _ in a })
        })
        let first = TranslationRecorder()
        let second = TranslationRecorder()
        async let one: Void = service.translateChapterBatch(
            paragraphs: (0..<10).map { (index: $0, text: "甲章段落原文\($0)") },
            bookTitle: "车道书", chapterTitle: "第一章", chapterIndex: 0,
            agentService: agent,
            onParagraphTranslated: { idx, trans in first.append(idx, trans) }
        )
        // 同一车道另一章同时发起:必须排队等车道空出并跑完,而非静默拒收——
        // 否则「翻译全书」/切章入队的章会被整条空转排空
        async let two: Void = service.translateChapterBatch(
            paragraphs: (0..<6).map { (index: $0, text: "乙章段落原文\($0)") },
            bookTitle: "车道书", chapterTitle: "第二章", chapterIndex: 1,
            agentService: agent,
            onParagraphTranslated: { idx, trans in second.append(idx, trans) }
        )
        _ = await one
        _ = await two
        XCTAssertEqual(second.snapshotDict.count, 6, "第二会话必须排队跑完,不得被单车道拒收")
        XCTAssertEqual(first.snapshotDict.count, 10)
        XCTAssertEqual(
            Set(second.snapshotDict.keys), Set(0..<6))
    }

    func testCancelledBatchLeavesNoFingerprintSidecar() async throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        // 130 段 → 3 包(60 上限):包 1(0–59)快返发完即触发取消;后两包慢/不入住
        let agent = AIAgentService(testBatchDriverOverride: { items in
            let isSlowBatch = items.contains { $0.index >= 60 }
            if isSlowBatch {
                try await Task.sleep(for: .milliseconds(900))
            }
            return Dictionary(items.map { ($0.index, "译\($0.index)") }, uniquingKeysWith: { a, _ in a })
        })
        let paragraphs = (0..<130).map { (index: $0, text: "取消不能转正段落\($0)") }
        let recorder = TranslationRecorder()
        await service.translateChapterBatch(
            paragraphs: paragraphs,
            bookTitle: "取消完整性书", chapterTitle: "第一章", chapterIndex: 0,
            agentService: agent,
            onParagraphTranslated: { idx, trans in recorder.append(idx, trans) },
            isCancelled: { !recorder.snapshotTexts.isEmpty }
        )
        let fingerprintURL = service.testCacheDirectory
            .appendingPathComponent("取消完整性书_ch0.fingerprint")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fingerprintURL.path),
                       "中途取消/收尾不完整的批翻不得落章指纹(否则半截字典会被接力当作完整版永久跳章)")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(service.currentProgressRatio, 1.0, accuracy: 0.0001, "取消路径仍要收尾复位进度")
    }

    func testMissingParagraphFallsBackPublishedExactlyOnce() async throws {
        let service = BilingualTranslationService(cacheDirectory: makeTempCacheDirectory())
        let agent = AIAgentService(testBatchDriverOverride: { items in
            // 段 0 有译文,段 1 缺译 → 走逐段兜底(Embedded 驱动)
            Dictionary(items.filter { $0.index == 0 }.map { ($0.index, "译\($0.index)") },
                       uniquingKeysWith: { a, _ in a })
        })
        if let embedded = ACPAgentPreset.allPresets.first(where: { $0.driverType == .embedded }) {
            agent.selectPreset(embedded)
        }
        let publishRecorder = TranslationRecorder()
        await service.translateChapterBatch(
            paragraphs: [(0, "缺段原文甲"), (1, "缺段原文乙")],
            bookTitle: "缺段记账书", chapterTitle: "第一章", chapterIndex: 0,
            agentService: agent,
            onParagraphTranslated: { idx, trans in publishRecorder.append(idx, trans) }
        )
        // 缺译段在批翻轮只记账不发布;兜底轮(单段路径)负责翻译、计数与发布各一次。
        // 旧行为缺段会在两轮各发布一次,进度与通知都会虚涨
        XCTAssertEqual(publishRecorder.snapshotIndices.filter { $0 == 1 }.count, 1,
                       "缺译段只能发布一次(兜底记账不得双轨)")
        XCTAssertEqual(publishRecorder.snapshotIndices.filter { $0 == 0 }.count, 1)
        XCTAssertFalse((publishRecorder.snapshotDict[1] ?? "").isEmpty, "缺译段兜底必须产出译文")
    }
}

/// 批次开始通知记录器(仿 TranslationRecorder 的锁结构)
final class BatchStartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[Int]] = []

    func record(_ indices: [Int]) {
        lock.lock()
        snapshots.append(indices)
        lock.unlock()
    }

    func all() -> [[Int]] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }
}
