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
    /// 旧快照覆盖新条目(实测丢段);按 key 前后链式等待,保证只落最新。
    /// 任务执行时才锁内现取全集快照——启动时捕获的旧快照不再滞留链上,
    /// 判废前提交的写任务也不会把已作废的字典复活(迟到写盘污染裸读路径)
    @ObservationIgnored private var diskWriteChain: [String: Task<Void, Never>] = [:]
    /// 章写盘递增序号:链中任务执行时用它判定自己是否仍排链尾,
    /// 中段任务静默让位,落盘 IO 只随「最后入队的那波」走(逐段 O(n²) 写放大消失)
    @ObservationIgnored private var diskWriteSeq: [String: Int] = [:]
    /// 章写盘代纪:判废时递增;在飞写任务在取字典/落盘各校验点发现代纪变更
    /// 即放弃,落盘后校验不通过还会补偿删除——判废与写盘竞态时旧字典不能复活
    @ObservationIgnored private var diskEpoch: [String: Int] = [:]
    /// 单车道:同一时刻只跑一个批翻会话;被占时排队等待(而非拒收)——
    /// 「翻译全书」/切章入队的章是等车道空出来的,逐一拒收会把整条接力队列空转排空
    @ObservationIgnored private let laneSemaphore = AsyncSemaphore(permits: 1)
    /// 批翻会话序号:finishBatchSession 双重身份校验用(同章晚到的 defer 不误清新会话)
    @ObservationIgnored private var activeSessionSerial: Int = 0

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
        let fileURL = cacheDirectory.appendingPathComponent("\(chapterFileKey(cleanTitle: cleanTitle, chapterIndex: chapterIndex)).json")
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
        let cleanTitle = sanitizeTitle(bookTitle)
        if memoryCache[cleanTitle] == nil {
            memoryCache[cleanTitle] = [:]
        }
        if memoryCache[cleanTitle]?[chapterIndex] == nil {
            memoryCache[cleanTitle]?[chapterIndex] = [:]
        }
        memoryCache[cleanTitle]?[chapterIndex]?[paragraphIndex] = translation
        lock.unlock()

        // Persist to disk asynchronously — 章写链负责串行与「只落链尾」
        enqueueChapterWrite(cleanTitle: cleanTitle, chapterIndex: chapterIndex)
    }

    // MARK: - 章级写链(执行时现取全集,链尾独写)

    /// 一章缓存的共用键:`书名_ch序号`,磁盘文件/写链/指纹 sidecar 同源
    private func chapterFileKey(cleanTitle: String, chapterIndex: Int) -> String {
        "\(cleanTitle)_ch\(chapterIndex)"
    }

    /// 把一章的落盘任务追加到章写链。任务执行时才锁内现取当下全集:
    /// 链尾永远写最新快照,不再有「提交时捕获」的旧字典滞留链上。
    private func enqueueChapterWrite(cleanTitle: String, chapterIndex: Int) {
        let chapterKey = chapterFileKey(cleanTitle: cleanTitle, chapterIndex: chapterIndex)
        let cacheDir = self.cacheDirectory
        lock.lock()
        let previousWrite = diskWriteChain[chapterKey]
        diskWriteSeq[chapterKey, default: 0] &+= 1
        let seq = diskWriteSeq[chapterKey] ?? 0
        let epoch = diskEpoch[chapterKey] ?? 0
        lock.unlock()
        let writeTask = Task.detached(priority: .background) {
            if let previous = previousWrite { await previous.value } // 链式等待前一次写盘
            // 已有更后任务接管此章:本轮由它写,中段任务静默让位(写盘 IO 不再逐段放大)
            guard self.isChainTail(chapterKey: chapterKey, seq: seq) else { return }
            // 判废后(epoch 已翻代)不再写:旧字典不能复活
            guard self.hasDiskEpoch(chapterKey: chapterKey, epoch: epoch) else { return }
            guard let dict = self.currentDiskChapterDict(cleanTitle: cleanTitle, chapterIndex: chapterIndex) else { return }
            guard self.hasDiskEpoch(chapterKey: chapterKey, epoch: epoch) else { return }
            if let data = try? JSONEncoder().encode(dict) {
                let fileURL = cacheDir.appendingPathComponent("\(chapterKey).json")
                try? data.write(to: fileURL, options: .atomic)
                // 写后补偿:字典已取好但落盘瞬间恰逢判废 → 补偿删除,不让旧内容复活
                guard self.hasDiskEpoch(chapterKey: chapterKey, epoch: epoch) else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
            }
        }
        lock.lock()
        diskWriteChain[chapterKey] = writeTask
        lock.unlock()
    }

    private func hasDiskEpoch(chapterKey: String, epoch: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (diskEpoch[chapterKey] ?? 0) == epoch
    }

    private func isChainTail(chapterKey: String, seq: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return diskWriteSeq[chapterKey] == seq
    }

    /// 锁内取一章当前全字典(字符串键);空章返回 nil(不落盘)
    private func currentDiskChapterDict(cleanTitle: String, chapterIndex: Int) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let dict = memoryCache[cleanTitle]?[chapterIndex], !dict.isEmpty else { return nil }
        return dict.reduce(into: [String: String]()) { acc, pair in
            acc["\(pair.key)"] = pair.value
        }
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
    /// 指纹不同则内存清空 + 磁盘 json/sidecar 一起删除,返回 false
    @discardableResult
    func chapterCacheMatchesFingerprint(
        bookTitle: String, chapterIndex: Int, fingerprint: String
    ) -> Bool {
        let cleanTitle = sanitizeTitle(bookTitle)
        let sidecarKey = chapterFileKey(cleanTitle: cleanTitle, chapterIndex: chapterIndex)
        let jsonURL = cacheDirectory.appendingPathComponent("\(sidecarKey).json")
        let sidecarURL = cacheDirectory.appendingPathComponent("\(sidecarKey).fingerprint")
        func invalidateStaleCache() {
            memoryCache[cleanTitle]?[chapterIndex] = nil
            storedFingerprints.removeValue(forKey: sidecarKey)
            diskEpoch[sidecarKey, default: 0] &+= 1
            try? FileManager.default.removeItem(at: jsonURL)
            // sidecar 一并删除:此后的判定走 legacy 分支,同一章只在「第一次发现过期」
            // 时作废一轮,不再每轮 body 读都重判一次(旧实现保留 sidecar 会陷入反复作废);
            // 滞留写盘任务执行时锁内现取全集,被清空的章取到 nil 不写盘——错位旧译不会复活
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        lock.lock()
        defer { lock.unlock() }
        if let stored = storedFingerprints[sidecarKey] {
            guard stored == fingerprint else {
                invalidateStaleCache() // 内存指纹表命中但不匹配:同样整体作废
                return false
            }
            return true
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
        let sidecarKey = chapterFileKey(cleanTitle: cleanTitle, chapterIndex: chapterIndex)
        lock.lock()
        storedFingerprints[sidecarKey] = fingerprint
        lock.unlock()
        let sidecarURL = cacheDirectory.appendingPathComponent("\(sidecarKey).fingerprint")
        try? fingerprint.write(to: sidecarURL, atomically: true, encoding: .utf8)
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
        onParagraphTranslated: @escaping @MainActor (Int, String) -> Void,
        onBatchStarted: (@MainActor ([Int]) -> Void)? = nil
    ) async {
        await translateChapterBatch(
            paragraphs: paragraphs,
            bookTitle: bookTitle,
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
            agentService: agentService,
            onParagraphTranslated: onParagraphTranslated,
            onBatchStarted: onBatchStarted
        )
    }

    /// 批翻会话键单一出处:「书名|章序」——service 内登记与 ReaderViewModel 的
    /// 让路判定(后台接力进行中不叠手动批翻)共用自己的这个实现
    static func batchKey(bookTitle: String, chapterIndex: Int) -> String {
        "\(bookTitle)|\(chapterIndex)"
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

        // 单车道:被占时排队等待而非拒收——接力队列/手动触发的章都要跑,只有
        // 「等待」语义能保住顺序与不空转。acquire 后登记会话身份(MainActor 原子);
        // isTranslatingChapter 只是观察镜像,窗口语义由信号量独占保证
        await laneSemaphore.acquire()
        guard !Task.isCancelled else {
            laneSemaphore.release() // 排队期间被取消(换书/关双语):让位,不占用车道
            return
        }
        let nowKey = Self.batchKey(bookTitle: bookTitle, chapterIndex: chapterIndex)
        let sessionId = await MainActor.run { () -> Int in
            self.activeSessionSerial &+= 1
            self.isTranslatingChapter = true
            self.currentProgressRatio = 0.0
            self.activeBatchKey = nowKey
            return self.activeSessionSerial
        }
        defer {
            laneSemaphore.release() // 车道让位:排队等候的下个会话立即接管
            let key = nowKey
            let sid = sessionId
            Task { @MainActor in
                self.finishBatchSession(key: key, sessionId: sid)
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
        // 收尾完整性核查:全部待翻段都有译文才落章指纹并补写一次盘。中途取消/
        // 兜底失败的半截字典若写入指纹,会被 isTranslated「非空即真」当完整版放行,
        // 自动接力从此永久跳过该章且缓存残缺无从发觉——残缺时保持无指纹状态,
        // 下次进章指纹判定重新走全章翻译
        let settled = getCachedTranslations(bookTitle: bookTitle, chapterIndex: chapterIndex) ?? [:]
        let missingAtEnd = pending.filter { (settled[$0.index] ?? "").isEmpty }
        if missingAtEnd.isEmpty {
            // 本版抽段的章指纹落 sidecar,此后任何改版/规则变化在读取时立即判过期
            recordChapterFingerprint(bookTitle: bookTitle, chapterIndex: chapterIndex, paragraphs: paragraphs)
            enqueueChapterWrite(cleanTitle: sanitizeTitle(bookTitle), chapterIndex: chapterIndex)
        } else {
            NSLog("[双语] 批翻收尾不完整:共 %d 段,缺译 %d 段,不落章指纹待重翻",
                  pending.count, missingAtEnd.count)
        }
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
        for item in batch {
            let idx = item.index
            let raw = mapped[idx] ?? ""
            let sourceText = fullTextByIndex[idx] ?? ""
            var trans: String? = raw.isEmpty ? nil : raw
            // 回声假翻译闸:原文原样吐回/英文未翻视同缺译,先记账
            if let t = trans, Self.isEchoTranslation(source: sourceText, translated: t) {
                trans = nil
                NSLog("[双语] 段 %d 批翻输出为回声假翻译,改走兜底", idx)
            }
            if let trans {
                await saveAndPublish(
                    idx: idx, text: trans, srcText: sourceText,
                    total: total, bookTitle: bookTitle, chapterTitle: chapterTitle, chapterIndex: chapterIndex,
                    agent: agent, counter: counter, onParagraphTranslated: onParagraphTranslated
                )
            } else {
                // 缺段只记账,计数与 agent 重试/Embedded 兜底统一下面的第二轮执行——
                // 否则兜底路径会为同一段计数两次(批翻轮漏翻译一次 + 兜底轮一次),进度虚涨
                missing.append((index: idx, text: sourceText))
            }
        }
        if !missing.isEmpty {
            NSLog("[双语] 批翻缺 %d 段，开始逐段兜底：%d", missing.count,
                  missing.first?.index ?? -1)
        }

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
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 批次进行状态(段号在飞)

    /// 会话收尾:key+序号双重身份校验。同键晚到的 defer(排队等车道的旧会话)
    /// 若只按 key 比较,会误清新会话的进行状态——序号对不上则保持新会话不动
    @MainActor
    private func finishBatchSession(key: String, sessionId: Int) {
        guard activeBatchKey == key, activeSessionSerial == sessionId else { return }
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
