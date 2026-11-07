import Foundation

/// pi agent 服务 facade:替换 AIAgentService 的唯一 AI 后端。
///
/// 拓扑:4 条 lane,每条 = 一个长驻 `pi --mode rpc --no-session` 子进程
/// - `chat`(1):聊天问答(AIChatPanel / ReviewSessionModalView)
/// - `guide`(1):全书/章节导读生成
/// - `translate`(2):章级批翻(并发数 = BilingualTranslationService.batchConcurrency)
///
/// 为什么一条 lane 一个进程:pi 的 `abort` 是**进程级**命令、事件帧无请求 id,
/// 串行 lane 是「事件归属哪次请求」的归因前提;单进程下「停止翻译」必误杀聊天。
///
/// @Observable 面(供 SwiftUI 绑定)只留 UI 真正读的字段;进程与锁全部 @ObservationIgnored。
@Observable
final class PiAgentService: @unchecked Sendable {
    // MARK: - UI 观察面

    /// 连接状态(设置 sheet 与聊天面板状态行展示)
    var connectionStatus: ConnectionStatus = .untested

    enum ConnectionStatus: Equatable {
        case untested
        case checking
        case connected(String)
        case failed(String)
    }

    /// 聊天 lane 是否在生成(停止按钮 / 思考占位)
    var isGenerating: Bool = false

    /// 伴读思考角色(头像菜单选择;决定聊天 lane 的 system prompt)
    var role: AIAgentRole = .deepReader

    /// pi 可用模型清单(设置 sheet Picker;首次打开设置页时拉取)
    var availableModels: [PiRPCProtocol.ModelInfo] = []

    /// 当前模型("provider/modelID";chat lane 的 get_state 实测值)
    var currentModel: String = ""

    /// 模型清单是否在拉取中
    var isLoadingModels: Bool = false

    // MARK: - 非 UI 内部(@ObservationIgnored:锁内写不触发 SwiftUI 重入)

    /// 聊天/导读 lane 的 system prompt(替换 pi 默认 coding assistant prompt)
    static let chatSystemPrompt = """
    你是一位精通中外文学、哲学与社科历史的深度导读学者。你的目标是帮助读者深入理解书中文字的深层寓意、历史背景与哲学脉络。回答逻辑清晰、生动优美、充满见地,支持 Markdown 格式。
    """

    /// 翻译 lane 的 system prompt
    static let translationSystemPrompt = """
    你是一位兼备信达雅的文学翻译名家。按用户消息中的指令翻译文本,直接输出译文,禁止任何解释、引言、前后缀或 Markdown 围栏。
    """

    /// 聊天 lane 默认角色(与 chatSystemPrompt 对应)
    static let chatSystemPromptRole = AIAgentRole.deepReader

    @ObservationIgnored private var chatLane = PiChannel(laneID: "chat", systemPrompt: chatSystemPrompt)
    @ObservationIgnored private let guideLane = PiChannel(laneID: "guide", systemPrompt: chatSystemPrompt)
    @ObservationIgnored private var translateLanes: [PiChannel] = []
    @ObservationIgnored private let translateLaneLock = NSLock()
    @ObservationIgnored private var translateLaneCursor = 0

    @ObservationIgnored private var chatTask: Task<Void, Never>?
    @ObservationIgnored private let chatTaskLock = NSLock()

    /// pi 二进制是否可用(启动时探测一次)
    @ObservationIgnored private var binaryChecked = false

    static let shared = PiAgentService()

    init() {
        let count = max(1, BilingualTranslationService.batchConcurrency)
        translateLanes = (0..<count).map { PiChannel(laneID: "translate-\($0)", systemPrompt: Self.translationSystemPrompt) }
    }

    /// 测试注入缝构造(仿 RankingService.init(configuration:) 先例):
    /// 设置后 translateParagraphBatch 走假驱动,不碰 pi 子进程
    convenience init(
        testBatchDriverOverride: @escaping @Sendable ([(index: Int, text: String)]) async throws -> [Int: String]
    ) {
        self.init()
        self.testBatchDriverOverride = testBatchDriverOverride
    }

    // MARK: - 批翻驱动注入缝(等价 BatchTranslationTests 的 testBatchDriverOverride)

    /// 批翻测试注入:设置后 translateParagraphBatch 走假驱动,不碰 pi 子进程
    @ObservationIgnored var testBatchDriverOverride: (@Sendable ([(index: Int, text: String)]) async throws -> [Int: String])?

    // MARK: - 状态展示(替代 currentPreset.name 的展示文案)

    /// 伴读引擎展示名(设置面板 / 聊天状态行引用;带当前模型)
    var displayName: String {
        let base: String
        switch connectionStatus {
        case .connected(let detail): base = "pi agent(\(detail))"
        case .checking: base = "pi agent(连接中)"
        case .failed: base = "pi agent(未就绪)"
        case .untested: base = "pi agent"
        }
        guard !currentModel.isEmpty else { return base }
        return "\(base) · \(currentModel)"
    }

    /// 探测 pi 二进制并置状态(启动/设置页刷新时调用)
    func checkConnection() {
        if binaryChecked { return }
        binaryChecked = true
        connectionStatus = .checking
        if PiRPCConnection.locatePiBinary() != nil {
            connectionStatus = .connected("就绪")
        } else {
            connectionStatus = .failed("未找到 pi CLI,请安装:curl -fsSL https://pi.dev/install.sh | sh")
        }
    }

    // MARK: - 模型选择(get_available_models / set_model)

    /// 拉取 pi 可用模型清单 + 当前模型(设置 sheet onAppear / 重新检测时调用)
    func refreshModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        let lane = chatLane
        Task { [weak self] in
            guard let self else { return }
            var models: [PiRPCProtocol.ModelInfo] = []
            var current = ""
            do {
                models = try await lane.fetchAvailableModels()
            } catch {
                NSLog("[PiAgent] get_available_models 失败: %@", error.localizedDescription)
            }
            do {
                if let cur = try await lane.fetchCurrentModel() {
                    current = "\(cur.provider)/\(cur.modelID)"
                }
            } catch {
                NSLog("[PiAgent] get_state 失败: %@", error.localizedDescription)
            }
            await MainActor.run {
                self.availableModels = models
                self.currentModel = current
                self.isLoadingModels = false
            }
        }
    }

    /// 切换模型:全 lane 同步 set_model(chat/guide/translate 共用一份 pi 配置面)
    func selectModel(provider: String, modelID: String) {
        let full = "\(provider)/\(modelID)"
        guard currentModel != full else { return }
        currentModel = full // 乐观更新,失败由下次 refreshModels 校正
        let chat = chatLane
        let guide = guideLane
        translateLaneLock.lock()
        let lanes = translateLanes
        translateLaneLock.unlock()
        Task { [weak self] in
            var failures: [String] = []
            for lane in [chat, guide] + lanes {
                do {
                    try await lane.setModel(provider: provider, modelID: modelID)
                } catch {
                    failures.append(lane.laneID)
                    NSLog("[PiAgent] set_model lane %@ 失败: %@", lane.laneID, error.localizedDescription)
                }
            }
            if !failures.isEmpty {
                await MainActor.run {
                    NSLog("[PiAgent] set_model 部分失败 lane: %@", failures.joined(separator: ","))
                }
            }
        }
    }

    // MARK: - 聊天(AIChatPanel / ReviewSessionModalView 同签名)

    func sendMessage(
        history: [ChatMessage],
        bookTitle: String,
        author: String,
        chapterTitle: String,
        activeQuote: String?,
        userPrompt: String,
        onToken: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        stopGeneration()
        isGenerating = true

        // 角色切换 = 换聊天 lane 的 system prompt(pi 的 system 在进程启动时注入;
        // 角色变了就重建 lane,下次 prompt 生效)
        let rolePrompt = role.systemPrompt
        if role != Self.chatSystemPromptRole {
            let lane = chatLane
            Task { await lane.updateSystemPrompt(rolePrompt) }
        }

        // 阅读语境拼进 user prompt(system prompt 由 lane 启动参数固定;
        // pi 的 prompt 命令不支持每请求换 system)
        let contextPrefixed = """
        【当前阅读语境】
        书籍:《\(bookTitle)》
        作者:\(author)
        章节:\(chapterTitle)
        \(activeQuote.flatMap { "【选中的重点段落】:\n『\($0)』\n" } ?? "")

        \(userPrompt)
        """

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var accumulated = ""
                let stream = try await self.chatLane.prompt(contextPrefixed)
                for await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case let .textDelta(delta):
                        accumulated += delta
                        await onToken(delta)
                    case let .messageEnd(completion):
                        guard let completion else { break }
                        // 权威文本:增量缺失/撕裂时以 message_end 为准
                        if !completion.text.isEmpty, completion.text != accumulated {
                            let missing = completion.text.count > accumulated.count
                                ? String(completion.text.dropFirst(accumulated.count)) : ""
                            if !missing.isEmpty { await onToken(missing) }
                            accumulated = completion.text
                        }
                        if let errorDetail = completion.errorMessage {
                            throw PiAgentError.commandFailed(command: "prompt", detail: errorDetail)
                        }
                    case let .agentError(detail):
                        throw PiAgentError.commandFailed(command: "prompt", detail: detail)
                    default:
                        break
                    }
                }
                let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                await MainActor.run {
                    self.isGenerating = false
                    if final.isEmpty {
                        onError("未收到 pi 的有效回答,请检查 pi 配置与模型")
                    } else {
                        onComplete()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    if !Task.isCancelled {
                        onError(error.localizedDescription)
                    }
                }
            }
        }
        chatTaskLock.lock()
        chatTask = task
        chatTaskLock.unlock()
    }

    /// 停止聊天 lane(pi abort 是进程级;lane 串行下即「当前这次」)
    func stopGeneration() {
        chatTaskLock.lock()
        let task = chatTask
        chatTask = nil
        chatTaskLock.unlock()
        task?.cancel()
        let lane = chatLane
        Task { await lane.abort() }
        isGenerating = false
    }

    /// 停止全部翻译 lane(聊天/导读 lane 不受影响)
    func stopBatchTranslation() {
        translateLaneLock.lock()
        let lanes = translateLanes
        translateLaneLock.unlock()
        for lane in lanes {
            Task { await lane.abort() }
        }
    }

    // MARK: - 章级批翻(签名与 AIAgentService 一致)

    /// 单请求源文字符预算(单次 LLM 输出 5k 上下的中文字符是稳妥区间)
    static let batchCharBudget = 4800
    /// 单包段数上限
    static let batchMaxParagraphs = 60
    /// 孤段独占包的尺寸硬顶,超出按句边界再拆
    static let batchHardSegmentLimit = 12_000

    /// 输入切块:顺序累积,达预算/段数上限即切包;空段滤除;
    /// 超巨段按句边界拆成多包(同编号多子块,译文合并由调度层负责)。
    static func planChapterBatches(
        _ paragraphs: [(index: Int, text: String)],
        charBudget: Int = PiAgentService.batchCharBudget
    ) -> [[(index: Int, text: String)]] {
        var batches: [[(index: Int, text: String)]] = []
        var current: [(index: Int, text: String)] = []
        var chars = 0

        func flush() {
            guard !current.isEmpty else { return }
            batches.append(current)
            current = []
            chars = 0
        }

        for (idx, raw) in paragraphs {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.count > Self.batchHardSegmentLimit {
                flush()
                // 超巨段:按句边界拆块后「同编号多行进同一包」,一次批翻由 agent 按行拼接
                // (跨包会导致逐包各自落盘互相覆盖,译文只剩末块)
                var mega: [(index: Int, text: String)] = []
                for part in Self.splitLongParagraph(text, limit: Self.batchHardSegmentLimit) {
                    mega.append((index: idx, text: part))
                }
                batches.append(mega)
                continue
            }
            if chars + text.count > charBudget || current.count >= Self.batchMaxParagraphs {
                flush()
            }
            current.append((index: idx, text: text))
            chars += text.count
        }
        flush()
        return batches
    }

    /// 超长段按句边界(。!?…;换行)拆为若干 ≤ limit 的子块(末尾允许超限单句)
    static func splitLongParagraph(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "。" || ch == "!" || ch == "?" || ch == "\n"
                || ch == ";" || ch == "…" || ch == "!" || ch == "?" {
                let next = text.index(after: i)
                sentences.append(String(text[start..<next]))
                start = next
            }
            i = text.index(after: i)
        }
        if start < text.endIndex {
            sentences.append(String(text[start...]))
        }
        guard !sentences.isEmpty else { return [text] }

        var parts: [String] = []
        var buffer = ""
        for sentence in sentences {
            if !buffer.isEmpty, buffer.count + sentence.count > limit {
                parts.append(buffer)
                buffer = sentence
            } else {
                buffer += sentence
            }
        }
        if !buffer.isEmpty { parts.append(buffer) }
        return parts
    }

    static func batchSystemPrompt(bookTitle: String, chapterTitle: String) -> String {
        """
        你是一位信达雅兼备的文学翻译名家。本次任务:把一本书中某一章的若干编号段落批量译成地道、典雅的现代中文。
        硬性输出要求:
        1. 只输出一个 JSON 对象,禁止任何解释、前后缀或 Markdown 代码围栏。
        2. 格式:{"items":[{"i":<段落编号>,"t":"<该段完整中文译文>"}]}
        3. 输入中的每一个编号都必须返回,编号一一对应、不得增删;同一编号若分行出现,译出各部分后按行序拼成同一段完整译文,只返回一个该编号条目;译文为纯正文自带标点,不得再包编号或引号。
        4. 译文与全书上下文连贯,人名、地名译法前后一致;对话、诗行的分行形态沿用原文。
        【书籍】《\(bookTitle)》 【章节】\(chapterTitle)
        """
    }

    /// user prompt:每段一行 `[N] 原文`;段内换行折成空格,防止行首数字被当编号
    static func batchUserPrompt(_ items: [(index: Int, text: String)]) -> String {
        let lines = items.map { item -> String in
            let normalized = item.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(item.index)] \(normalized)"
        }
        return "将下列 \(items.count) 个编号段落译成中文,编号原样映射,只输出 JSON:\n" + lines.joined(separator: "\n")
    }

    /// 宽容解析批翻输出:
    /// 1) 去代码围栏;2) 扫首个平衡大括号对象;3) JSONSerialization 兼容三种形态:
    ///    {"items":[{i,t}]}(键名别名免疫)/ 顶层 {编号: 译文} map / 顶层数组;
    /// 4) 仅保留 validIndices 内、非空字符串的条目。
    static func parseBatchResponse(_ raw: String, validIndices: Set<Int>) -> [Int: String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = Self.firstJSONValueData(in: s),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return [:] }

        var result: [Int: String] = [:]
        if let dict = obj as? [String: Any] {
            for key in ["items", "translations", "data", "results", "paragraphs"] {
                guard let rows = dict[key] as? [[String: Any]] else { continue }
                for row in rows { Self.feedRow(row, into: &result, validIndices: validIndices) }
                break
            }
            if result.isEmpty {
                for (k, v) in dict {
                    guard let idx = Int(k), let text = v as? String, !text.isEmpty else { continue }
                    Self.feed(idx: idx, text: text, into: &result, validIndices: validIndices)
                }
            }
        } else if let rows = obj as? [[String: Any]] {
            for row in rows { Self.feedRow(row, into: &result, validIndices: validIndices) }
        }
        return result
    }

    private static func feedRow(
        _ row: [String: Any], into result: inout [Int: String], validIndices: Set<Int>
    ) {
        let indexedPairs = row.filter { ["i", "index", "id", "n", "num"].contains($0.key) }
        let textPairs = row.filter { ["t", "text", "translation", "trans", "zh", "c"].contains($0.key) }
        guard !indexedPairs.isEmpty, let textPair = textPairs.first else { return }
        guard let idx = Self.toInt(indexedPairs.first!.value) else { return }
        Self.feed(idx: idx, text: textPair.value, into: &result, validIndices: validIndices)
    }

    private static func feed(
        idx: Int, text: Any, into result: inout [Int: String], validIndices: Set<Int>
    ) {
        guard let str = text as? String else { return }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, validIndices.contains(idx) else { return }
        // 超巨段拆块后同一编号多条目:按行序拼接成整段译文
        result[idx] = (result[idx].map { $0 + trimmed }) ?? trimmed
    }

    private static func toInt(_ value: Any) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as Double: return Int(n)
        case let n as String: return Int(n)
        default: return nil
        }
    }

    /// 从脏输出中扫取首个完整平衡的 `{...}` 或 `[...]` JSON 值(字符串内转义/括号不误计)
    private static func firstJSONValueData(in raw: String) -> Data? {
        guard let startIdx = raw.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opening = raw[startIdx]
        let closing: Character = opening == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        var i = startIdx
        while i < raw.endIndex {
            let ch = raw[i]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == opening {
                depth += 1
            } else if ch == closing {
                depth -= 1
                if depth == 0 {
                    return String(raw[startIdx...i]).data(using: .utf8)
                }
            }
            i = raw.index(after: i)
        }
        return nil
    }

    /// 章级批翻:一次 agent 调用返回整包译文 map(缺编号由调度层兜底)。
    /// 并发包轮转分配到 translate lane 池(每 lane 串行,包间并发)。
    func translateParagraphBatch(
        items: [(index: Int, text: String)],
        bookTitle: String,
        chapterTitle: String
    ) async throws -> [Int: String] {
        if let override = testBatchDriverOverride {
            return try await override(items)
        }
        guard !items.isEmpty else { return [:] }
        let system = Self.batchSystemPrompt(bookTitle: bookTitle, chapterTitle: chapterTitle)
        let user = Self.batchUserPrompt(items)
        let startedAt = Date().timeIntervalSince1970
        let raw = try await runDriverCollect(systemPrompt: system, userPrompt: user)
        let parsed = Self.parseBatchResponse(raw, validIndices: Set(items.map(\.index)))
        NSLog("[双语] 驱动输出 %d 字 → 解析命中 %d/%d 段(%.1fs,驱动=pi)",
              raw.count, parsed.count, items.count,
              Date().timeIntervalSince1970 - startedAt)
        if parsed.count < items.count {
            let head = raw.prefix(260).replacingOccurrences(of: "\n", with: "⏎")
            let tail = raw.suffix(120).replacingOccurrences(of: "\n", with: "⏎")
            NSLog("[双语] 批翻输出样例(首%d字):%@", head.count, head)
            NSLog("[双语] 批翻输出样例(尾%d字):%@", tail.count, tail)
        }
        return parsed
    }

    /// 单段直译(签名与 AIAgentService.translate 一致;走轮转 translate lane)
    func translate(
        text: String,
        bookTitle: String,
        chapterTitle: String
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 驱动级注入缝:批翻/单段直译同走假驱动(测试不拉真子进程)
        if let override = testBatchDriverOverride {
            let mapped = try await override([(index: 0, text: trimmed)])
            guard let translation = mapped[0], !translation.isEmpty else {
                throw BatchTranslationError.emptyResponse
            }
            return translation
        }

        let systemContext = """
        你是一位兼备信达雅的文学翻译名家。
        【任务要求】
        请将书籍段落翻译为地道、典雅、符合原著语境的中文。
        要求原汁原味,措辞优美,符合现代文学名著名译标准。
        严禁输出任何多余的引言、解释、前后缀或 Markdown 标题,直接输出纯中文译文即可。

        【书本信息】
        书籍:《\(bookTitle)》
        章节:\(chapterTitle)
        """
        return try await runDriverCollect(systemPrompt: systemContext, userPrompt: trimmed)
    }

    /// 一次 agent 调用收集完整输出(批翻/直译共用;轮转占用 translate lane)
    private func runDriverCollect(systemPrompt: String, userPrompt: String) async throws -> String {
        let lane = nextTranslateLane()
        var collected = ""
        let stream = try await lane.promptWithSystem(systemPrompt, userPrompt: userPrompt)
        for await event in stream {
            switch event {
            case let .textDelta(delta):
                collected += delta
            case let .messageEnd(completion):
                guard let completion else { break }
                if completion.text.count > collected.count {
                    collected = completion.text
                }
                if let errorDetail = completion.errorMessage {
                    throw PiAgentError.commandFailed(command: "prompt", detail: errorDetail)
                }
            case let .agentError(detail):
                throw PiAgentError.commandFailed(command: "prompt", detail: detail)
            default:
                break
            }
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BatchTranslationError.emptyResponse }
        return trimmed
    }

    /// translate lane 轮转(每 lane 串行;并发包数 ≤ lane 数时天然隔离)
    private func nextTranslateLane() -> PiChannel {
        translateLaneLock.lock()
        defer { translateLaneLock.unlock() }
        let lane = translateLanes[translateLaneCursor % max(translateLanes.count, 1)]
        translateLaneCursor &+= 1
        return lane
    }

    enum BatchTranslationError: LocalizedError {
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "批翻译调用未返回内容"
            }
        }
    }

    // MARK: - 导读(guide lane;BookGuide 生成走这里)

    /// 单轮导读生成:收集完整输出(不流式;导读是一次性长文)
    func collectGuide(prompt: String) async throws -> String {
        let stream = try await guideLane.prompt(prompt)
        var collected = ""
        for await event in stream {
            switch event {
            case let .textDelta(delta):
                collected += delta
            case let .messageEnd(completion):
                guard let completion else { break }
                if completion.text.count > collected.count {
                    collected = completion.text
                }
                if let errorDetail = completion.errorMessage {
                    throw PiAgentError.commandFailed(command: "prompt", detail: errorDetail)
                }
            case let .agentError(detail):
                throw PiAgentError.commandFailed(command: "prompt", detail: detail)
            default:
                break
            }
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PiAgentError.emptyResponse(laneID: "guide") }
        return trimmed
    }

    // MARK: - 生命周期

    /// 退出全部 lane 子进程(App 退出时调用)
    func terminateAll() {
        let chat = chatLane
        let guide = guideLane
        translateLaneLock.lock()
        let lanes = translateLanes
        translateLaneLock.unlock()
        Task {
            await chat.terminate()
            await guide.terminate()
            for lane in lanes {
                await lane.terminate()
            }
        }
    }
}
