import Foundation

/// Manages dual-language interlinear paragraph translations and persistent disk caching
@Observable
final class BilingualTranslationService: @unchecked Sendable {
    static let shared = BilingualTranslationService()

    // In-memory cache: [bookTitle: [chapterIndex: [paragraphIndex: Chinese translation]]]
    private var memoryCache: [String: [Int: [Int: String]]] = [:]
    private let cacheDirectory: URL
    private let lock = NSLock()

    var isTranslatingChapter: Bool = false
    var currentProgressRatio: Double = 0.0 // 0.0 to 1.0

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

        // Persist to disk asynchronously
        guard let chapterDict = memoryCache[cleanTitle]?[chapterIndex] else { return }
        let stringKeyedDict = chapterDict.reduce(into: [String: String]()) { acc, pair in
            acc["\(pair.key)"] = pair.value
        }

        Task.detached(priority: .background) { [cacheDir = self.cacheDirectory] in
            if let data = try? JSONEncoder().encode(stringKeyedDict) {
                let fileURL = cacheDir.appendingPathComponent("\(cleanTitle)_ch\(chapterIndex).json")
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    // MARK: - Translate Single Paragraph with Active Agent

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
        isCancelled: (@MainActor @Sendable () -> Bool)? = nil
    ) async {
        guard !paragraphs.isEmpty else { return }

        await MainActor.run {
            self.isTranslatingChapter = true
            self.currentProgressRatio = 0.0
        }
        defer {
            Task { @MainActor in
                self.isTranslatingChapter = false
                self.currentProgressRatio = 1.0
            }
        }

        let cached = getCachedTranslations(bookTitle: bookTitle, chapterIndex: chapterIndex) ?? [:]
        let pending = paragraphs.filter { item in
            item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && cached[item.index] == nil
        }
        guard !pending.isEmpty else {
            await MainActor.run { self.currentProgressRatio = 1.0 }
            return
        }

        let total = Double(pending.count)
        // 超巨段按句边界拆块后同编号多行进同一包；批翻缺编号时逐段兜底要用整段原文
        let fullTextByIndex = Dictionary(pending.map { ($0.index, $0.text) }, uniquingKeysWith: { a, _ in a })
        let batches = AIAgentService.planChapterBatches(pending)
        let semaphore = AsyncSemaphore(permits: Self.batchConcurrency)
        let counter = ProgressCounter()
        let bookTitle = bookTitle
        let chapterTitle = chapterTitle
        let agent = agentService
        let service = self
        let cancelled: (@MainActor @Sendable () -> Bool)? = isCancelled

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
                        isCancelled: cancelled
                    )
                }
            }
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
        isCancelled: (@MainActor @Sendable () -> Bool)?
    ) async {
        var mapped: [Int: String] = [:]
        for attempt in 0..<2 {
            if let cancelledFn = isCancelled, await cancelledFn() { return }
            do {
                mapped = try await agent.translateParagraphBatch(
                    items: batch,
                    bookTitle: bookTitle,
                    chapterTitle: chapterTitle
                )
                break
            } catch {
                mapped = [:]
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }

        if let cancelledFn = isCancelled, await cancelledFn() { return }

        var missing: [(index: Int, text: String)] = []
        for (idx, _) in batch {
            let trans = mapped[idx] ?? ""
            await saveAndPublish(
                idx: idx, text: trans.isEmpty ? nil : trans, srcText: fullTextByIndex[idx] ?? "",
                total: total, bookTitle: bookTitle, chapterTitle: chapterTitle, chapterIndex: chapterIndex,
                agent: agent, counter: counter, onParagraphTranslated: onParagraphTranslated
            )
            if trans.isEmpty {
                missing.append((index: idx, text: fullTextByIndex[idx] ?? ""))
            }
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
