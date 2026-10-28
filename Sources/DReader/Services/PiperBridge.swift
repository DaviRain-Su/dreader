import Foundation

/// Piper 合成桥：常驻 venv Python 进程（piper1-gpl），stdin 逐行送文本、
/// stdout 按帧收 wav（8 字节小端长度头 + 数据）。进程崩了下次合成自动重启。
/// 协议与脚本常量 piperBridgeScript 严格对应。
final class PiperBridge: @unchecked Sendable {
    static let shared = PiperBridge()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private let lock = NSLock()
    private var launchFailed = false

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

    private func launchIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if let process, process.isRunning {
            return
        }
        guard !launchFailed else { throw ReadAloudError.piperFailed("桥进程此前启动失败") }
        try ensureScriptOnDisk()

        guard FileManager.default.isExecutableFile(atPath: PiperInstaller.venvPython.path) else {
            throw ReadAloudError.piperNotInstalled
        }

        let proc = Process()
        proc.executableURL = PiperInstaller.venvPython
        proc.arguments = [Self.bridgeScriptURL.path]
        proc.environment = [
            "PIPER_MODEL": PiperInstaller.modelURL.path,
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
        ]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        try proc.run()

        // 等就绪帧（模型加载 1~3 秒）
        let readyData = readFrameLocked(from: stdoutPipe.fileHandleForReading)
        guard readyData != nil else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            proc.terminate()
            launchFailed = true
            throw ReadAloudError.piperFailed("桥启动失败: \(err.prefix(200))")
        }

        // 后台收割退出状态，防止僵尸进程
        proc.terminationHandler = { [weak self] _ in
            self?.lock.lock()
            self?.process = nil
            self?.stdinHandle = nil
            self?.stdoutBuffer = Data()
            self?.lock.unlock()
        }
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutBuffer = Data()
    }

    /// 合成一段文本 → wav Data。失败抛错由上层回退 AI 引擎。
    func synthesize(text: String, lengthScale: Double) async throws -> Data {
        try launchIfNeeded()
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
        guard let stdin = stdinHandle, let proc = process, proc.isRunning else {
            throw ReadAloudError.piperFailed("桥进程未就绪")
        }
        guard let stdoutHandle = proc.standardOutput as? FileHandle else {
            throw ReadAloudError.piperFailed("桥 stdout 不可用")
        }
        // 请求帧：一行 JSON（length_scale 每段可调）
        let request: [String: Any] = ["text": text, "length_scale": lengthScale]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        try stdin.write(contentsOf: requestData)
        try stdin.write(contentsOf: Data("\n".utf8))

        guard let frame = readFrameLocked(from: stdoutHandle) else {
            throw ReadAloudError.piperFailed("桥输出中断")
        }
        return frame
    }

    /// 读一帧：8 字节长度头 + 数据。错误帧（长度头 0）展开为异常。
    private func readFrameLocked(from handle: FileHandle) -> Data? {
        guard let header = readExactLocked(handle, count: 8), header.count == 8 else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        // 错误帧：长度 0，后跟另一长度头 + 文本
        if length == 0 {
            guard let errHeader = readExactLocked(handle, count: 8),
                  errHeader.count == 8 else { return nil }
            let errLen = errHeader.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            guard let errData = readExactLocked(handle, count: Int(errLen)) else { return nil }
            let msg = String(data: errData, encoding: .utf8) ?? "unknown bridge error"
            // 以异常形式传达（同步上下文，直接抛）
            _ = msg
            return Data() // 空数据 = 失败信号
        }
        guard length > 0, length < 512 * 1024 * 1024 else { return nil }
        return readExactLocked(handle, count: Int(length))
    }

    private func readExactLocked(_ handle: FileHandle, count: Int) -> Data? {
        var collected = stdoutBuffer
        stdoutBuffer = Data()
        while collected.count < count {
            let chunk = handle.availableData
            if chunk.isEmpty { // EOF
                stdoutBuffer = Data(collected.suffix(min(collected.count, count - 1)))
                return collected.count == count ? collected : nil
            }
            collected.append(chunk)
        }
        if collected.count > count {
            stdoutBuffer = Data(collected.dropFirst(count))
        }
        return collected.prefix(count)
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if let stdin = stdinHandle {
            try? stdin.close()
        }
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutBuffer = Data()
    }
}
