import Foundation

/// Piper 合成桥：常驻 venv Python 进程（piper1-gpl），stdin 逐行送文本、
/// stdout 按帧收 wav（8 字节小端长度头 + 数据）。进程崩了下次合成自动重启。
/// 协议与脚本常量 piperBridgeScript 严格对应。
final class PiperBridge: @unchecked Sendable {
    static let shared = PiperBridge()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private let lock = NSLock()
    private var launchFailed = false
    /// 测试只替换启动命令，仍使用完整的真实管道与帧协议。
    private let processFactory: (@Sendable () throws -> Process)?

    init(processFactory: (@Sendable () throws -> Process)? = nil) {
        self.processFactory = processFactory
    }

    // MARK: - 桥接脚本（写入 Piper 根目录后由 venv python 执行）

    static let piperBridgeScript = #"""
    import io
    import json
    import os
    import struct
    import sys
    import wave

    def main():
        model_path = os.environ.get("PIPER_MODEL", "")
        if not model_path or not os.path.isfile(model_path):
            print("model not found: " + model_path, file=sys.stderr)
            return 2
        try:
            from piper import PiperVoice, SynthesisConfig
        except ImportError as e:
            print("piper package missing: %s" % e, file=sys.stderr)
            return 3
        try:
            voice = PiperVoice.load(model_path)
        except Exception as e:
            print("voice load failed: %s" % e, file=sys.stderr)
            return 4

        default_length_scale = os.environ.get("PIPER_LENGTH_SCALE", "1.0")

        ready = json.dumps({"ok": True})
        sys.stdout.buffer.write(struct.pack("<Q", len(ready)))
        sys.stdout.buffer.write(ready.encode("utf-8"))
        sys.stdout.buffer.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
                text = req.get("text", "")
                length_scale = float(req.get("length_scale", default_length_scale))
            except Exception:
                continue
            if not text:
                continue
            try:
                config = SynthesisConfig(length_scale=length_scale)
                buf = io.BytesIO()
                with wave.open(buf, "wb") as wav_file:
                    voice.synthesize_wav(text, wav_file, syn_config=config)
                data = buf.getvalue()
                sys.stdout.buffer.write(struct.pack("<Q", len(data)))
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            except Exception as e:
                msg = ("error: %s" % e).encode("utf-8")
                sys.stdout.buffer.write(struct.pack("<Q", 0))
                sys.stdout.buffer.write(struct.pack("<Q", len(msg)))
                sys.stdout.buffer.write(msg)
                sys.stdout.buffer.flush()

    if __name__ == "__main__":
        sys.exit(main())
    """#

    static var bridgeScriptURL: URL {
        PiperInstaller.piperRoot.appendingPathComponent("piper_bridge.py")
    }

    /// 确保脚本落盘（每次启动合成前调用，幂等）
    func ensureScriptOnDisk() throws {
        let url = Self.bridgeScriptURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try Self.piperBridgeScript.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 进程生命周期

    /// 调用方持锁；启动与请求在同一临界区内，避免 shutdown 插在二者之间。
    private func launchIfNeededLocked() throws {
        if let process, process.isRunning {
            return
        }
        cleanupLocked()
        guard !launchFailed else { throw ReadAloudError.piperFailed("桥进程此前启动失败") }

        let proc: Process
        if let processFactory {
            proc = try processFactory()
        } else {
            try ensureScriptOnDisk()
            guard FileManager.default.isExecutableFile(atPath: PiperInstaller.venvPython.path) else {
                throw ReadAloudError.piperNotInstalled
            }
            proc = Process()
            proc.executableURL = PiperInstaller.venvPython
            proc.arguments = [Self.bridgeScriptURL.path]
            proc.environment = [
                "PIPER_MODEL": PiperInstaller.modelURL.path,
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
            ]
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // 错误通过协议帧返回，stderr 不留无人消费的管道，防止写满阻塞。
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading

        // ready 和后续 wav 帧必须共用句柄及缓冲，不能丢弃同次读取的尾部。
        do {
            let readyData = try readFrameLocked(from: stdoutPipe.fileHandleForReading)
            guard let ready = try JSONSerialization.jsonObject(with: readyData) as? [String: Any],
                  ready["ok"] as? Bool == true else {
                throw ReadAloudError.piperFailed("桥未返回就绪帧")
            }
        } catch {
            cleanupLocked()
            launchFailed = true
            throw ReadAloudError.piperFailed("桥启动失败: \(error.localizedDescription)")
        }

        proc.terminationHandler = { [weak self] exitedProcess in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            // 旧进程的延迟退出通知不能清理已重启的新进程。
            guard self.process === exitedProcess else { return }
            self.cleanupLocked()
        }
    }

    /// 合成一段文本 → wav Data。失败抛错由上层回退 AI 引擎。
    func synthesize(text: String, lengthScale: Double) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { [weak self] in
                guard let self else {
                    cont.resume(throwing: ReadAloudError.piperFailed("桥已释放"))
                    return
                }
                do {
                    let data = try self.synthesizeSync(text: text, lengthScale: lengthScale)
                    cont.resume(returning: data)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func synthesizeSync(text: String, lengthScale: Double) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try launchIfNeededLocked()
        guard let stdin = stdinHandle, let stdout = stdoutHandle,
              let proc = process, proc.isRunning else {
            throw ReadAloudError.piperFailed("桥进程未就绪")
        }
        // 请求帧：一行 JSON（length_scale 每段可调）
        let request: [String: Any] = ["text": text, "length_scale": lengthScale]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        try stdin.write(contentsOf: requestData)
        try stdin.write(contentsOf: Data("\n".utf8))
        return try readFrameLocked(from: stdout)
    }

    /// 读一帧：8 字节长度头 + 数据。错误帧（长度头 0）展开为异常。
    private func readFrameLocked(from handle: FileHandle) throws -> Data {
        let header = try readExactLocked(handle, count: 8)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        if length == 0 {
            let errHeader = try readExactLocked(handle, count: 8)
            let errLen = errHeader.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            guard errLen > 0, errLen < 512 * 1024 * 1024 else {
                throw ReadAloudError.piperFailed("桥错误帧长度无效")
            }
            let errData = try readExactLocked(handle, count: Int(errLen))
            let msg = String(data: errData, encoding: .utf8) ?? "unknown bridge error"
            throw ReadAloudError.piperFailed(msg)
        }
        guard length < 512 * 1024 * 1024 else {
            throw ReadAloudError.piperFailed("桥输出帧长度无效")
        }
        return try readExactLocked(handle, count: Int(length))
    }

    private func readExactLocked(_ handle: FileHandle, count: Int) throws -> Data {
        var collected = stdoutBuffer
        stdoutBuffer = Data()
        while collected.count < count {
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                throw ReadAloudError.piperFailed("桥输出中断")
            }
            collected.append(chunk)
        }
        if collected.count > count {
            stdoutBuffer = Data(collected.dropFirst(count))
        }
        return Data(collected.prefix(count))
    }

    private func cleanupLocked() {
        let oldProcess = process
        process = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stdoutBuffer = Data()
        if oldProcess?.isRunning == true {
            oldProcess?.terminate()
        }
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
        launchFailed = false
    }
}
