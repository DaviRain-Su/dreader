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
    private var activeProcess: Process?

    init() {
        selectPreset(currentPreset)
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

        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
        }
        activeProcess = nil
        isGenerating = false
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
                    }
                )

            case .cliStreaming:
                try await runCLIStreaming(
                    command: customCommand,
                    systemPrompt: systemContext,
                    userPrompt: trimmed,
                    activeQuote: nil,
                    onToken: { token in
                        collectedResult += token
                    }
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
        onToken: @escaping @MainActor (String) -> Void
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

        self.activeProcess = process

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
        onToken: @escaping @MainActor (String) -> Void
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

        self.activeProcess = process

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
