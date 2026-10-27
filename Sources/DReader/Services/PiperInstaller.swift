import Foundation

/// Piper 本地神经网络 TTS 的安装器：首次使用自动下载 piper 二进制（官方 macOS 构建）
/// 与中文「花言」语音模型（HuggingFace rhasspy/piper-voices），存于应用支持目录，永久离线可用。
/// Piper 是 KOReader / Home Assistant 的默认开源 TTS 引擎，CPU 实时合成，完全免费。
@MainActor
final class PiperInstaller: ObservableObject {
    static let shared = PiperInstaller()

    @Published var downloadProgress: Double? = nil // nil = 未在下载
    @Published var statusText: String = ""
    @Published var lastError: String? = nil

    // MARK: - 路径（nonisolated：合成在后台线程读路径）

    nonisolated static var piperRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("DReader/Piper", isDirectory: true)
    }

    /// 官方 tarball 解压后的目录（含 piper 可执行与 espeak-ng-data）
    nonisolated static var piperBinDir: URL { piperRoot.appendingPathComponent("piper", isDirectory: true) }
    nonisolated static var piperBinary: URL { piperBinDir.appendingPathComponent("piper") }
    nonisolated static var modelURL: URL { piperRoot.appendingPathComponent("zh_CN-huayan-medium.onnx") }
    nonisolated static var modelConfigURL: URL { piperRoot.appendingPathComponent("zh_CN-huayan-medium.onnx.json") }

    nonisolated var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.piperBinary.path)
            && FileManager.default.fileExists(atPath: Self.modelURL.path)
            && FileManager.default.fileExists(atPath: Self.modelConfigURL.path)
    }

    var isDownloading: Bool { downloadProgress != nil }

    // MARK: - 下载源

    private static let binaryURL = "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_macos_aarch64.tar.gz"
    private static let modelBase = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/zh/zh_CN/huayan/medium"

    // MARK: - 安装

    func install() async {
        guard !isDownloading else { return }
        lastError = nil
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.piperRoot, withIntermediateDirectories: true)

            // 1. piper 二进制（含 espeak-ng-data）
            if !FileManager.default.isExecutableFile(atPath: Self.piperBinary.path) {
                statusText = "下载 Piper 引擎（18 MB）…"
                downloadProgress = 0.02
                let tarball = try await downloadFile(from: Self.binaryURL, expectedMB: 18)
                statusText = "解压 Piper 引擎…"
                downloadProgress = 0.35
                try await extractTarGz(at: tarball, to: Self.piperRoot)
                try? fm.removeItem(at: tarball)
                // 确保可执行位（tar 保留权限但保险起见）
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.piperBinary.path)
            }

            // 2. 花言语音模型 + 配置
            if !fm.fileExists(atPath: Self.modelURL.path) {
                statusText = "下载中文语音模型「花言」（63 MB）…"
                downloadProgress = 0.4
                let onnx = try await downloadFile(from: "\(Self.modelBase)/zh_CN-huayan-medium.onnx", expectedMB: 63)
                try fm.moveItem(at: onnx, to: Self.modelURL)
            }
            if !fm.fileExists(atPath: Self.modelConfigURL.path) {
                statusText = "下载模型配置…"
                downloadProgress = 0.95
                let json = try await downloadFile(from: "\(Self.modelBase)/zh_CN-huayan-medium.onnx.json", expectedMB: 0)
                try fm.moveItem(at: json, to: Self.modelConfigURL)
            }

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

    private static func humanMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "没有网络连接——Piper 安装需要联网一次，之后永久离线"
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

    /// macOS 自带 /usr/bin/tar 解压（Process 调用，避免引入压缩库依赖）
    private func extractTarGz(at archive: URL, to destination: URL) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", archive.path, "-C", destination.path]
        let pipe = Pipe()
        proc.standardError = pipe
        try proc.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }
        guard proc.terminationStatus == 0 else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw PiperError.extract(msg)
        }
    }

    enum PiperError: LocalizedError {
        case badURL
        case http(Int)
        case extract(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "下载地址无效"
            case .http(let code): return "下载失败（HTTP \(code)）"
            case .extract(let detail): return "解压失败：\(detail)"
            }
        }
    }
}
