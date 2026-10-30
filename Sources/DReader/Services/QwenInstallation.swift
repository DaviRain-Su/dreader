import Foundation
import CryptoKit

/// Qwen 的持久安装边界。生产代码不读取 .build 中的模型或试听 venv。
enum QwenInstallation {
    static let revision = "1c6c0ff58c43afa8df571facde2efa077efd85e2"
    static let backendVersion = "0.6.3"
    static let expectedBytes = 2_696_100_432

    static let requiredFiles: Set<String> = [
        ".gitattributes", "README.md", "config.json", "generation_config.json",
        "merges.txt", "model.safetensors", "model.safetensors.index.json",
        "preprocessor_config.json", "speech_tokenizer/config.json",
        "speech_tokenizer/configuration.json", "speech_tokenizer/model.safetensors",
        "speech_tokenizer/preprocessor_config.json", "tokenizer_config.json", "vocab.json",
    ]
    static let weightHashes = [
        "model.safetensors": "097b66a8c63570b88abc2fb393d1dc2360394ca7741c818455ba9da257ac2f3b",
        "speech_tokenizer/model.safetensors": "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258",
    ]

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DReader/Qwen", isDirectory: true)
    }
    static var modelDirectory: URL { root.appendingPathComponent("model", isDirectory: true) }
    static var venvDirectory: URL { root.appendingPathComponent("venv", isDirectory: true) }
    static var pythonURL: URL { venvDirectory.appendingPathComponent("bin/python3") }
    static var workerScriptURL: URL { root.appendingPathComponent("qwen_worker.py") }
    static var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }
    static var homeDirectory: URL { root.appendingPathComponent("home", isDirectory: true) }
    static var temporaryDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    enum Status: String, Sendable {
        case missingModel = "未找到 Qwen 模型"
        case missingRuntime = "未找到 Qwen 独立后端"
        case ready = "Qwen 安装文件已就绪"
    }

    enum InstallationError: LocalizedError {
        case invalidFiles(String)
        case invalidHash(String)
        case invalidBackend

        var errorDescription: String? {
            switch self {
            case .invalidFiles(let detail): return "Qwen 模型文件不完整：\(detail)"
            case .invalidHash(let file): return "Qwen 权重哈希校验失败：\(file)"
            case .invalidBackend: return "Qwen 后端不可用，需要 mlx-audio \(QwenInstallation.backendVersion)"
            }
        }
    }

    static func status(python: URL = pythonURL) -> Status {
        let fm = FileManager.default
        guard requiredFiles.allSatisfy({ fm.fileExists(atPath: modelDirectory.appendingPathComponent($0).path) }) else {
            return .missingModel
        }
        guard fm.isExecutableFile(atPath: python.path),
              fm.fileExists(atPath: venvDirectory.appendingPathComponent("lib/python3.12/site-packages/mlx_audio/tts/utils.py").path) else {
            return .missingRuntime
        }
        return .ready
    }

    static func validateModel(at directory: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw InstallationError.invalidFiles("无法读取模型目录")
        }
        var files: [String: URL] = [:]
        var total = 0
        let rootPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            let relative = url.path.dropFirst(rootPath.count + 1)
            guard !relative.starts(with: ".cache/") else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  url.resolvingSymlinksInPath().path.hasPrefix(rootPath + "/") else {
                throw InstallationError.invalidFiles("包含符号链接或越界路径")
            }
            files[String(relative)] = url
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        guard Set(files.keys) == requiredFiles, total == expectedBytes else {
            throw InstallationError.invalidFiles("文件集合或总字节不符")
        }
        for (name, expected) in weightHashes {
            guard let url = files[name], try sha256(of: url) == expected else {
                throw InstallationError.invalidHash(name)
            }
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
