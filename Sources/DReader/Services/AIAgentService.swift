import Foundation

@Observable
final class AIAgentService: @unchecked Sendable {
    var currentPreset: ACPAgentPreset = ACPAgentPreset.allPresets.first! // Default Grok
    var customCommand: String = "grok agent stdio"
    var role: AIAgentRole = .deepReader
    var selectedModel: String = "Grok"
    var isGenerating: Bool = false
    var connectionStatus: ConnectionStatus = .untested

    enum ConnectionStatus: Equatable {
        case untested
        case checking
        case connected(String)
        case failed(String)
    }

    private var activeTask: Task<Void, Never>?
    /// 进程分槽:聊天(单槽,受停止按钮控制)与翻译(批翻并发多进程)分账登记,
    /// 否则并发批翻互相覆写 activeProcess、还会被 AI 伴读聊天的 stopGeneration 误杀。
    private var chatProcess: Process?
    private let translationProcessLock = NSLock()
    private var translationProcesses: [ObjectIdentifier: Process] = [:]

    /// 进程用途:聊天 / 翻译(分槽停止与登记用)
    enum ProcessRole {
        case chat
        case translation
    }

    // MARK: - Environment & Binary Lookup
    static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let customPaths = [
            "\(home)/.kimi-code/bin",
            "\(home)/.grok/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.cargo/bin"
        ]
        let currentPath = env["PATH"] ?? ""
        let combined = (customPaths + [currentPath]).filter { !$0.isEmpty }.joined(separator: ":")
        env["PATH"] = combined
        env["HOME"] = home
        return env
    }

    static func findBinaryPath(name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let env = buildEnvironment()
        let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in paths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func selectPreset(_ preset: ACPAgentPreset) {
        self.currentPreset = preset
        self.customCommand = preset.command
        self.selectedModel = preset.name

        switch preset.driverType {
        case .embedded:
            self.connectionStatus = .connected("内置伴读引擎已就绪")
        case .acpStdio, .cliStreaming:
            self.connectionStatus = .checking
            checkLocalBinary(preset: preset)
        case .httpAdapter:
            self.connectionStatus = .checking
            if preset.id == "ollama" {
                checkOllamaConnection(endpoint: preset.command)
            } else {
                checkOpenAIConnection(endpoint: preset.command)
            }
        }
    }

    // MARK: - Health Checks
    private func checkLocalBinary(preset: ACPAgentPreset) {
        let binName = preset.defaultBin.isEmpty ? (preset.command.components(separatedBy: " ").first ?? "") : preset.defaultBin
        if let path = Self.findBinaryPath(name: binName) {
            self.connectionStatus = .connected("已就绪: \(path)")
        } else {
            self.connectionStatus = .failed("未在系统中探测到 `\(binName)`，请检查安装")
        }
    }

    private func checkOllamaConnection(endpoint: String) {
        guard let url = URL(string: "\(endpoint)/api/tags") else { return }
        Task {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 2.0
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    struct OllamaTags: Decodable {
                        struct Item: Decodable { let name: String }
                        let models: [Item]?
                    }
                    let res = try JSONDecoder().decode(OllamaTags.self, from: data)
                    let names = res.models?.map(\.name) ?? []
                    await MainActor.run {
                        self.selectedModel = names.first ?? "llama3.2"
                        self.connectionStatus = .connected("已连接 Ollama (\(names.count)个模型)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.connectionStatus = .failed("未连接到 Ollama 服务 (11434 端口未开放)")
                }
            }
        }
    }

    private func checkOpenAIConnection(endpoint: String) {
        guard let url = URL(string: "\(endpoint)/models") else { return }
        Task {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 2.0
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    await MainActor.run {
                        self.connectionStatus = .connected("已连接本地 OpenAI API 端口")
                    }
                }
            } catch {
                await MainActor.run {
                    self.connectionStatus = .failed("未探测到本地 API 服务 (端口未开放)")
                }
            }
        }
    }

    // MARK: - Send Message
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

        let systemContext = """
        \(role.systemPrompt)

        【当前阅读语境】
        书籍：《\(bookTitle)》
        作者：\(author)
        章节：\(chapterTitle)
        \(activeQuote.flatMap { "【选中的重点段落】：\n『\($0)』\n" } ?? "")

        请依据书籍语境与选中段落，用清晰优雅、条理分明的方式回答读者。支持 Markdown 格式。
        """

        activeTask = Task {
            do {
                switch currentPreset.driverType {
                case .acpStdio:
                    try await runACPStdio(
                        command: customCommand,
                        systemPrompt: systemContext,
                        userPrompt: userPrompt,
                        activeQuote: activeQuote,
                        onToken: onToken
                    )

                case .cliStreaming:
                    try await runCLIStreaming(
                        command: customCommand,
                        systemPrompt: systemContext,
                        userPrompt: userPrompt,
                        activeQuote: activeQuote,
                        onToken: onToken
                    )

                case .httpAdapter:
                    if currentPreset.id == "ollama" {
                        try await runOllamaAdapter(
                            endpoint: customCommand,
                            model: selectedModel,
                            systemPrompt: systemContext,
                            history: history,
                            userPrompt: userPrompt,
                            onToken: onToken
                        )
                    } else {
                        try await runOpenAIAdapter(
                            endpoint: customCommand,
                            model: selectedModel,
                            systemPrompt: systemContext,
                            history: history,
                            userPrompt: userPrompt,
                            onToken: onToken
                        )
                    }

                case .embedded:
                    try await runEmbeddedEngine(
                        role: role,
                        bookTitle: bookTitle,
                        chapterTitle: chapterTitle,
                        activeQuote: activeQuote,
                        userPrompt: userPrompt,
                        onToken: onToken
                    )
                }

                await MainActor.run {
                    self.isGenerating = false
                    onComplete()
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.isGenerating = false
                        onError(error.localizedDescription)
                    }
                }
            }
        }
    }

    func stopGeneration() {
        activeTask?.cancel()
        activeTask = nil

        if let proc = chatProcess, proc.isRunning {
            proc.terminate()
        }
        chatProcess = nil
        isGenerating = false
    }

    /// 批次翻译停止开关:终止所有在跑的翻译进程(聊天槽不受影响)
    func stopBatchTranslation() {
        translationProcessLock.lock()
        let procs = Array(translationProcesses.values)
        translationProcesses.removeAll()
        translationProcessLock.unlock()
        for proc in procs where proc.isRunning {
            proc.terminate()
        }
    }

    private func registerTranslationProcess(_ process: Process) {
        translationProcessLock.lock()
        translationProcesses[ObjectIdentifier(process)] = process
        translationProcessLock.unlock()
    }

    private func unregisterTranslationProcess(_ process: Process) {
        translationProcessLock.lock()
        translationProcesses.removeValue(forKey: ObjectIdentifier(process))
        translationProcessLock.unlock()
    }

    // MARK: - 章级批翻（整章上下文打包；协议纯函数均可单测）

    enum BatchTranslationError: LocalizedError {
        case unsupportedDriver
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .unsupportedDriver: return "当前伴读引擎不支持章级批翻，将退化为逐段翻译"
            case .emptyResponse: return "批翻译调用未返回内容"
            }
        }
    }

    /// 章级批翻测试注入缝（不设时按真实驱动跑；仿 RankingService.init(configuration:) 先例）
    let testBatchDriverOverride: (@Sendable ([(index: Int, text: String)]) async throws -> [Int: String])?

    init(testBatchDriverOverride: (@Sendable ([(index: Int, text: String)]) async throws -> [Int: String])? = nil) {
        self.testBatchDriverOverride = testBatchDriverOverride
        selectPreset(currentPreset)
    }

    /// 单请求源文字符预算（单次 LLM 输出 5k 上下的中文字符是稳妥区间）
    static let batchCharBudget = 4800
    /// 单包段数上限
    static let batchMaxParagraphs = 60
    /// 孤段独占包的尺寸硬顶，超出按句边界再拆
    static let batchHardSegmentLimit = 12_000

    /// 输入切块：顺序累积，达预算/段数上限即切包；空段滤除；
    /// 超巨段按句边界拆成多包（同编号多子块，译文合并由调度层负责）。
    static func planChapterBatches(
        _ paragraphs: [(index: Int, text: String)],
        charBudget: Int = AIAgentService.batchCharBudget
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

    /// 超长段按句边界（。！?…；换行）拆为若干 ≤ limit 的子块（末尾允许超限单句）
    static func splitLongParagraph(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "。" || ch == "!" || ch == "?" || ch == "\n"
                || ch == "；" || ch == "…" || ch == "!" || ch == "?" {
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
        你是一位信达雅兼备的文学翻译名家。本次任务：把一本书中某一章的若干编号段落批量译成地道、典雅的现代中文。
        硬性输出要求：
        1. 只输出一个 JSON 对象，禁止任何解释、前后缀或 Markdown 代码围栏。
        2. 格式：{"items":[{"i":<段落编号>,"t":"<该段完整中文译文>"}]}
        3. 输入中的每一个编号都必须返回,编号一一对应、不得增删;同一编号若分行出现,译出各部分后按行序拼成同一段完整译文,只返回一个该编号条目;译文为纯正文自带标点,不得再包编号或引号。
        4. 译文与全书上下文连贯，人名、地名译法前后一致；对话、诗行的分行形态沿用原文。
        【书籍】《\(bookTitle)》　【章节】\(chapterTitle)
        """
    }

    /// user prompt：每段一行 `[N] 原文`；段内换行折成空格，防止行首数字被当编号
    static func batchUserPrompt(_ items: [(index: Int, text: String)]) -> String {
        let lines = items.map { item -> String in
            let normalized = item.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(item.index)] \(normalized)"
        }
        return "将下列 \(items.count) 个编号段落译成中文，编号原样映射，只输出 JSON：\n" + lines.joined(separator: "\n")
    }

    /// 宽容解析批翻输出：
    /// 1) 去代码围栏；2) 扫首个平衡大括号对象；3) JSONSerialization 兼容三种形态：
    ///    {"items":[{i,t}]}（键名别名免疫）/ 顶层 {编号: 译文} map / 顶层数组；
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

    /// 章级批翻：一次 agent 调用返回整包译文 map（缺编号由调度层兜底）。
    func translateParagraphBatch(
        items: [(index: Int, text: String)],
        bookTitle: String,
        chapterTitle: String
    ) async throws -> [Int: String] {
        if let override = testBatchDriverOverride {
            return try await override(items)
        }
        guard currentPreset.driverType != .embedded else {
            throw BatchTranslationError.unsupportedDriver
        }
        guard !items.isEmpty else { return [:] }
        let system = Self.batchSystemPrompt(bookTitle: bookTitle, chapterTitle: chapterTitle)
        let user = Self.batchUserPrompt(items)
        let raw = try await runDriverCollect(systemPrompt: system, userPrompt: user)
        return Self.parseBatchResponse(raw, validIndices: Set(items.map(\.index)))
    }

    /// 一次 agent 调用收集完整输出（批翻路径，进程登记走 translation 槽）
    private func runDriverCollect(systemPrompt: String, userPrompt: String) async throws -> String {
        var collected = ""
        switch currentPreset.driverType {
        case .acpStdio:
            try await runACPStdio(
                command: customCommand, systemPrompt: systemPrompt, userPrompt: userPrompt,
                activeQuote: nil, onToken: { collected += $0 }, processRole: .translation
            )
        case .cliStreaming:
            try await runCLIStreaming(
                command: customCommand, systemPrompt: systemPrompt, userPrompt: userPrompt,
                activeQuote: nil, onToken: { collected += $0 }, processRole: .translation
            )
        case .httpAdapter:
            if currentPreset.id == "ollama" {
                try await runOllamaAdapter(
                    endpoint: customCommand, model: selectedModel,
                    systemPrompt: systemPrompt, history: [], userPrompt: userPrompt,
                    onToken: { collected += $0 }
                )
            } else {
                try await runOpenAIAdapter(
                    endpoint: customCommand, model: selectedModel,
                    systemPrompt: systemPrompt, history: [], userPrompt: userPrompt,
                    onToken: { collected += $0 }
                )
            }
        case .embedded:
            throw BatchTranslationError.unsupportedDriver
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BatchTranslationError.emptyResponse }
        return trimmed
    }

    // MARK: - Direct Literary Translation with Active Agent
    func translate(
        text: String,
        bookTitle: String,
        chapterTitle: String
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if currentPreset.driverType == .embedded {
            return EmbeddedTranslationEngine.shared.translate(text: trimmed, bookTitle: bookTitle)
        }

        let systemContext = """
        你是一位兼备信达雅的文学翻译名家。
        【任务要求】
        请将书籍段落翻译为地道、典雅、符合原著语境的中文。
        要求原汁原味，措辞优美，符合现代文学名著名译标准。
        严禁输出任何多余的引言、解释、前后缀或 Markdown 标题，直接输出纯中文译文即可。

        【书本信息】
        书籍：《\(bookTitle)》
        章节：\(chapterTitle)
        """

        var collectedResult = ""
        do {
            switch currentPreset.driverType {
            case .acpStdio:
                try await runACPStdio(
                    command: customCommand,
                    systemPrompt: systemContext,
                    userPrompt: trimmed,
                    activeQuote: nil,
                    onToken: { token in
                        collectedResult += token
                    },
                    processRole: .translation
                )

            case .cliStreaming:
                try await runCLIStreaming(
                    command: customCommand,
                    systemPrompt: systemContext,
                    userPrompt: trimmed,
                    activeQuote: nil,
                    onToken: { token in
                        collectedResult += token
                    },
                    processRole: .translation
                )

            case .httpAdapter:
                if currentPreset.id == "ollama" {
                    try await runOllamaAdapter(
                        endpoint: customCommand,
                        model: selectedModel,
                        systemPrompt: systemContext,
                        history: [],
                        userPrompt: trimmed,
                        onToken: { token in
                            collectedResult += token
                        }
                    )
                } else {
                    try await runOpenAIAdapter(
                        endpoint: customCommand,
                        model: selectedModel,
                        systemPrompt: systemContext,
                        history: [],
                        userPrompt: trimmed,
                        onToken: { token in
                            collectedResult += token
                        }
                    )
                }

            case .embedded:
                return EmbeddedTranslationEngine.shared.translate(text: trimmed, bookTitle: bookTitle)
            }

            let finalStr = collectedResult.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalStr.isEmpty {
                return finalStr
            }
        } catch {
            return EmbeddedTranslationEngine.shared.translate(text: trimmed, bookTitle: bookTitle)
        }

        return EmbeddedTranslationEngine.shared.translate(text: trimmed, bookTitle: bookTitle)
    }

    // MARK: - Driver 1: ACP Stdio Process Runner (Grok, Kimi, Devin)
    private func runACPStdio(
        command: String,
        systemPrompt: String,
        userPrompt: String,
        activeQuote: String?,
        onToken: @escaping @MainActor (String) -> Void,
        processRole: ProcessRole = .chat
    ) async throws {
        let parts = command.components(separatedBy: " ").filter { !$0.isEmpty }
        guard let binName = parts.first else {
            throw NSError(domain: "ACPError", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的 ACP 命令"])
        }

        guard let resolvedBin = Self.findBinaryPath(name: binName) else {
            throw NSError(domain: "ACPError", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到可执行文件 `\(binName)`。请确认已安装或在设置中配置正确路径。"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedBin)
        process.arguments = Array(parts.dropFirst())
        process.environment = Self.buildEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        switch processRole {
        case .chat:
            self.chatProcess = process
        case .translation:
            self.registerTranslationProcess(process)
            defer { self.unregisterTranslationProcess(process) }
        }

        try process.run()

        let inHandle = inPipe.fileHandleForWriting

        // Helper to send JSON-RPC line
        func sendJSON(_ dict: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: dict)
            inHandle.write(data)
            inHandle.write("\n".data(using: .utf8)!)
        }

        // 1. Send initialize
        try sendJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientInfo": [
                    "name": "DReader",
                    "version": "1.0.0"
                ]
            ]
        ])

        // 2. Send session/new
        let cwd = FileManager.default.currentDirectoryPath
        try sendJSON([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "session/new",
            "params": [
                "cwd": cwd,
                "mcpServers": []
            ]
        ])

        var receivedTokens = false
        let fullUserPrompt = "\(systemPrompt)\n\n【读者问题】：\(userPrompt)"

        let fileHandle = outPipe.fileHandleForReading
        for try await line in fileHandle.bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }

            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // 1. Detect session/new response (id: 2)
            if let id = json["id"] as? Int, id == 2,
               let result = json["result"] as? [String: Any],
               let sid = result["sessionId"] as? String {
                // Send prompt (id: 3)
                try sendJSON([
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "session/prompt",
                    "params": [
                        "sessionId": sid,
                        "prompt": [
                            ["type": "text", "text": fullUserPrompt]
                        ]
                    ]
                ])
            }

            // 2. Detect streaming tokens (session/update)
            if let method = json["method"] as? String, method == "session/update",
               let params = json["params"] as? [String: Any] {

                let update = (params["update"] as? [String: Any]) ?? params
                let sessionUpdate = update["sessionUpdate"] as? String ?? ""

                // Extract token text
                var tokenText: String?
                if let content = update["content"] as? [String: Any] {
                    tokenText = content["text"] as? String
                } else if let contentArray = update["content"] as? [[String: Any]] {
                    tokenText = contentArray.compactMap { $0["text"] as? String }.joined()
                } else if let contentStr = update["content"] as? String {
                    tokenText = contentStr
                } else if let text = update["text"] as? String {
                    tokenText = text
                } else if let delta = update["delta"] as? String {
                    tokenText = delta
                }

                if let text = tokenText, !text.isEmpty {
                    // Only stream message chunks (skip internal thought chunks from output)
                    if sessionUpdate == "agent_message_chunk" || sessionUpdate.isEmpty {
                        receivedTokens = true
                        await onToken(text)
                    }
                }
            }

            // 3. Detect turn completion
            if let method = json["method"] as? String {
                if method == "_x.ai/session/prompt_complete" {
                    break
                }
            }

            if let id = json["id"] as? Int, id == 3 {
                // Standard prompt response completion
                break
            }

            if let result = json["result"] as? [String: Any],
               let stopReason = result["stopReason"] as? String {
                if stopReason == "completed" || stopReason == "end_turn" {
                    break
                }
            }
        }

        // Clean up process immediately without hanging on persistent stdio daemon
        if process.isRunning {
            process.terminate()
        }

        if !receivedTokens {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !errMsg.isEmpty {
                throw NSError(domain: "ACPError", code: 3, userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
        }
    }

    // MARK: - Driver 2: CLI Streaming Runner (Claude Code, Pi, Codex, Cursor)
    private func runCLIStreaming(
        command: String,
        systemPrompt: String,
        userPrompt: String,
        activeQuote: String?,
        onToken: @escaping @MainActor (String) -> Void,
        processRole: ProcessRole = .chat
    ) async throws {
        let parts = command.components(separatedBy: " ").filter { !$0.isEmpty }
        guard let binName = parts.first else {
            throw NSError(domain: "CLIError", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的 CLI 命令"])
        }

        guard let resolvedBin = Self.findBinaryPath(name: binName) else {
            throw NSError(domain: "CLIError", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到可执行文件 `\(binName)`。请确认已安装到 PATH。"])
        }

        let fullPrompt = "\(systemPrompt)\n\n【读者问题】：\(userPrompt)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedBin)

        var args = Array(parts.dropFirst())
        args.append(fullPrompt)
        process.arguments = args
        process.environment = Self.buildEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        switch processRole {
        case .chat:
            self.chatProcess = process
        case .translation:
            self.registerTranslationProcess(process)
            defer { self.unregisterTranslationProcess(process) }
        }

        try process.run()

        var receivedAny = false
        let fileHandle = outPipe.fileHandleForReading

        for try await line in fileHandle.bytes.lines {
            try Task.checkCancellation()
            // Filter common CLI banner warnings
            if line.hasPrefix("Warning: No models match") {
                continue
            }
            receivedAny = true
            await onToken(line + "\n")
        }

        process.waitUntilExit()

        if !receivedAny || process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !errMsg.isEmpty {
                throw NSError(domain: "CLIError", code: 3, userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
        }
    }

    // MARK: - Driver 3: Ollama Adapter
    private func runOllamaAdapter(
        endpoint: String,
        model: String,
        systemPrompt: String,
        history: [ChatMessage],
        userPrompt: String,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let url = URL(string: "\(endpoint)/api/chat") else {
            throw URLError(.badURL)
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in history.suffix(8) {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ])
        }
        messages.append(["role": "user", "content": userPrompt])

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "options": ["temperature": 0.7]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "OllamaError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ollama 请求错误，请检查模型 \(model)"])
        }

        struct Chunk: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message?
            let done: Bool?
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(Chunk.self, from: d),
               let text = chunk.message?.content {
                await onToken(text)
                if chunk.done == true { break }
            }
        }
    }

    // MARK: - Driver 4: OpenAI / LM Studio Adapter
    private func runOpenAIAdapter(
        endpoint: String,
        model: String,
        systemPrompt: String,
        history: [ChatMessage],
        userPrompt: String,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let url = URL(string: "\(endpoint)/chat/completions") else {
            throw URLError(.badURL)
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in history.suffix(8) {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ])
        }
        messages.append(["role": "user", "content": userPrompt])

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "OpenAIError", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地 API 返回错误，请检查 LM Studio 服务"])
        }

        struct OpenAISSESelection: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
            }
            let choices: [Choice]?
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }
            let jsonString = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            if jsonString == "[DONE]" { break }

            guard let data = jsonString.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OpenAISSESelection.self, from: data),
                  let text = chunk.choices?.first?.delta?.content else { continue }

            await onToken(text)
        }
    }

    // MARK: - Driver 5: Embedded Engine
    private func runEmbeddedEngine(
        role: AIAgentRole,
        bookTitle: String,
        chapterTitle: String,
        activeQuote: String?,
        userPrompt: String,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws {
        let quote = activeQuote ?? "本章节核心文本"
        let response: String

        switch role {
        case .deepReader:
            response = """
            ### 📖 深度导读解析

            在《\(bookTitle)》**\(chapterTitle)** 中，这段文字展现了深刻的思辨深度：

            > “\(quote.prefix(60))...”

            #### 1. 文本内在逻辑与微言大义
            作者在这里的行文并非孤立叙述，而是通过具体的细节描摹折射出深层的隐喻。文字表面平缓，实则暗流涌动，呈现出心境与外部环境之间的微妙张力。

            #### 2. 时代语境与思想脉络
            从思想史与文学演进的维度来看，这一论述承接了经典叙事的传统，将普遍性的人性困境置于具体的历史横切面中。作者在此处埋下了重要的思想伏笔，与全书的核心主旨形成回响。

            #### 3. 伴读心法
            在阅读本节时，建议关注作者在关键词选择上的留白与克制，其未言之意往往胜过直白之语。
            """

        case .criticalThinker:
            response = """
            ### 🔍 批判性审视与逻辑质询

            针对选段『\(quote.prefix(50))...』：

            1. **核心假定的局限性**：作者在推演观点时，默认了一个关键前设。然而如果置换环境或历史坐标，这一因果链条便容易受到挑战。
            2. **幸存者偏差与主观投射**：论述中选取的例证是否具备普适性？是否忽略了反向例证？
            3. **开放反思**：如果将这个命题推向极端，其理论边界在何处崩塌？
            """

        case .ideaExtractor:
            response = """
            ### 💡 核心观点与实践灵感

            从当前选段中萃取的精华要点：

            * 📌 **核心洞见**：直击本质，强调在不确定性中建立内在秩序的重要性。
            * 🔑 **关键启发**：
              1. 敏锐觉察环境中的微弱信号，不被浮躁表象遮蔽；
              2. 保持独立思考与心智留白；
              3. 将知解转化为习惯与行动力。
            * 🎯 **行动建议**：尝试在接下来的阅读中用自己的话复述本段的底层论据。
            """

        case .translator:
            response = """
            ### 🌐 文学语境精译与鉴赏

            **选文原句**：
            > \(quote)

            **信达雅译文**：
            > *\(quote.contains(where: { $0.isASCII && $0.isLetter }) ? "（此处提供纯正优雅的中文文学对译）" : "（此处提供贴合原著语境的对应英文精译）")*

            **修辞与用词品析**：
            * 句式节奏起伏有致，长短句相间；
            * 带有鲜明的风格烙印与文化隐喻。
            """
        }

        for char in response {
            try Task.checkCancellation()
            await onToken(String(char))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
