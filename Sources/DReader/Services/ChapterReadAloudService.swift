import Foundation
import AVFoundation

/// Whole-chapter read-aloud (听书) service.
/// Queues chapter paragraphs one by one, reports progress, and supports a soft sleep timer.
/// 双引擎：macOS 系统语音（自动选 Premium/增强档，离线）或 OpenAI 兼容 TTS 大模型（拟人，逐段合成+预取，失败回退系统语音）。
@Observable
final class ChapterReadAloudService: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    enum PlaybackState: String {
        case idle, playing, paused
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var paragraphs: [(index: Int, firstLine: String)] = []
    private var paragraphIndex: Int = 0
    private var rate: Double = 0.52

    private(set) var state: PlaybackState = .idle
    /// Index of the paragraph currently being read (for UI / follow highlighting)
    private(set) var currentParagraphIndex: Int = 0
    private(set) var currentBookId: UUID?

    /// 当前生效的引擎（AI 请求失败会回退 system，UI 提示用）
    private(set) var activeEngine: ReaderSettings.ReadAloudEngine = .system
    /// AI 引擎最近一次失败原因（nil = 无）
    private(set) var aiEngineError: String?

    /// AI TTS 音频播放器（每段一个，播完释放）
    private var audioPlayer: AVAudioPlayer?
    /// 预取缓存：段落序列号 → 音频数据
    private var prefetchedAudio: [Int: Data] = [:]
    private var prefetchTask: Task<Void, Never>?
    /// 防止过期回调推进段落（stop/重启后旧 delegate 事件丢弃）
    private var playbackGeneration = 0

    /// Sleep timer fire date (nil = off). When set, playback pauses at the deadline.
    private(set) var sleepTimerDeadline: Date?
    private var sleepTimerCheck: Timer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

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
        let settings = settingsProvider()
        activeEngine = settings.readAloudEngine
        aiEngineError = nil
        speakCurrentParagraph()
    }

    func pause() {
        guard state == .playing else { return }
        switch activeEngine {
        case .system:
            synthesizer.pauseSpeaking(at: .word)
        case .ai:
            audioPlayer?.pause()
        }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        switch activeEngine {
        case .system:
            synthesizer.continueSpeaking()
        case .ai:
            audioPlayer?.play()
        }
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
        synthesizer.stopSpeaking(at: .immediate)
        paragraphs = []
        paragraphIndex = 0
        currentParagraphIndex = 0
        currentBookId = nil
        state = .idle
        cancelSleepTimer()
    }

    /// Reading speed 0...1 → AV rate 0.35...0.72
    func setRate(_ doubleValue: Double) {
        rate = min(max(doubleValue, 0.3), 0.8)
        // Re-apply on next utterance; live utterances keep their intrinsic rate
    }

    /// 注入设置读取器（避免服务直接持有 ReaderSettings 引用）
    var settingsProvider: () -> ReaderSettings = { ReaderSettings() }

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
        case .system:
            speakWithSystem(entry.firstLine)
        case .ai:
            speakWithAI(entry.firstLine, sequence: paragraphIndex)
        }
    }

    // MARK: 系统语音：自动挑最高质量中文语音（Premium/增强 > 默认）

    /// 缓存挑选结果（语音列表不常变）；锁+盒子规避 Swift 6 全局可变状态检查
    private static let voiceCacheLock = NSLock()
    private static let voiceCacheBox = VoiceCacheBox()

    private final class VoiceCacheBox: @unchecked Sendable {
        var voice: AVSpeechSynthesisVoice?
    }

    static func bestChineseVoice() -> AVSpeechSynthesisVoice? {
        voiceCacheLock.lock()
        if let cached = voiceCacheBox.voice {
            voiceCacheLock.unlock()
            return cached
        }
        voiceCacheLock.unlock()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("zh")
        }
        guard !candidates.isEmpty else { return nil }
        // quality: default=1 < enhanced=2 < premium=3；同档优先 zh-CN，再按名称偏好好听的
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var score = v.quality.rawValue * 100
            if v.language.hasPrefix("zh-CN") { score += 20 }
            // Apple 内置增强女声口碑普遍好于方言/男声兜底
            let niceNames = ["Tingting", "婷婷", "Meijia", "Sinji", "Yue"]
            if niceNames.contains(where: { v.name.contains($0) }) { score += 10 }
            return score
        }
        let best = candidates.max(by: { rank($0) < rank($1) })
        voiceCacheLock.lock()
        voiceCacheBox.voice = best
        voiceCacheLock.unlock()
        return best
    }

    private func speakWithSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(rate)
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.4
        let settings = settingsProvider()
        if let identifier = settings.systemVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else if let best = Self.bestChineseVoice() {
            utterance.voice = best
        } else if let voice = AVSpeechSynthesisVoice(language: "zh-CN") ?? AVSpeechSynthesisVoice(language: "zh-TW") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    // MARK: AI 大模型 TTS（OpenAI 兼容 /v1/audio/speech）

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
                // 会话已作废（stop/切换引擎）则丢弃
                guard generation == self.playbackGeneration, self.state == .playing || self.state == .paused else { return }
                self.playAIAudio(audio, sequence: sequence, generation: generation)
                self.prefetchNext(sequence: sequence + 1)
            } catch {
                // 会话已作废：静默丢弃
                guard generation == self.playbackGeneration else { return }
                self.fallbackToSystem(reason: error.localizedDescription, restartWithText: text)
            }
        }
    }

    /// 预取下一段（只预取一段，控制 API 用量）
    private func prefetchNext(sequence: Int) {
        guard sequence < paragraphs.count, prefetchedAudio[sequence] == nil else { return }
        let text = paragraphs[sequence].firstLine
        let settings = settingsProvider()
        let generation = playbackGeneration
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            if let data = try? await Self.synthesize(text: text, settings: settings) {
                guard let self, generation == self.playbackGeneration else { return }
                self.prefetchedAudio[sequence] = data
            }
        }
    }

    private func playAIAudio(_ data: Data, sequence: Int, generation: Int) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.rate = 1.0
            audioPlayer = player
            player.play()
        } catch {
            fallbackToSystem(reason: "音频播放失败：\(error.localizedDescription)", restartWithText: paragraphs[sequence].firstLine)
        }
    }

    /// AI 引擎失败：记录原因，本段起回退系统语音继续朗读（不打断听书体验）
    private func fallbackToSystem(reason: String, restartWithText: String) {
        aiEngineError = reason
        activeEngine = .system
        guard state == .playing else { return }
        speakWithSystem(restartWithText)
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

    enum ReadAloudError: LocalizedError {
        case missingKey
        case badEndpoint
        case network
        case http(Int)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: return "未配置 AI 语音 API Key"
            case .badEndpoint: return "TTS 端点地址无效"
            case .network: return "网络错误"
            case .http(let code): return "TTS 服务返回 HTTP \(code)"
            case .emptyResponse: return "TTS 服务返回空音频"
            }
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Pause-interrupted utterances resume on their own; only advance while playing
        guard state == .playing else { return }
        paragraphIndex += 1
        if paragraphIndex < paragraphs.count {
            speakCurrentParagraph()
        } else {
            stop()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // no-op; stop() handles cleanup
    }

    // MARK: - AVAudioPlayerDelegate（AI 引擎段落播完 → 下一段）

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard state == .playing, activeEngine == .ai else { return }
        paragraphIndex += 1
        if paragraphIndex < paragraphs.count {
            speakCurrentParagraph()
        } else {
            stop()
        }
    }
}
