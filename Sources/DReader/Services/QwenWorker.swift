import Foundation

enum QwenWorkerError: LocalizedError {
    case notInstalled
    case cancelled
    case timeout
    case invalidResponse(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Qwen 模型或独立后端未安装"
        case .cancelled: return "Qwen 合成已取消"
        case .timeout: return "Qwen 加载或合成超时，请重试"
        case .invalidResponse(let detail): return "Qwen 返回无效音频：\(detail)"
        case .failed(let detail): return "Qwen 合成失败：\(detail)"
        }
    }
}

/// 常驻 Qwen 进程。I/O 串行，取消不需要等待正在阻塞的读取锁。
final class QwenWorker: @unchecked Sendable {
    static let shared = QwenWorker()

    static let script = #"""
    import io
    import json
    import struct
    import sys
    import wave

    def frame(payload):
        sys.stdout.buffer.write(struct.pack('<Q', len(payload)))
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.flush()

    def fail(error):
        message = str(error)[:800].encode('utf-8', errors='replace')
        frame(struct.pack('<Q', 0) + struct.pack('<Q', len(message)) + message)

    try:
        from mlx_audio.tts.utils import load_model
        import numpy as np
        model = load_model(sys.argv[1])
        frame(json.dumps({'ok': True}).encode('utf-8'))
    except Exception as error:
        fail(error)
        raise SystemExit(1)

    for line in sys.stdin:
        try:
            request = json.loads(line)
            text = request.get('text', '')
            if not text or len(text) > 10000:
                raise ValueError('invalid text length')
            chunks = []
            rate = None
            for result in model.generate_custom_voice(
                text=text,
                speaker=request['speaker'],
                language='Chinese',
                instruct=request.get('instruct', '以平静温和的语气连贯讲述，停顿自然，不要夸张表演。'),
                stream=True,
                streaming_interval=0.32,
                verbose=False,
            ):
                chunks.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
                rate = int(result.sample_rate)
            if not chunks or rate != 24000:
                raise ValueError('empty audio or unsupported sample rate')
            audio = np.concatenate(chunks)
            if audio.size == 0 or not np.isfinite(audio).all():
                raise ValueError('empty or non-finite audio')
            pcm = (np.clip(audio, -1.0, 1.0) * 32767).round().astype('<i2')
            output = io.BytesIO()
            with wave.open(output, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(rate)
                wav.writeframes(pcm.tobytes())
            frame(output.getvalue())
        except Exception as error:
            fail(error)
    """#

    private let ioLock = NSLock()
    private let stateLock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var timedOut = false
    private var exitError: QwenWorkerError?
    private let processFactory: (() throws -> Process)?
    private let scriptURL: URL
    private let launchTimeout: TimeInterval
    private let requestTimeout: TimeInterval

    init(processFactory: (() throws -> Process)? = nil,
         scriptURL: URL = QwenInstallation.workerScriptURL,
         launchTimeout: TimeInterval = 120,
         requestTimeout: TimeInterval = 120) {
        self.processFactory = processFactory
        self.scriptURL = scriptURL
        self.launchTimeout = launchTimeout
        self.requestTimeout = requestTimeout
    }

    func synthesize(text: String, voice: ReaderSettings.QwenVoice) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try self.synthesizeSync(text: text, voice: voice)
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func synthesizeSync(text: String, voice: ReaderSettings.QwenVoice) throws -> Data {
        ioLock.lock()
        defer { ioLock.unlock() }
        try launchIfNeededLocked()
        guard let process = currentProcess(), let stdin = stdinHandle else {
            throw QwenWorkerError.cancelled
        }
        let request: [String: Any] = [
            "text": text,
            "speaker": voice.backendName,
            "instruct": "以平静温和的语气连贯讲述，停顿自然，不要夸张表演。",
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        try stdin.write(contentsOf: data)
        try stdin.write(contentsOf: Data("\n".utf8))
        let watchdog = armWatchdog(for: process, after: requestTimeout)
        defer { watchdog.cancel() }
        let audio = try readFrameLocked()
        guard audio.count > 44,
              String(decoding: audio.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: audio[8..<12], as: UTF8.self) == "WAVE",
              integer(UInt16.self, in: audio, at: 22) == 1,
              integer(UInt32.self, in: audio, at: 24) == 24000,
              integer(UInt16.self, in: audio, at: 34) == 16 else {
            throw QwenWorkerError.invalidResponse("需要 24kHz 单声道 16-bit PCM WAV")
        }
        return audio
    }

    private func launchIfNeededLocked() throws {
        if let process, process.isRunning { return }
        cleanupLocked()
        let proc: Process
        if let processFactory {
            proc = try processFactory()
        } else {
            guard QwenInstallation.status() == .ready else { throw QwenWorkerError.notInstalled }
            try FileManager.default.createDirectory(at: QwenInstallation.root, withIntermediateDirectories: true)
            for directory in [QwenInstallation.cacheDirectory, QwenInstallation.homeDirectory, QwenInstallation.temporaryDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let script = Data(Self.script.utf8)
            if (try? Data(contentsOf: scriptURL)) != script {
                try script.write(to: scriptURL, options: .atomic)
            }
            proc = Process()
            proc.executableURL = QwenInstallation.pythonURL
            proc.arguments = [scriptURL.path, QwenInstallation.modelDirectory.path]
            proc.environment = [
                "HOME": QwenInstallation.homeDirectory.path,
                "PATH": "\(QwenInstallation.venvDirectory.path)/bin:/usr/bin:/bin:/opt/homebrew/bin",
                "TMPDIR": QwenInstallation.temporaryDirectory.path,
                "HF_HOME": QwenInstallation.cacheDirectory.path,
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
                "HF_HUB_DISABLE_TELEMETRY": "1",
                "PYTHONNOUSERSITE": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONUTF8": "1",
            ]
        }
        let input = Pipe()
        let output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        if proc.standardError == nil { proc.standardError = FileHandle.nullDevice }
        try proc.run()
        log("launch running=\(proc.isRunning)")
        stateLock.lock()
        process = proc
        stdinHandle = input.fileHandleForWriting
        stdoutHandle = output.fileHandleForReading
        stateLock.unlock()

        proc.terminationHandler = { [weak self] exited in
            guard let self else { return }
            self.stateLock.lock()
            let isCurrent = self.process === exited
            if isCurrent {
                self.process = nil
                self.exitError = self.timedOut ? .timeout : .failed("worker 进程已退出")
            }
            self.stateLock.unlock()
            // 旧进程通知不清理后来启动的进程，句柄只在 I/O 锁内关闭。
        }

        let watchdog = armWatchdog(for: proc, after: launchTimeout)
        defer { watchdog.cancel() }
        do {
            let data = try readFrameLocked()
            log("ready bytes=\(data.count)")
            let ready = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard ready?["ok"] as? Bool == true else {
                throw QwenWorkerError.invalidResponse("worker 未返回就绪帧")
            }
        } catch {
            terminateIfCurrent(proc)
            throw error
        }
    }

    private func readFrameLocked() throws -> Data {
        let header = try readExactLocked(count: 8)
        let length = integer(UInt64.self, in: header, at: 0)
        log("frame length=\(length)")
        if length == 0 {
            let length = integer(UInt64.self, in: try readExactLocked(count: 8), at: 0)
            guard length > 0, length < 1024 * 1024 else {
                throw QwenWorkerError.invalidResponse("错误帧长度无效")
            }
            let data = try readExactLocked(count: Int(length))
            let message = String(decoding: data, as: UTF8.self)
            if message.contains("operation was cancelled") || message.contains("请求被取消") {
                throw QwenWorkerError.cancelled
            }
            throw QwenWorkerError.failed(message)
        }
        guard length > 0, length <= 128 * 1024 * 1024 else {
            throw QwenWorkerError.invalidResponse("音频帧长度无效")
        }
        return try readExactLocked(count: Int(length))
    }

    private func readExactLocked(count: Int) throws -> Data {
        var data = stdoutBuffer
        stdoutBuffer = Data()
        while data.count < count {
            guard let process = currentProcess(), let handle = stdoutHandle else {
                log("read guard failed: process or stdout is nil")
                throw currentFailure()
            }
            guard process.isRunning else {
                log("read guard failed: process exited \(process.terminationStatus)")
                throw QwenWorkerError.failed("worker 进程退出，状态 \(process.terminationStatus)")
            }
            let chunk = handle.availableData
            log("read chunk=\(chunk.count), need=\(count), have=\(data.count)")
            guard !chunk.isEmpty else { throw currentFailure() }
            data.append(chunk)
        }
        if data.count > count { stdoutBuffer = Data(data.dropFirst(count)) }
        return Data(data.prefix(count))
    }

    private func integer<T: FixedWidthInteger>(_ type: T.Type, in data: Data, at offset: Int) -> T {
        data.subdata(in: offset..<(offset + MemoryLayout<T>.size))
            .withUnsafeBytes { $0.loadUnaligned(as: T.self).littleEndian }
    }

    private func currentProcess() -> Process? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return process
    }

    private func currentFailure() -> QwenWorkerError {
        stateLock.lock()
        defer { stateLock.unlock() }
        log("failure timeout=\(timedOut), exit=\(String(describing: exitError))")
        return exitError ?? (timedOut ? .timeout : .cancelled)
    }

    private func log(_ message: String) {
        guard ProcessInfo.processInfo.environment["DREADER_QWEN_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("QwenWorker \(message)\n".utf8))
    }

    private func armWatchdog(for process: Process, after timeout: TimeInterval) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self, weak process] in
            guard let process else { return }
            self?.terminateIfCurrent(process, timeout: true)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        return item
    }

    private func terminateIfCurrent(_ process: Process, timeout: Bool = false) {
        log("terminate timeout=\(timeout)")
        stateLock.lock()
        guard self.process === process else {
            stateLock.unlock()
            log("terminate skipped: stale process")
            return
        }
        self.process = nil
        timedOut = timedOut || timeout
        exitError = timeout ? .timeout : .cancelled
        stateLock.unlock()
        if process.isRunning { process.terminate() }
    }

    private func cleanupLocked() {
        stateLock.lock()
        let old = process
        let input = stdinHandle
        let output = stdoutHandle
        stateLock.unlock()
        if let old { terminateIfCurrent(old) }
        try? input?.close()
        try? output?.close()
        timedOut = false
        exitError = nil
        stdoutBuffer = Data()
    }

    func cancel() {
        if let process = currentProcess() { terminateIfCurrent(process) }
    }

    func shutdown() {
        ioLock.lock()
        defer { ioLock.unlock() }
        cleanupLocked()
    }
}
