import Foundation
import AVFoundation

/// Whole-chapter read-aloud (听书) service.
/// 双引擎均为神经网络语音（系统 AVSpeechSynthesizer 已按用户要求移除）：
/// - piper（默认）：本地开源 TTS（KOReader/Home Assistant 同款），首次自动下载 ~80MB 后永久离线
/// - ai：OpenAI 兼容 /v1/audio/speech 在线大模型 TTS（硅基流动 CosyVoice2 等）
@Observable
final class ChapterReadAloudService: NSObject, @unchecked Sendable, AVAudioPlayerDelegate {
    enum PlaybackState: String {
        case idle, playing, paused
    }

    enum Engine: String {
        case piper
        case ai
    }

    private var paragraphs: [(index: Int, firstLine: String)] = []
    private var paragraphIndex: Int = 0
    private var rate: Double = 0.52

    private(set) var state: PlaybackState = .idle
    /// Index of the paragraph currently being read (for UI / follow highlighting)
    private(set) var currentParagraphIndex: Int = 0
    private(set) var currentBookId: UUID?

    /// 当前生效的引擎
    private(set) var activeEngine: Engine = .piper
    /// 引擎最近一次失败原因（nil = 无；失败时自动切到另一引擎）
    private(set) var engineError: String?

    /// AI TTS 音频播放器（每段一个，播完释放）
    private var audioPlayer: AVAudioPlayer?
    /// 预取缓存：段落序列号 → 音频数据（piper 为 wav，ai 为 mp3）
    private var prefetchedAudio: [Int: Data] = [:]
    private var prefetchTask: Task<Void, Never>?
    /// 防止过期回调推进段落（stop/重启后旧事件丢弃）
    private var playbackGeneration = 0

    /// Sleep timer fire date (nil = off). When set, playback pauses at the deadline.
    private(set) var sleepTimerDeadline: Date?
    private var sleepTimerCheck: Timer?

    /// 注入设置读取器（避免服务直接持有 ReaderSettings 引用）
    var settingsProvider: () -> ReaderSettings = { ReaderSettings() }

    var isBusyForBook: (UUID) -> Bool { { [weak self] bookId in
        self?.state != .idle && self?.currentBookId == bookId
    } }

    // MARK: - Control

    /// Starts (or restarts) reading a chapter split into paragraphs.
    func start(bookId: UUID, paragraphs: [String], startIndex: Int = 0, rate: Double = 0.52) {
        stop()
        self.rate = min(max(rate, 0.3), 0.8)
        self.paragraphs = paragraphs.enumerated()
            .filter { $0.element.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
            .map { (index: $0.offset, firstLine: $0.element) }
        self.paragraphIndex = self.paragraphs.firstIndex(where: { $0.index >= startIndex }) ?? 0
        currentBookId = bookId
        guard !self.paragraphs.isEmpty else { return }
        state = .playing
        activeEngine = settingsProvider().readAloudEngine == .ai ? .ai : .piper
        engineError = nil
        speakCurrentParagraph()
    }

    func pause() {
        guard state == .playing else { return }
        audioPlayer?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        audioPlayer?.play()
        state = .playing
    }

    func toggledFrom(_ bookId: UUID) {
        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .idle:
            break // caller should supply chapter paragraphs
        }
    }

    func stop() {
        playbackGeneration += 1
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedAudio.removeAll()
        audioPlayer?.stop()
        audioPlayer = nil
        paragraphs = []
        paragraphIndex = 0
        currentParagraphIndex = 0
        currentBookId = nil
        state = .idle
        cancelSleepTimer()
    }

    /// Reading speed 0...1 → piper length_scale /（AI 引擎暂不支持变速，下一段生效）
    func setRate(_ doubleValue: Double) {
        rate = min(max(doubleValue, 0.3), 0.8)
    }

    // MARK: - Sleep Timer

    func enableSleepTimer(minutes: Int) {
        sleepTimerDeadline = Date().addingTimeInterval(Double(minutes) * 60)
        // Re-start the timer cleanly
        stopSleepTimerInternal()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let deadline = self.sleepTimerDeadline, Date() >= deadline {
                self.pause()
                self.cancelSleepTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimerCheck = timer
    }

    func cancelSleepTimer() {
        sleepTimerDeadline = nil
        stopSleepTimerInternal()
    }

    private func stopSleepTimerInternal() {
        sleepTimerCheck?.invalidate()
        sleepTimerCheck = nil
    }

    // MARK: - Speech Driver

    private func speakCurrentParagraph() {
        guard paragraphIndex < paragraphs.count else {
            // Chapter finished
            stop()
            return
        }
        let entry = paragraphs[paragraphIndex]
        currentParagraphIndex = entry.index
        switch activeEngine {
        case .piper:
            speakWithPiper(entry.firstLine, sequence: paragraphIndex)
        case .ai:
            speakWithAI(entry.firstLine, sequence: paragraphIndex)
        }
    }

    /// 引擎失败：记录原因，切到另一引擎重读当前段（不打断听书体验）
    private func fallback(reason: String, restartWithText: String) {
        engineError = reason
        activeEngine = (activeEngine == .piper) ? .ai : .piper
        guard state == .playing || state == .paused else { return }
        if state == .paused {
            // 暂停状态下失败：记下引擎切换，等恢复时再读
            pendingRestartText = restartWithText
            return
        }
        speakCurrentParagraphForText(restartWithText)
    }

    /// 暂停中失败时暂存的段落文本（恢复播放时先读它）
    private var pendingRestartText: String?

    /// 用指定文本重读（fallback 用；不推进 currentParagraphIndex，段落归属不变）
    private func speakCurrentParagraphForText(_ text: String) {
        switch activeEngine {
        case .piper:
            speakWithPiper(text, sequence: paragraphIndex)
        case .ai:
            speakWithAI(text, sequence: paragraphIndex)
        }
    }

    /// 暂停恢复时如果引擎已切换，需要从暂存文本重读
    func resumeIfNeededAfterEngineSwitch() {
        if let text = pendingRestartText {
            pendingRestartText = nil
            speakCurrentParagraphForText(text)
        }
    }

    // MARK: Piper 本地引擎（进程管道：stdin 文本 → stdout wav）

    private func speakWithPiper(_ text: String, sequence: Int) {
        let generation = playbackGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let audio: Data
                if let cached = self.prefetchedAudio[sequence] {
                    audio = cached
                    self.prefetchedAudio.removeValue(forKey: sequence)
                } else {
                    audio = try await Self.piperSynthesize(text: text, rate: self.rate)
                }
                guard generation == self.playbackGeneration,
                      self.state == .playing || self.state == .paused else { return }
                self.playAudio(audio, sequence: sequence, generation: generation)
                self.prefetchNext(sequence: sequence + 1)
            } catch {
                guard generation == self.playbackGeneration else { return }
                self.fallback(reason: "Piper：\(error.localizedDescription)", restartWithText: text)
            }
        }
    }

    /// 经 PiperBridge（常驻 venv Python 进程）合成一段 wav。
    /// length_scale 越小语速越快（rate 0.3~0.8 → 1.63~0.68）。
    static func piperSynthesize(text: String, rate: Double) async throws -> Data {
        guard piperFilesPresent() else {
            throw ReadAloudError.piperNotInstalled
        }
        let lengthScale = 2.2 - rate * 1.9 // 0.3→1.63, 0.52→1.21, 0.8→0.68
        let data = try await PiperBridge.shared.synthesize(text: text, lengthScale: lengthScale)
        guard !data.isEmpty else { throw ReadAloudError.emptyResponse }
        return data
    }

    nonisolated private static func piperFilesPresent() -> Bool {
        FileManager.default.fileExists(atPath: PiperInstaller.modelURL.path)
            && FileManager.default.isExecutableFile(atPath: PiperInstaller.venvPython.path)
            && PiperInstaller.pythonPackageReady
    }

    // MARK: AI 在线引擎（OpenAI 兼容 /v1/audio/speech）

    private func speakWithAI(_ text: String, sequence: Int) {
        let generation = playbackGeneration
        let settings = settingsProvider()
        Task { [weak self] in
            guard let self else { return }
            do {
                let audio: Data
                if let cached = self.prefetchedAudio[sequence] {
                    audio = cached
                    self.prefetchedAudio.removeValue(forKey: sequence)
                } else {
                    audio = try await Self.synthesize(text: text, settings: settings)
                }
                guard generation == self.playbackGeneration,
                      self.state == .playing || self.state == .paused else { return }
                self.playAudio(audio, sequence: sequence, generation: generation)
                self.prefetchNext(sequence: sequence + 1)
            } catch {
                guard generation == self.playbackGeneration else { return }
                self.fallback(reason: "AI 语音：\(error.localizedDescription)", restartWithText: text)
            }
        }
    }

    /// 预取下一段（只预取一段，piper 本地无成本、AI 控制 API 用量）
    private func prefetchNext(sequence: Int) {
        guard sequence < paragraphs.count, prefetchedAudio[sequence] == nil else { return }
        let text = paragraphs[sequence].firstLine
        let generation = playbackGeneration
        let engine = activeEngine
        let rate = self.rate
        let settings = settingsProvider()
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            let data: Data?
            switch engine {
            case .piper:
                data = try? await Self.piperSynthesize(text: text, rate: rate)
            case .ai:
                data = try? await Self.synthesize(text: text, settings: settings)
            }
            if let data {
                guard let self, generation == self.playbackGeneration else { return }
                self.prefetchedAudio[sequence] = data
            }
        }
    }

    private func playAudio(_ data: Data, sequence: Int, generation: Int) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.rate = 1.0
            audioPlayer = player
            player.play()
        } catch {
            fallback(reason: "音频播放失败：\(error.localizedDescription)", restartWithText: paragraphs[sequence].firstLine)
        }
    }

    static func synthesize(text: String, settings: ReaderSettings) async throws -> Data {
        guard !settings.aiTTSAPIKey.isEmpty else { throw ReadAloudError.missingKey }
        guard let base = URL(string: settings.aiTTSEndpoint) else { throw ReadAloudError.badEndpoint }
        let speechURL = base.appendingPathComponent("audio/speech")
        var request = URLRequest(url: speechURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(settings.aiTTSAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": settings.aiTTSModel,
            "input": text,
            "voice": settings.aiTTSVoice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw ReadAloudError.network }
        guard (200..<300).contains(http.statusCode) else {
            // 只暴露状态码不暴露响应体（可能含敏感信息）
            throw ReadAloudError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw ReadAloudError.emptyResponse }
        return data
    }

    // MARK: - AVAudioPlayerDelegate（段落播完 → 下一段）

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard state == .playing else { return }
        paragraphIndex += 1
        if paragraphIndex < paragraphs.count {
            speakCurrentParagraph()
        } else {
            stop()
        }
    }
}

/// 听书引擎共享错误（PiperBridge 也用）
enum ReadAloudError: LocalizedError {
    case missingKey
    case badEndpoint
    case network
    case http(Int)
    case emptyResponse
    case piperNotInstalled
    case piperFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "未配置 AI 语音 API Key"
        case .badEndpoint: return "TTS 端点地址无效"
        case .network: return "网络错误"
        case .http(let code): return "TTS 服务返回 HTTP \(code)"
        case .emptyResponse: return "TTS 服务返回空音频"
        case .piperNotInstalled: return "Piper 引擎未安装"
        case .piperFailed(let detail): return "Piper 合成失败 \(detail.prefix(160))"
        }
    }
}
