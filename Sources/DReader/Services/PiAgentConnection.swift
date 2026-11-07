import Foundation

/// 子进程环境与二进制查找(自 AIAgentService 移入;pi 需要用户工具链 PATH)
enum AgentProcessEnvironment {
    static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let customPaths = [
            "\(home)/.kimi-code/bin",
            "\(home)/.grok/bin",
            "\(home)/.local/bin",
            "\(home)/.pi/agent/bin",
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
}

/// pi RPC 长驻子进程连接:JSONL over stdin/stdout。
///
/// 生命周期约定(实测 pi v1.5.0):
/// - stdin EOF 会让 pi 静默终止——本连接常驻期间**绝不关 stdin**,由 `terminate()` 显式收尾
/// - 命令/响应按可选 `id` 关联;事件(agent_start/message_update/agent_settled…)无 id,广播给订阅者
/// - stdout 专用于协议记录,诊断走 stderr
final class PiRPCConnection: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let stateLock = NSLock()
    private var requestCounter = 0
    /// id → 等待中的响应续体(存原始行,String 是 Sendable;锁内登记/摘除,锁外 resume)
    private var pendingResponses: [String: CheckedContinuation<String, Never>] = [:]
    /// 事件订阅者(收原始 JSON 行;String 是 Sendable,解析下沉到 PiRPCProtocol)
    private var eventHandlers: [(id: UUID, handler: @Sendable (String) -> Void)] = []
    private var didTerminate = false
    /// stderr 尾部(环形,8KB):失败诊断用
    private var stderrTail = Data()
    private let stderrLimit = 8192

    /// pi 二进制路径(找不到为 nil)
    static func locatePiBinary() -> String? {
        AgentProcessEnvironment.findBinaryPath(name: "pi")
    }

    /// 启动 pi RPC 子进程。`extraArgs` 附加在模式参数之后(模型选择等)。
    func start(extraArgs: [String] = []) throws {
        guard let bin = Self.locatePiBinary() else {
            throw NSError(
                domain: "PiRPC", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未找到 pi CLI,请先安装:curl -fsSL https://pi.dev/install.sh | sh"]
            )
        }
        stateLock.lock()
        didTerminate = false
        stateLock.unlock()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["--mode", "rpc", "--no-session"] + extraArgs
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = AgentProcessEnvironment.buildEnvironment()
        pumpStderr()
        try process.run()
        pumpStdout()
    }

    var isRunning: Bool {
        process.isRunning
    }

    /// 最近 stderr 摘要(诊断)
    var recentStderr: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return String(data: stderrTail, encoding: .utf8) ?? ""
    }

    /// 发送命令并等待其响应帧(原始 JSON 行)。事件帧不占用响应通道。
    /// 解析为字典用 `parseResponseLine`。
    func sendCommand(_ payload: [String: Any]) async throws -> String {
        var framed = payload
        let id: String = stateLock.withLock {
            requestCounter += 1
            return "dreader-req-\(requestCounter)"
        }
        framed["id"] = id
        let data = try JSONSerialization.data(withJSONObject: framed)
        guard process.isRunning else {
            throw NSError(domain: "PiRPC", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "pi RPC 进程未在运行"])
        }
        var line = data
        line.append(0x0A) // LF 终止(pi 协议帧规则)
        try stdinPipe.fileHandleForWriting.write(contentsOf: line)

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            stateLock.lock()
            if didTerminate {
                stateLock.unlock()
                continuation.resume(returning: #"{"type":"response","success":false,"error":"connection terminated"}"#)
                return
            }
            pendingResponses[id] = continuation
            stateLock.unlock()
        }
    }

    /// 同步写一帧命令(不等待响应;actor 上下文里不能 await 时用)
    func sendCommandSync(_ payload: [String: Any]) throws {
        var framed = payload
        let id: String = stateLock.withLock {
            requestCounter += 1
            return "dreader-req-\(requestCounter)"
        }
        framed["id"] = id
        let data = try JSONSerialization.data(withJSONObject: framed)
        guard process.isRunning else {
            throw NSError(domain: "PiRPC", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "pi RPC 进程未在运行"])
        }
        var line = data
        line.append(0x0A) // LF 终止(pi 协议帧规则)
        try stdinPipe.fileHandleForWriting.write(contentsOf: line)
    }

    /// 响应行 → 字典(失败或非 JSON 返回 success=false 的兜底字典)
    static func parseResponseLine(_ line: String) -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["type": "response", "success": false, "error": "响应不是合法 JSON: \(line.prefix(200))"]
        }
        return json
    }

    /// 订阅事件帧(收原始 JSON 行;agent_start / message_update / agent_settled …)。返回退订闭包。
    @discardableResult
    func subscribeEvents(_ handler: @escaping @Sendable (String) -> Void) -> @Sendable () -> Void {
        let token = UUID()
        stateLock.lock()
        eventHandlers.append((token, handler))
        stateLock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.eventHandlers.removeAll { $0.id == token }
            self.stateLock.unlock()
        }
    }

    /// 有序退出:关 stdin(pi 收到 EOF 走有序关闭)+ SIGTERM 兜底
    func terminate() {
        stateLock.lock()
        if didTerminate { stateLock.unlock(); return }
        didTerminate = true
        let waiters = pendingResponses
        pendingResponses.removeAll()
        stateLock.unlock()
        let fallback = Self.failureResponseLine(reason: "connection terminated")
        for (_, continuation) in waiters {
            continuation.resume(returning: fallback)
        }
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Internals

    private func pumpStderr() {
        let handle = stderrPipe.fileHandleForReading
        Task.detached(priority: .utility) { [weak self] in
            for try await chunk in Self.lfSplitFrames(handle: handle) {
                guard let self else { return }
                self.appendStderr(chunk + "\n")
            }
        }
    }

    private func appendStderr(_ line: String) {
        stateLock.lock()
        stderrTail.append(Data(line.utf8))
        if stderrTail.count > stderrLimit {
            stderrTail.removeFirst(stderrTail.count - stderrLimit)
        }
        stateLock.unlock()
    }

    /// 常驻读循环:逐帧解析 JSON,响应按 id 派发,事件广播。
    /// 进程退出后循环自然结束;等待中的响应由 failAllWaiters 兜底。
    private func pumpStdout() {
        let handle = stdoutPipe.fileHandleForReading
        let weakSelf = self
        Task.detached(priority: .userInitiated) {
            for try await line in Self.lfSplitFrames(handle: handle) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                weakSelf.dispatchFrame(json, rawLine: trimmed)
            }
            // stdout 关闭 = 进程退出:唤醒全部等待者(响应带失败标记)
            let err = weakSelf.recentStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = "pi 进程已退出" + (err.isEmpty ? "" : ":\(err.suffix(300))")
            weakSelf.failAllWaiters(reason: reason)
        }
    }

    private func dispatchFrame(_ json: [String: Any], rawLine: String) {
        let type = json["type"] as? String
        if type == "response", let id = json["id"] as? String {
            stateLock.lock()
            let continuation = pendingResponses.removeValue(forKey: id)
            stateLock.unlock()
            continuation?.resume(returning: rawLine)
            return
        }
        // 无 id 的会话事件 → 广播原始行(解析由订阅方做)
        guard type != nil, json["id"] == nil else { return }
        stateLock.lock()
        let handlers = eventHandlers.map { $0.handler }
        stateLock.unlock()
        for handler in handlers {
            handler(rawLine)
        }
    }

    /// 字节级 LF 分帧:pi 文档警告勿用把 U+2028/U+2029 当记录边界的行读取器
    /// (Node readline 中招;实测 Swift `AsyncBytes.lines` 同样中招,LLM 输出含该字符时撕裂帧)。
    /// 这里按 0x0A 切分,字节流内其他 Unicode 一律不视为记录边界。
    static func lfSplitFrames(handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var buffer = Data()
                for try await byte in handle.bytes {
                    if byte == 0x0A {
                        let line = String(data: buffer, encoding: .utf8) ?? ""
                        buffer.removeAll()
                        continuation.yield(line)
                    } else {
                        buffer.append(byte)
                    }
                }
                if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
                    continuation.yield(tail)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func failAllWaiters(reason: String) {
        stateLock.lock()
        let waiters = pendingResponses
        pendingResponses.removeAll()
        stateLock.unlock()
        let fallback = Self.failureResponseLine(reason: reason)
        for (_, continuation) in waiters {
            continuation.resume(returning: fallback)
        }
    }

    private static func failureResponseLine(reason: String) -> String {
        let payload: [String: Any] = ["type": "response", "success": false, "error": reason]
        return String(data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}
