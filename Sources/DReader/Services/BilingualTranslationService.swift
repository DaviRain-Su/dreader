import Foundation

/// Manages dual-language interlinear paragraph translations and persistent disk caching
@Observable
final class BilingualTranslationService: @unchecked Sendable {
    static let shared = BilingualTranslationService()

    // In-memory cache: [bookTitle: [chapterIndex: [paragraphIndex: Chinese translation]]]
    // @ObservationIgnored 严肃隔离:锁临界区内写被观察属性会同步触发 SwiftUI 重排,
    // 而视图会重入读同一把 NSLock(非重入)→ 主线程死锁(实测过)。
    @ObservationIgnored private var memoryCache: [String: [Int: [Int: String]]] = [:]
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let lock = NSLock()
    /// 章级落盘串行链:同章每段各起一个「全量字典写盘」Task,乱序落地会用
    /// 旧快照覆盖新条目(实测丢段);按 key 前后链式等待,保证只落最新
    @ObservationIgnored private var diskWriteChain: [String: Task<Void, Never>] = [:]

    /// 这两个观察属性只在 MainActor 上写(不持 service 锁),供弹窗进度条观察
    var isTranslatingChapter: Bool = false
    var currentProgressRatio: Double = 0.0 // 0.0 to 1.0
    /// 当前批翻会话身份「书|章」:同一时刻只跑一个会话(单车道),同章重触发不叠加
    var activeBatchKey: String? = nil
    /// 弹窗接力/批翻状态行:「正在翻译 P3–P8、P12–P15」(MainActor 写,观察安全)
    var batchActivityDescription: String = ""
    /// 在飞批次的段号(service 锁保护,只描 UI 值用)
    @ObservationIgnored private var inFlightIndices: Set<Int> = []

    /// cacheDirectory 注入缝：测试用临时目录隔离磁盘（仿 RankingService.init(configuration:) 先例）
    init(cacheDirectory: URL? = nil) {
        if let dir = cacheDirectory {
            self.cacheDirectory = dir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let defaultDir = appSupport.appendingPathComponent("DReader/BilingualCache", isDirectory: true)
            self.cacheDirectory = defaultDir
            try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Cache Retrieval

    func getCachedTranslations(bookTitle: String, chapterIndex: Int) -> [Int: String]? {
        lock.lock()
        defer { lock.unlock() }

        let cleanTitle = sanitizeTitle(bookTitle)

        // 1. Check memory cache
        if let bookCache = memoryCache[cleanTitle], let chapterCache = bookCache[chapterIndex], !chapterCache.isEmpty {
            return chapterCache
        }

        // 2. Check disk cache
        let fileURL = cacheDirectory.appendingPathComponent("\(cleanTitle)_ch\(chapterIndex).json")
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }

        var result: [Int: String] = [:]
        for (k, v) in dict {
            if let idx = Int(k) {
                result[idx] = v
            }
        }

        if memoryCache[cleanTitle] == nil {
            memoryCache[cleanTitle] = [:]
        }
        memoryCache[cleanTitle]?[chapterIndex] = result
        return result
    }

    // MARK: - Save Translation

    func saveTranslation(
        bookTitle: String,
        chapterIndex: Int,
        paragraphIndex: Int,
        translation: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        let cleanTitle = sanitizeTitle(bookTitle)
        if memoryCache[cleanTitle] == nil {
            memoryCache[cleanTitle] = [:]
        }
        if memoryCache[cleanTitle]?[chapterIndex] == nil {
            memoryCache[cleanTitle]?[chapterIndex] = [:]
        }
        memoryCache[cleanTitle]?[chapterIndex]?[paragraphIndex] = translation

        // Persist to disk asynchronously — 关键:同章串行,防旧快照乱序覆盖新条目
        guard let chapterDict = memoryCache[cleanTitle]?[chapterIndex] else { return }
        let stringKeyedDict = chapterDict.reduce(into: [String: String]()) { acc, pair in
            acc["\(pair.key)"] = pair.value
        }
        let chapterKey = "\(cleanTitle)_ch\(chapterIndex)"
        let previousWrite = diskWriteChain[chapterKey]
        let cacheDir = self.cacheDirectory
        let writeTask = Task.detached(priority: .background) {
            if let previous = previousWrite { await previous.value } // 链式等待前一次写盘
            if let data = try? JSONEncoder().encode(stringKeyedDict) {
                let fileURL = cacheDir.appendingPathComponent("\(chapterKey).json")
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        diskWriteChain[chapterKey] = writeTask
    }

    // MARK: - 章指纹(防改版/改抽段规则后译文张冠李戴)

    /// 章级指纹:全章抽段原文的 FNV-1a 64(参考 empty 译文键的稳定哈希思路,保守落地为
    /// 「sidecar 文件 + 不匹配整体作废」——段号键与读写 API 全部保持不变)
    static func chapterFingerprint(paragraphs: [(index: Int, text: String)]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for paragraph in paragraphs {
            for byte in paragraph.text.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            hash = (hash ^ 0x1E) &* 0x100_0000_01b3 // 段间分隔
        }
        return String(format: "%016llx", hash)
    }

    @ObservationIgnored private var storedFingerprints: [String: String] = [:]

    #if DEBUG
    /// 测试缝:读缓存目录位置(与 init 的临时目录注入配套)
    var testCacheDirectory: URL { cacheDirectory }
    #endif

    /// 校验当前缓存是否还属于这版抽段:sidecar 缺失(legacy)视为有效;
    /// 指纹不同则内存清空 + 磁盘文件删除,返回 false
    @discardableResult
    func chapterCacheMatchesFingerprint(
        bookTitle: String, chapterIndex: Int, fingerprint: String
    ) -> Bool {
        let cleanTitle = sanitizeTitle(bookTitle)
        let sidecarKey = "\(cleanTitle)_ch\(chapterIndex)"
        let jsonURL = cacheDirectory.appendingPathComponent("\(sidecarKey).json")
        let sidecarURL = cacheDirectory.appendingPathComponent("\(sidecarKey).fingerprint")
        func invalidateStaleCache() {
            memoryCache[cleanTitle]?[chapterIndex] = nil
            try? FileManager.default.removeItem(at: jsonURL)
            // sidecar 保留:后续读取继续按指纹拒绝(迟到的链式写盘重写 json 也会被拦)
        }
        lock.lock()
        defer { lock.unlock() }
        if let stored = storedFingerprints[sidecarKey] {
            if stored == fingerprint || isLegacyFingerprint(stored) { return true }
            invalidateStaleCache() // 内存表命中但不匹配:同样整体作废
            return false
        }
        guard let stored = try? String(contentsOf: sidecarURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else {
            return true // legacy 无指纹文件:照旧可用(旧版本用户的缓存不无故作废)
        }
        storedFingerprints[sidecarKey] = stored
        if stored == fingerprint { return true }
        // 指纹不符:这版缓存已属于旧版本抽段/改版章,整体作废
        invalidateStaleCache()
        return false
    }

    /// 批翻整章收尾时落章指纹(sidecar 文件,13 字节,同步写)
    func recordChapterFingerprint(bookTitle: String, chapterIndex: Int, paragraphs: [(index: Int, text: String)]) {
        let cleanTitle = sanitizeTitle(bookTitle)
        let fingerprint = Self.chapterFingerprint(paragraphs: paragraphs)
        let sidecarKey = "\(cleanTitle)_ch\(chapterIndex)"
        lock.lock()
        storedFingerprints[sidecarKey] = fingerprint
        lock.unlock()
        let sidecarURL = cacheDirectory.appendingPathComponent("\(sidecarKey).fingerprint")
        try? fingerprint.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }

    private func isLegacyFingerprint(_ stored: String) -> Bool {
        false // 预留:后续若引入多代指纹格式,在这里按前缀识别
    }

    // MARK: - Translate Single Paragraph with Active Agent

    /// 回声假翻译闸门(纯函数可单测,参考 empty InlineNoteQuality):
    /// agent 偶尔把原文原样吐回来,这类「翻译」不得入库/上屏。
    /// 只拦 agent 输出,不看 Embedded 词典兜底(它的产物是最终回退,拦了就没有译文可写)。
    static func isEchoTranslation(source: String, translated: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.replacingOccurrences(of: "　", with: " ")
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func latinRatio(_ s: String) -> Double {
            guard !s.isEmpty else { return 0 }
            var letters = 0
            for character in s {
                guard character.isLetter,
                      let scalar = character.unicodeScalars.first,
                      scalar.value <= 0x24F else { continue } // 拉丁/ASCII 字母(East Asian ideograph 为 0x4E00+)
                letters += 1
            }
            return Double(letters) / Double(s.count)
        }
        let src = normalize(source)
        let out = normalize(translated)
        guard !out.isEmpty else { return false } // 空译文走既有 missing 链
        if out == src { return true }
        // 英文原文(拉丁占比高)而输出完全没有 CJK → 没翻过去/原样回吐
        let srcLatin = latinRatio(src)
        guard srcLatin >= 0.5 else { return false } // 原文本就是中文/其他文种,本闸不判
        let outHasCJK = out.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        if outHasCJK { return false } // 有中文即认可
        let outLatin = latinRatio(out)
        return outLatin >= 0.85 && out.count >= max(6, src.count / 2)
    }

    func translateParagraph(
        text: String,
        bookTitle: String,
        chapterTitle: String,
        chapterIndex: Int,
        paragraphIndex: Int,
        agentService: AIAgentService
    ) async -> String {
        if let cached = getCachedTranslations(bookTitle: bookTitle, chapterIndex: chapterIndex)?[paragraphIndex] {
            return cached
        }

        do {
            let translation = try await agentService.translate(
                text: text,
                bookTitle: bookTitle,
                chapterTitle: chapterTitle
            )
            guard !Self.isEchoTranslation(source: text, translated: translation) else {
                // 回声假翻译视同失败,转入 Embedded 词典兜底
                throw AIAgentService.BatchTranslationError.emptyResponse
            }
            saveTranslation(
                bookTitle: bookTitle,
                chapterIndex: chapterIndex,
                paragraphIndex: paragraphIndex,
                translation: translation
            )
            return translation
        } catch {
            let fallback = EmbeddedTranslationEngine.shared.translate(text: text, bookTitle: bookTitle)
            saveTranslation(
                bookTitle: bookTitle,
                chapterIndex: chapterIndex,
                paragraphIndex: paragraphIndex,
                translation: fallback
            )
            return fallback
        }
    }

    // MARK: - 章级批翻调度（分包并发；缺段/失败逐段兜底，进度必达）

    /// 默认并发包数（agent CLI 起进程 + LLM 限速压力兼顾）
    static let batchConcurrency = 2

    /// 兼容薄皮：既有「整章逐段」调用入口转投批翻调度器
    func translateEntireChapter(
        paragraphs: [(index: Int, text: String)],
        bookTitle: String,
        chapterTitle: String,
        chapterIndex: Int,
        agentService: AIAgentService,
        onParagraphTranslated: @escaping @MainActor (Int, String) -> Void
    ) async {
        await translateChapterBatch(
            paragraphs: paragraphs,
            bookTitle: bookTitle,
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
            agentService: agentService,
            onParagraphTranslated: onParagraphTranslated
        )
    }

    func translateChapterBatch(
        paragraphs: [(index: Int, text: String)],
        bookTitle: String,
        chapterTitle: String,
        chapterIndex: Int,
        agentService: AIAgentService,
        onParagraphTranslated: @escaping @MainActor (Int, String) -> Void,
        onBatchStarted: (@MainActor ([Int]) -> Void)? = nil,
        isCancelled: (@MainActor @Sendable () -> Bool)? = nil
    ) async {
        guard !paragraphs.isEmpty else { return }

        // 单车道登记(MainActor 原子判断):同一时刻只跑一个批翻会话,防重复触发/手动与接力并发互踩进度
        let nowKey = "\(bookTitle)|\(chapterIndex)"
        let proceed = await MainActor.run { () -> Bool in
            if self.isTranslatingChapter { return false }
            self.isTranslatingChapter = true
            self.currentProgressRatio = 0.0
            self.activeBatchKey = nowKey
            return true
        }
        guard proceed else {
            NSLog("[双语] 单车道跳过:书=%@ 章=%d 已有会话在翻(%@)", bookTitle, chapterIndex, activeBatchKey ?? "nil")
            return
        }
        defer {
            Task { @MainActor [key = nowKey] in
                self.finishBatchSession(key)
            }
        }

        // 章指纹校验:书改版/抽段规则变化会让段号整体错位,旧缓存一次性作废重翻
        let paragraphFingerprint = Self.chapterFingerprint(paragraphs: paragraphs)
        chapterCacheMatchesFingerprint(
            bookTitle: bookTitle, chapterIndex: chapterIndex, fingerprint: paragraphFingerprint
        )

        let cached = getCachedTranslations(bookTitle: bookTitle, chapterIndex: chapterIndex) ?? [:]
        let pending = paragraphs.filter { item in
            item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && cached[item.index] == nil
        }
        guard !pending.isEmpty else {
            await MainActor.run { self.currentProgressRatio = 1.0 }
            recordChapterFingerprint(bookTitle: bookTitle, chapterIndex: chapterIndex, paragraphs: paragraphs)
            return
        }

        let total = Double(pending.count)
        // 超巨段按句边界拆块后同编号多行进同一包；批翻缺编号时逐段兜底要用整段原文
        let fullTextByIndex = Dictionary(pending.map { ($0.index, $0.text) }, uniquingKeysWith: { a, _ in a })
        let batches = AIAgentService.planChapterBatches(pending)
        NSLog("[双语] 批翻开始：书=%@ 章=%d 段数=%d(缓存命中 %d) 包数=%d 驱动=%@",
              bookTitle, chapterIndex, paragraphs.count, cached.count, batches.count,
              agentService.currentPreset.name)
        let semaphore = AsyncSemaphore(permits: Self.batchConcurrency)
        let counter = ProgressCounter()
        let bookTitle = bookTitle
        let chapterTitle = chapterTitle
        let agent = agentService
        let service = self
        let cancelled: (@MainActor @Sendable () -> Bool)? = isCancelled
        let startedAt = Date()
        let batch_notifier: (@MainActor ([Int]) -> Void)? = onBatchStarted

        await withTaskGroup(of: Void.self) { group in
            for batch in batches {
                group.addTask {
                    await semaphore.acquire()
                    defer { semaphore.release() }
                    await service.processBatch(
                        batch, fullTextByIndex: fullTextByIndex, total: total,
                        bookTitle: bookTitle, chapterTitle: chapterTitle, chapterIndex: chapterIndex,
                        agent: agent, counter: counter,
                        onParagraphTranslated: onParagraphTranslated,
                        onBatchStarted: batch_notifier,
                        isCancelled: cancelled
                    )
                }
            }
        }
        NSLog("[双语] 批翻整章收尾：书=%@ 章=%d 耗时=%.1fs", bookTitle, chapterIndex, Date().timeIntervalSince(startedAt))
        await MainActor.run {
            self.finishBatchSession(nowKey)
        }
        // 本版抽段的章指纹落 sidecar,此后任何改版/规则变化在读取时立即判过期
        recordChapterFingerprint(bookTitle: bookTitle, chapterIndex: chapterIndex, paragraphs: paragraphs)
    }

    /// 单包处理：两次批翻尝试；缺编号段逐段兜底；两连败退化为整包串行逐段（单段路径内含 Embedded 兜底）
    private func processBatch(
        _ batch: [(index: Int, text: String)],
        fullTextByIndex: [Int: String],
        total: Double,
        bookTitle: String,
        chapterTitle: String,
        chapterIndex: Int,
        agent: AIAgentService,
        counter: ProgressCounter,
        onParagraphTranslated: @escaping @MainActor (Int, String) -> Void,
        onBatchStarted: (@MainActor ([Int]) -> Void)?,
        isCancelled: (@MainActor @Sendable () -> Bool)?
    ) async {
        let batchIndices = batch.map(\.index)
        await MainActor.run {
            self.registerBatchStart(batchIndices, notifier: onBatchStarted)
        }
        defer {
            Task { @MainActor in
                self.registerBatchEnd(batchIndices)
            }
        }
        var mapped: [Int: String] = [:]
        for attempt in 0..<2 {
            if let cancelledFn = isCancelled, await cancelledFn() { return }
            do {
                mapped = try await agent.translateParagraphBatch(
                    items: batch,
                    bookTitle: bookTitle,
                    chapterTitle: chapterTitle
                )
                NSLog("[双语] 包(\(batch.count)段) 批翻尝试\(attempt + 1) 完成：命中 %d/%d",
                      mapped.count, batch.count)
                break
            } catch {
                mapped = [:]
                NSLog("[双语] 包(%d段) 批翻尝试%d 失败：%@", batch.count, attempt + 1,
                      error.localizedDescription)
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }

        if let cancelledFn = isCancelled, await cancelledFn() { return }

        var missing: [(index: Int, text: String)] = []
        for (idx, _) in batch {
            let raw = mapped[idx] ?? ""
            let sourceText = fullTextByIndex[idx] ?? ""
            var trans: String? = raw.isEmpty ? nil : raw
            // 回声假翻译闸:原文原样吐回/英文未翻视同缺失,走逐段兜底重试
            if let t = trans, Self.isEchoTranslation(source: sourceText, translated: t) {
                trans = nil
                NSLog("[双语] 段 %d 批翻输出为回声假翻译,改走兜底", idx)
            }
            await saveAndPublish(
                idx: idx, text: trans, srcText: sourceText,
                total: total, bookTitle: bookTitle, chapterTitle: chapterTitle, chapterIndex: chapterIndex,
                agent: agent, counter: counter, onParagraphTranslated: onParagraphTranslated
            )
            if trans == nil {
                missing.append((index: idx, text: sourceText))
            }
        }
        if !missing.isEmpty {
            NSLog("[双语] 批翻缺 %d 段，开始逐段兜底：%d", missing.count,
                  missing.first?.index ?? -1)
        }
        guard !missing.isEmpty else { return }

        for item in missing {
            if let cancelledFn = isCancelled, await cancelledFn() { return }
            await saveAndPublish(
                idx: item.index, text: nil, srcText: item.text,
                total: total, bookTitle: bookTitle, chapterTitle: chapterTitle, chapterIndex: chapterIndex,
                agent: agent, counter: counter, onParagraphTranslated: onParagraphTranslated
            )
        }
    }

    /// 段级落地 + 进度推进：有译文直接存；无译文走单段路径（内部含 agent 重试与 Embedded 兜底）
    private func saveAndPublish(
        idx: Int,
        text: String?,
        srcText: String,
        total: Double,
        bookTitle: String,
        chapterTitle: String,
        chapterIndex: Int,
        agent: AIAgentService,
        counter: ProgressCounter,
        onParagraphTranslated: @escaping @MainActor (Int, String) -> Void
    ) async {
        let trans: String
        if let text, !text.isEmpty {
            saveTranslation(bookTitle: bookTitle, chapterIndex: chapterIndex, paragraphIndex: idx, translation: text)
            trans = text
        } else {
            guard !srcText.isEmpty else { return }
            trans = await translateParagraph(
                text: srcText, bookTitle: bookTitle, chapterTitle: chapterTitle,
                chapterIndex: chapterIndex, paragraphIndex: idx, agentService: agent
            )
        }
        counter.add(1)
        let ratio = min(1.0, counter.value / max(total, 1))
        await MainActor.run {
            self.currentProgressRatio = ratio
            onParagraphTranslated(idx, trans)
        }
    }

    private func sanitizeTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "　", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 批次进行状态(段号在飞)

    /// 会话收尾:只清 activeBatchKey 归属自己的状态(defer Task 晚到不会误清接力新章的会话)
    @MainActor
    private func finishBatchSession(_ key: String?) {
        guard key == nil || activeBatchKey == key else { return }
        isTranslatingChapter = false
        currentProgressRatio = 1.0
        activeBatchKey = nil
        clearInFlightAndResetDescription()
    }

    /// 包开始:登记在飞段号,发布「正在翻译 P3–P8、P12」给页面提示与弹窗状态行
    @MainActor
    private func registerBatchStart(_ indices: [Int], notifier: (@MainActor ([Int]) -> Void)?) {
        lock.lock()
        indices.forEach { inFlightIndices.insert($0) }
        lock.unlock()
        batchActivityDescription = Self.describeRanges(inFlightIndices)
        // 页面提示画**全量在飞集合**(setPending 是全清重画模型;并发包后到合并先到,不许互相清)
        notifier?(Array(inFlightIndices).sorted())
    }

    /// 包收尾:摘除在飞段号并续描(先落地的段由 onParagraphTranslated 直填,提示随之消失)
    @MainActor
    private func registerBatchEnd(_ indices: [Int]) {
        lock.lock()
        indices.forEach { inFlightIndices.remove($0) }
        lock.unlock()
        batchActivityDescription = Self.describeRanges(inFlightIndices)
    }

    /// 整章收尾:清空在飞与描述
    @MainActor
    private func clearInFlightAndResetDescription() {
        lock.lock()
        inFlightIndices = []
        lock.unlock()
        batchActivityDescription = ""
    }

    /// 段号集合 → 「P3–P8、P12」连续段合并描述(纯函数可单测)
    static func describeRanges(_ indices: Set<Int>) -> String {
        guard !indices.isEmpty else { return "" }
        let sorted = indices.sorted()
        var parts: [String] = []
        var start = sorted[0]
        var prev = sorted[0]
        for idx in sorted.dropFirst() {
            if idx == prev + 1 {
                prev = idx
                continue
            }
            parts.append(start == prev ? "P\(start)" : "P\(start)–P\(prev)")
            start = idx
            prev = idx
        }
        parts.append(start == prev ? "P\(start)" : "P\(start)–P\(prev)")
        return "正在翻译 " + parts.joined(separator: "、")
    }
}

/// 章级批翻并发计数（锁内读写，包间随进度可信递增）
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = 0.0

    func add(_ n: Double) {
        lock.lock()
        raw += n
        lock.unlock()
    }

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}

/// 异步信号量：批翻分包并发上限（内部小用，零依赖自持）
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    func acquire() async {
        if tryAcquire() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue(continuation)
        }
    }

    private func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if permits > 0 {
            permits -= 1
            return true
        }
        return false
    }

    /// 锁内：有空余许可直接移交并唤醒，否则入等待队列
    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if permits > 0 {
            permits -= 1
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    func release() {
        releaseSync()
    }

    private func releaseSync() {
        lock.lock()
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
            return
        }
        permits += 1
        lock.unlock()
    }
}
