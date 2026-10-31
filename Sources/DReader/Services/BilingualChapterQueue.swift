//
//  BilingualChapterQueue.swift
//  DReader
//
//  章级双语队列:开双语/切章只自动翻**当前章**(用户口径,消除后台乱翻的混乱感);
//  「翻译全书」= 全量入队按辐射序推进(幂等,已译章由 isTranslated 过滤)。换书/关双语/
//  退书即 cancel。本章体验优先:队列只写缓存,不触碰渲染状态。
//

import Foundation

/// 反隔离:与 BookIndexService 同模式(状态小、单 Task 消费、调用方全是主线程 UI 动作),
/// 状态由一把 NSLock 保护。刻意不用 @Observable——锁临界区里的 submitted 写会同步触发
/// SwiftUI 重排并重入同一把锁造成死锁;弹窗接力状态行改由批翻进度的观察侧通道刷新。
final class BilingualChapterQueue: @unchecked Sendable {
    static let shared = BilingualChapterQueue()

    /// 排队模式:开双语/切章只排当前章;「翻译全书」其余未译章全量入队
    private enum Mode { case chapterOnly, fullBook }

    private var bookKey: String? = nil
    private var chapterCount: Int = 0
    private var activeChapterIndex: Int? = nil
    private var pendingQueue: [Int] = []
    private var mode: Mode = .chapterOnly
    /// 本队列已推进章数(面板显示)
    private var completedChaptersCount: Int = 0

    /// 注入缝(测试):「该章是否已译」与「翻一章」由宿主提供实现
    var isTranslated: (@Sendable (String, Int) -> Bool)? = nil
    var translateHandler: (@Sendable (String, Int) async -> Bool)? = nil

    private var loopTask: Task<Void, Never>?
    private var loopGeneration = 0
    /// 已入队未完成章节(防重复)
    private var scheduledKeys = Set<Int>()
    private let lock = NSLock()

    init() {}

    // MARK: - 可观察投影(锁内读)

    var isTranslating: Bool { lock.lock(); defer { lock.unlock() }; return activeChapterIndex != nil }
    var hasPendingWork: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeChapterIndex != nil || !pendingQueue.isEmpty
    }

    var queueDescription: String {
        lock.lock(); defer { lock.unlock() }
        guard let active = activeChapterIndex else {
            if mode == .chapterOnly || pendingQueue.isEmpty { return "" }
            return "待译 \(pendingQueue.count) 章"
        }
        if mode == .chapterOnly {
            return "正在翻译第 \(active + 1) 章"
        }
        return "第 \(active + 1)/\(chapterCount) 章 · 后台待译 \(pendingQueue.count) 章"
    }

    private(set) var activeIndex: Int? {
        get { lock.lock(); defer { lock.unlock() }; return activeChapterIndex }
        set { lock.lock(); activeChapterIndex = newValue; lock.unlock() }
    }

    // MARK: - 对外 API

    /// 开双语/重排入口:回到单章模式,只翻当前章(「翻译全书」另行 requestFullBook)
    func schedule(bookKey newBook: String, chapterCount: Int, fromIndex: Int) {
        lock.lock()
        if self.bookKey != newBook {
            cancelLocked(forKey: self.bookKey)
            if self.bookKey != newBook { completedChaptersCount = 0 }
        }
        self.bookKey = newBook
        self.chapterCount = max(chapterCount, 1)
        self.mode = .chapterOnly
        lock.unlock()
        reprioritize(fromIndex: fromIndex)
    }

    /// 切章:未译的新当前章插队。单章模式只排本章;全书模式仍按辐射序整列重排
    /// (已开始的章不打断,已译章过滤)
    func reprioritize(fromIndex index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let key = bookKey, chapterCount > 0 else { return }
        guard !(isTranslated?(key, index) ?? false) else { return }
        if mode == .fullBook {
            var order = Self.radiatingOrder(current: index, count: chapterCount)
                .filter { idx in !(isTranslated?(key, idx) ?? false) }
            // 去重;正在翻的章不重排队(等它跑完,后续摘取新序)
            var seen = Set<Int>()
            order = order.filter { seen.insert($0).inserted }
            if let active = activeChapterIndex {
                order.removeAll { $0 == active }
            }
            pendingQueue = order
            scheduledKeys = Set(order)
            if let active = activeChapterIndex {
                scheduledKeys.insert(active)
            }
        } else {
            // 单章模式:只排当前章;本章已在翻则什么都不做
            guard activeChapterIndex != index else { return }
            pendingQueue = [index]
            scheduledKeys = [index]
            if let active = activeChapterIndex {
                // 在翻的别章(全书遗留)保持不动,等它跑完再翻本章
                scheduledKeys.insert(active)
            }
        }
        ensureLoopRunningLocked()
    }

    /// 「翻译全书」:切全书模式,未译章全量重排(当前章已在队首,不打断现翻章)
    func requestFullBook(fromIndex index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let key = bookKey, chapterCount > 0 else { return }
        mode = .fullBook
        let order = (0..<chapterCount).filter { idx in
            idx != index && !scheduledKeys.contains(idx) && !(isTranslated?(key, idx) ?? false)
        }
        scheduledKeys.formUnion(order)
        pendingQueue += order
        ensureLoopRunningLocked()
    }

    /// 关双语/换书/退书。key 为 nil 表示无条件清;传值则只有同书才清。
    func cancel(forKey key: String?) {
        lock.lock()
        defer { lock.unlock() }
        cancelLocked(forKey: key)
    }

    private func cancelLocked(forKey key: String?) {
        guard key == nil || bookKey == key else { return }
        loopGeneration &+= 1
        loopTask?.cancel()
        loopTask = nil
        activeChapterIndex = nil
        pendingQueue = []
        scheduledKeys = []
        mode = .chapterOnly
        bookKey = nil
        chapterCount = 0
    }

    /// 辐射式章序:[cur, cur+1, cur-1, cur+2, cur-2 …](纯函数可单测)
    static func radiatingOrder(current: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var order: [Int] = []
        var offset = 0
        while (current + offset < count) || (current - offset >= 0) {
            let forward = current + offset
            if forward < count { order.append(forward) }
            let backward = current - offset
            if offset > 0 && backward >= 0 { order.append(backward) }
            offset += 1
        }
        return order
    }

    // MARK: - 主循环(锁内挑活,锁外执行)

    private func ensureLoopRunningLocked() {
        guard loopTask == nil else { return }
        let generation = loopGeneration
        loopTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    private func runLoop(generation: Int) async {
        while !Task.isCancelled {
            guard let (key, next) = takeNextLocked(gen: generation) else {
                clearLoopTaskLocked(gen: generation)
                return
            }
            let translated = await translateHandler?(key, next) ?? false
            if finishChapterLocked(gen: generation, key: key, index: next, translated: translated) == false {
                clearLoopTaskLocked(gen: generation)
                return
            }
        }
        // Task 被取消(cancel 已清 loopTask,generation 不符则 no-op)
        clearLoopTaskLocked(gen: generation)
    }

    /// 锁内清 loopTask(仅同代次),让后续 reprioritize 能再起新循环
    private func clearLoopTaskLocked(gen: Int) {
        lock.lock()
        if loopGeneration == gen { loopTask = nil }
        lock.unlock()
    }

    /// 锁内挑活:校验代次,摘队首并置 active;空队/换代返回 nil(循环退出)
    private func takeNextLocked(gen: Int) -> (key: String, index: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard loopGeneration == gen, bookKey != nil, let key = bookKey, let next = pendingQueue.first else {
            return nil
        }
        pendingQueue.removeFirst()
        scheduledKeys.remove(next)
        activeChapterIndex = next
        return (key, next)
    }

    /// 锁内落账:清 active;换代(取消/换书)返回 false 让循环退出
    private func finishChapterLocked(gen: Int, key: String, index: Int, translated: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        activeChapterIndex = nil
        guard loopGeneration == gen, bookKey == key else { return false }
        if translated { completedChaptersCount += 1 }
        return true
    }
}
