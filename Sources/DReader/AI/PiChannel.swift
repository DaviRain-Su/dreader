import Foundation

/// pi agent 单 lane:一条 lane = 一个长驻 pi RPC 子进程。
///
/// Lane 拓扑(定型):
/// - `chat`(1 条):聊天问答,串行 FIFO
/// - `guide`(1 条):导读生成,串行
/// - `translate`(n 条,n = BilingualTranslationService.batchConcurrency,现 2):批翻
///
/// 为什么一条 lane 一个进程:pi 的 `abort` 是**进程级**命令,无法只取消一条会话;
/// 事件帧也无请求 id,串行 lane 是「事件归属哪次请求」的归因前提。
/// 单进程下「停止翻译」必然误杀聊天,所以拍板进程池。
actor PiChannel: PiTranslationDriving {
    let laneID: String
    /// lane 专属 system prompt(进程启动时以 --system-prompt 注入,替换 pi 默认 coding prompt)
    private var systemPrompt: String?
    private var connection: PiRPCConnection?
    private var currentModel: String?
    /// 进程刚启动、get_state 尚未回包时的乐观值(启动参数注入的模型)
    private var pendingModel: String?

    nonisolated var id: String { laneID }

    init(laneID: String, systemPrompt: String? = nil) {
        self.laneID = laneID
        self.systemPrompt = systemPrompt
    }

    var isRunning: Bool {
        connection?.isRunning == true
    }

    /// 确保子进程在运行;已运行则直接返回
    func ensureRunning() throws {
        if connection?.isRunning == true { return }
        connection?.terminate()
        let conn = PiRPCConnection()
        // 阅读场景不需要 pi 的文件/bash 工具;--no-tools + --no-mcp 收窄攻击面与 token 开销
        var extraArgs = ["--no-tools", "--no-mcp"]
        if let systemPrompt, !systemPrompt.isEmpty {
            extraArgs += ["--system-prompt", systemPrompt]
        }
        try conn.start(extraArgs: extraArgs)
        connection = conn
        currentModel = nil
    }

    /// 重启子进程(模型切换后生效;system prompt 沿用 lane 当前值)
    func restart() throws {
        connection?.terminate()
        connection = nil
        try ensureRunning()
    }

    /// 发送 prompt 并流式回传事件,直到 agent_settled(流自动结束)。
    /// - Throws: 进程未启动 / pi 返回错误
    func prompt(_ text: String) async throws -> AsyncStream<PiEvent> {
        try await promptWithSystem(nil, userPrompt: text)
    }

    /// 带独立 system prompt 的 prompt(不拼接进 user 文本;lane 未带 system prompt 时报错)
    /// - Throws: lane 未配置 system prompt / pi 返回错误
    func promptWithSystem(_ system: String?, userPrompt: String) async throws -> AsyncStream<PiEvent> {
        if system != nil, self.systemPrompt == nil {
            throw PiAgentError.commandFailed(
                command: "prompt",
                detail: "lane「\(laneID)」启动时未配置 system prompt,无法按请求切换"
            )
        }
        try ensureRunning()
        guard let conn = connection else {
            throw PiAgentError.channelNotRunning(laneID: laneID)
        }

        let (stream, continuation) = AsyncStream<PiEvent>.makeStream()

        // 串行 lane 语义:同一时刻只有一次 prompt 在飞;发命令前先 abort 清场
        _ = try? await conn.sendCommand(PiAbortCommand.dictionary(requestID: PiRequestID.next()))

        // 订阅事件帧(在写命令前订阅,防漏 agent_start)。
        // settle 后在回调内收流退订——绝不能起第二个消费者迭代同一 stream。
        // 退订闭包装 final class 盒,绕开「闭包捕获自身」的 Sendable 推导死结。
        let box = UnsubscribeBox()
        let unsubscribe = conn.subscribeEvents { line in
            guard let event = PiRPCProtocol.parseEvent(fromLine: line) else { return }
            if case .agentSettled = event {
                continuation.yield(event)
                continuation.finish()
                box.call()
                return
            }
            continuation.yield(event)
        }
        box.store(unsubscribe)

        do {
            let responseLine = try await conn.sendCommand([
                "type": "prompt",
                "message": userPrompt,
                "id": PiRequestID.next(),
            ])
            let response = PiRPCConnection.parseResponseLine(responseLine)
            guard response["success"] as? Bool == true else {
                throw PiAgentError.commandFailed(command: "prompt", detail: PiRPCProtocol.errorMessage(from: response))
            }
        } catch let error as PiAgentError {
            box.call()
            continuation.finish()
            throw error
        } catch {
            box.call()
            continuation.finish()
            throw PiAgentError.commandFailed(command: "prompt", detail: error.localizedDescription)
        }

        return stream
    }

    /// 中止当前 lane 上的运行(pi abort 是进程级——lane 内即「当前这次」)
    func abort() async {
        guard let conn = connection, conn.isRunning else { return }
        _ = try? await conn.sendCommand(PiAbortCommand.dictionary(requestID: PiRequestID.next()))
    }

    /// 设置模型(provider/modelID);幂等,同模型不重发
    func setModel(provider: String, modelID: String) async throws {
        guard currentModel != "\(provider)/\(modelID)" else { return }
        guard let conn = connection, conn.isRunning else {
            throw PiAgentError.channelNotRunning(laneID: laneID)
        }
        let responseLine = try await conn.sendCommand([
            "type": "set_model",
            "provider": provider,
            "modelId": modelID,
            "id": PiRequestID.next(),
        ])
        let response = PiRPCConnection.parseResponseLine(responseLine)
        guard response["success"] as? Bool == true else {
            throw PiAgentError.commandFailed(command: "set_model", detail: PiRPCProtocol.errorMessage(from: response))
        }
        currentModel = "\(provider)/\(modelID)"
    }

    /// 同步设置模型(actor 上下文不能 await 时用;不等待响应,乐观更新)
    func setModelSync(provider: String, modelID: String) throws {
        let full = "\(provider)/\(modelID)"
        guard currentModel != full else { return }
        guard let conn = connection, conn.isRunning else {
            throw PiAgentError.channelNotRunning(laneID: laneID)
        }
        try conn.sendCommandSync([
            "type": "set_model",
            "provider": provider,
            "modelId": modelID,
            "id": PiRequestID.next(),
        ])
        currentModel = full
        pendingModel = full
    }

    /// 拉取 pi 可用模型清单(get_available_models;1448 条含全部 provider)
    func fetchAvailableModels() async throws -> [PiRPCProtocol.ModelInfo] {
        try ensureRunning()
        guard let conn = connection else {
            throw PiAgentError.channelNotRunning(laneID: laneID)
        }
        let responseLine = try await conn.sendCommand(
            PiRPCProtocol.encodeGetAvailableModelsDict(requestID: PiRequestID.next())
        )
        let response = PiRPCConnection.parseResponseLine(responseLine)
        guard response["success"] as? Bool == true else {
            throw PiAgentError.commandFailed(command: "get_available_models",
                                            detail: PiRPCProtocol.errorMessage(from: response))
        }
        return PiRPCProtocol.parseAvailableModels(from: response)
    }

    /// 拉取 pi 当前模型(get_state → model);回包前回落到乐观值
    func fetchCurrentModel() async throws -> (provider: String, modelID: String)? {
        try ensureRunning()
        guard let conn = connection else {
            throw PiAgentError.channelNotRunning(laneID: laneID)
        }
        let responseLine = try await conn.sendCommand([
            "type": "get_state",
            "id": PiRequestID.next(),
        ])
        let response = PiRPCConnection.parseResponseLine(responseLine)
        guard response["success"] as? Bool == true,
              let parsed = PiRPCProtocol.parseCurrentModel(from: response) else {
            // get_state 慢/失败:回落到启动参数注入的乐观值
            if let pendingModel, let slash = pendingModel.firstIndex(of: "/") {
                return (String(pendingModel[..<slash]), String(pendingModel[pendingModel.index(after: slash)...]))
            }
            return nil
        }
        return parsed
    }

    /// 有序退出子进程
    func terminate() {
        connection?.terminate()
        connection = nil
    }

    /// 更新 lane 的 system prompt(下次 ensureRunning 以新值重建;当前连接直接重启)
    func updateSystemPrompt(_ prompt: String) {
        guard systemPrompt != prompt else { return }
        systemPrompt = prompt
        connection?.terminate()
        connection = nil
    }

    // MARK: - PiTranslationDriving(批翻桩:lane 的翻译语义由 facade 组合)

    func translate(_ request: PiTranslationRequest) async throws -> String {
        let stream = try await promptWithSystem(request.systemPrompt, userPrompt: request.promptText)
        var authoritative: String?
        for await event in stream {
            if case let .messageEnd(completion) = event, let completion {
                authoritative = completion.text
            }
        }
        if let authoritative, !authoritative.isEmpty {
            return authoritative
        }
        throw PiAgentError.emptyResponse(laneID: laneID)
    }

    // MARK: - Internals
}

// MARK: - 请求 id 与命令字典

/// 退订闭包盒:闭包自身捕获闭包的 Sendable 推导死结解法
private final class UnsubscribeBox: @unchecked Sendable {
    private var unsubscribe: (@Sendable () -> Void)?
    private let lock = NSLock()

    func store(_ fn: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        unsubscribe = fn
    }

    func call() {
        lock.lock(); defer { lock.unlock() }
        unsubscribe?()
        unsubscribe = nil
    }
}

/// 请求 id 生成(线程安全递增)
enum PiRequestID {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter = 0

    static func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "dreader-\(counter)"
    }
}

enum PiAbortCommand {
    static func dictionary(requestID: String) -> [String: Any] {
        ["type": "abort", "id": requestID]
    }
}

// MARK: - 错误

enum PiAgentError: LocalizedError {
    case channelNotRunning(laneID: String)
    case commandFailed(command: String, detail: String)
    case emptyResponse(laneID: String)
    case invalidJSON(detail: String)

    var errorDescription: String? {
        switch self {
        case let .channelNotRunning(laneID):
            return "pi lane「\(laneID)」未在运行"
        case let .commandFailed(command, detail):
            return "pi 命令「\(command)」失败:\(detail)"
        case let .emptyResponse(laneID):
            return "pi lane「\(laneID)」返回空响应"
        case let .invalidJSON(detail):
            return "pi 响应解析失败:\(detail)"
        }
    }
}

// MARK: - 批翻驱动注入缝(等价 BatchTranslationTests 的 testBatchDriverOverride)

/// 批翻驱动抽象:BilingualTranslationService 通过此协议注入 pi lane(生产)或假驱动(测试)。
protocol PiTranslationDriving: Sendable {
    var id: String { get }
    func translate(_ request: PiTranslationRequest) async throws -> String
}

/// 单段批翻请求
struct PiTranslationRequest: Sendable {
    /// 源文本(段落原文)
    let sourceText: String
    /// 目标语言(如 "zh-CN")
    let targetLanguage: String
    /// 上下文(前一段尾 + 后一段头,消歧用)
    let contextPrefix: String
    let contextSuffix: String
    /// system prompt(翻译 lane 以 --system-prompt 启动时固定;按请求传入时须 lane 支持)
    let systemPrompt: String?
    /// 完整 user prompt 文本(由 facade 组装)
    let promptText: String
}
