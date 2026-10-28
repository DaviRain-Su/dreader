import Foundation

/// Piper 本地神经网络 TTS 的安装器。
/// 走 piper1-gpl（Home Assistant 官方维护的 Python 发行版，PyPI 有 macOS arm64 轮子）：
/// 在 Application Support/DReader/Piper/venv 建独立 venv，pip 安装 piper-tts，
/// 复用已下载的「花言」onnx 模型。合成走桥接脚本（见 PiperBridge.swift），完全离线。
///
/// 历史注记：官方 C++ 2023.11.14-2 macOS tarball 是坏包（缺 libespeak-ng 等 dylib，
/// dyld 直接起不来），这是改走 Python 发行版的原因。
@MainActor
final class PiperInstaller: ObservableObject {
    static let shared = PiperInstaller()

    @Published var downloadProgress: Double? = nil // nil = 未在安装
    @Published var statusText: String = ""
    @Published var lastError: String? = nil

    // MARK: - 路径

    nonisolated static var piperRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("DReader/Piper", isDirectory: true)
    }

    nonisolated static var venvDir: URL { piperRoot.appendingPathComponent("venv", isDirectory: true) }
    nonisolated static var venvPython: URL { venvDir.appendingPathComponent("bin/python3") }
    nonisolated static var modelURL: URL { piperRoot.appendingPathComponent("zh_CN-huayan-medium.onnx") }
    nonisolated static var modelConfigURL: URL { piperRoot.appendingPathComponent("zh_CN-huayan-medium.onnx.json") }

    nonisolated var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.venvPython.path)
            && Self.pythonPackageReady
            && FileManager.default.fileExists(atPath: Self.modelURL.path)
            && FileManager.default.fileExists(atPath: Self.modelConfigURL.path)
    }

    /// venv 里 piper 包是否就绪（bin 目录出现 piper 模块即视为完成）
    nonisolated static var pythonPackageReady: Bool {
        FileManager.default.fileExists(atPath: venvDir.appendingPathComponent("bin/piper").path)
            || FileManager.default.fileExists(atPath: venvDir.appendingPathComponent("lib").path + "/" + pythonLibDir() + "/piper/__init__.py")
    }

    /// lib/pythonX.Y 探测（venv 布局随 Python 版本变化）
    nonisolated private static func pythonLibDir() -> String {
        let lib = venvDir.appendingPathComponent("lib")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: lib.path) {
            if let py = entries.first(where: { $0.hasPrefix("python3.") }) {
                return py
            }
        }
        return "python3.14"
    }

    var isDownloading: Bool { downloadProgress != nil }

    // MARK: - 安装

    func install() async {
        guard !isDownloading else { return }
        lastError = nil
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.piperRoot, withIntermediateDirectories: true)

            // 0. 找系统 python3（Homebrew 或系统自带均可，>=3.9）
            guard let sysPython = Self.locateSystemPython() else {
                throw PiperError.noPython
            }

            // 1. 模型（此前 C++ 方案下载过的直接复用，60MB 不重下）
            if !fm.fileExists(atPath: Self.modelURL.path) {
                statusText = "下载中文语音模型「花言」（60 MB）…"
                downloadProgress = 0.05
                let onnx = try await downloadFile(
                    from: "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx",
                    expectedMB: 60
                )
                try fm.moveItem(at: onnx, to: Self.modelURL)
            }
            if !fm.fileExists(atPath: Self.modelConfigURL.path) {
                statusText = "下载模型配置…"
                downloadProgress = 0.35
                let json = try await downloadFile(
                    from: "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx.json",
                    expectedMB: 0
                )
                try fm.moveItem(at: json, to: Self.modelConfigURL)
            }

            // 2. venv + pip 安装 piper-tts（PyPI macOS arm64 轮子，约 35MB 含 onnxruntime）
            if !FileManager.default.isExecutableFile(atPath: Self.venvPython.path) {
                statusText = "创建 Python 虚拟环境…"
                downloadProgress = 0.45
                try? fm.removeItem(at: Self.venvDir)
                let (out, err, code) = try await runProcess(
                    sysPython, ["-m", "venv", Self.venvDir.path]
                )
                guard code == 0 else { throw PiperError.process("venv 创建失败: \(err.isEmpty ? out : err)") }
            }

            statusText = "安装 Piper 语音引擎（约 35 MB）…"
            downloadProgress = 0.55
            let (out, err, code) = try await runProcess(
                Self.venvPython.path,
                ["-m", "pip", "install", "--quiet", "--disable-pip-version-check", "piper-tts>=1.4.2"]
            )
            guard code == 0 else {
                throw PiperError.process("pip 安装失败: \((err.isEmpty ? out : err).prefix(300))")
            }
            _ = out

            downloadProgress = 1.0
            statusText = "安装完成"
            try? await Task.sleep(nanoseconds: 600_000_000)
            downloadProgress = nil
            statusText = ""
        } catch {
            downloadProgress = nil
            statusText = ""
            lastError = Self.humanMessage(for: error)
        }
    }

    nonisolated static func locateSystemPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    private static func humanMessage(for error: Error) -> String {
        if let piperError = error as? PiperError {
            switch piperError {
            case .noPython:
                return "未找到 python3（需要 3.9+）。可运行 `brew install python` 后重试"
            default: break
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "没有网络连接——安装需要联网一次，之后永久离线"
            case .timedOut: return "下载超时，请重试"
            default: break
            }
        }
        return "安装失败：\(error.localizedDescription)"
    }

    // MARK: - 原语

    private func downloadFile(from urlString: String, expectedMB: Int) async throws -> URL {
        guard let url = URL(string: urlString) else { throw PiperError.badURL }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dreader-piper-\(UUID().uuidString)")
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (asyncBytes, resp) = try await URLSession.shared.bytes(for: request)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PiperError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let expectedBytes = max(1, expectedMB * 1_048_576)
        var data = Data()
        var lastReport = Date()
        for try await byte in asyncBytes {
            data.append(byte)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                downloadProgress = min(0.98, Double(data.count) / Double(expectedBytes))
            }
        }
        try data.write(to: tmp, options: .atomic)
        return tmp
    }

    @discardableResult
    private func runProcess(_ executable: String, _ args: [String]) async throws -> (out: String, err: String, code: Int32) {
        try await Self.runProcess(executable, args)
    }

    nonisolated static func runProcess(_ executable: String, _ args: [String]) async throws -> (out: String, err: String, code: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // venv/pip 不需要继承用户环境，最小环境即可
        proc.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
        try proc.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, proc.terminationStatus)
    }

    enum PiperError: LocalizedError {
        case badURL
        case http(Int)
        case noPython
        case process(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "下载地址无效"
            case .http(let code): return "下载失败（HTTP \(code)）"
            case .noPython: return "未找到系统 python3"
            case .process(let detail): return detail
            }
        }
    }
}
