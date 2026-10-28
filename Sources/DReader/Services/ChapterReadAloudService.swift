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

    enum Engine: String, Hashable, Sendable {
        case piper
        case ai

        var alternate: Engine { self == .piper ? .ai : .piper }
        var displayName: String { self == .piper ? "Piper" : "AI 语音" }
    }

    /// 轻量播放接口；测试可替换为纯内存播放器，不打开音频设备。
    struct Playback {
        let play: () -> Bool
        let pause: () -> Void
        let stop: () -> Void
    }

    typealias Synthesis = @Sendable (Engine, String, Double) async throws -> Data
    typealias PlaybackCompletion = @Sendable (Bool) -> Void
    typealias PlaybackFactory = (Data, @escaping PlaybackCompletion) throws -> Playback

    private struct Attempt: Hashable {
        let sequence: Int
        let engine: Engine
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
    /// 当前段的失败原因；双引擎耗尽后停止并保留，供 UI 显示。
    private(set) var engineError: String?

    private var audioPlayer: AVAudioPlayer?
    private var playback: Playback?
    private var playbackCompletion: PlaybackCompletion?
    private var playbackID: UUID?
    /// 同段/同引擎只有一个任务，预取与前台共用成功或失败的结果。
    private var synthesisTasks: [Attempt: Task<Data, Error>] = [:]
    private var failedAttempts: [Attempt: String] = [:]
    private var speechTask: Task<Void, Never>?
    private var currentAttempt: Attempt?
    /// stop/重启后，合成结果与播放器回调均须匹配本代次。
    private var playbackGeneration = 0

    private let preferredEngine: Engine?
    private let synthesisOverride: Synthesis?
    private let playbackFactory: PlaybackFactory?

    /// Sleep timer fire date (nil = off). When set, playback pauses at the deadline.
    private(set) var sleepTimerDeadline: Date?
    private var sleepTimerCheck: Timer?

    /// 注入设置读取器（避免服务直接持有 ReaderSettings 引用）
    var settingsProvider: () -> ReaderSettings = { ReaderSettings() }

    /// 默认仍使用真实引擎/播放器；注入时无需读取凭据或打开音频设备。
    init(preferredEngine: Engine? = nil, synthesizeAudio: Synthesis? = nil,
         makePlayback: PlaybackFactory? = nil) {
        self.preferredEngine = preferredEngine
        self.synthesisOverride = synthesizeAudio
        self.playbackFactory = makePlayback
        super.init()
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
        guard !self.paragraphs.isEmpty else { return }
        currentBookId = bookId
        state = .playing
        activeEngine = preferredEngine ?? (settingsProvider().readAloudEngine == .ai ? .ai : .piper)
        speakCurrentParagraph()
    }

    func pause() {
        guard state == .playing else { return }
        state = .paused
        playback?.pause()
    }

    func resume() {
        guard state == .paused else { return }
        state = .playing
        if let playback {
            if !playback.play() {
                fallback(reason: "音频播放失败", attempt: Attempt(sequence: paragraphIndex, engine: activeEngine),
                         generation: playbackGeneration)
            }
        } else {
            // 暂停中合成完成或回退时，复用已有任务/结果，不重复消耗尝试次数。
            speakCurrentParagraph()
        }
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
        speechTask?.cancel()
        speechTask = nil
        currentAttempt = nil
        synthesisTasks.values.forEach { $0.cancel() }
        synthesisTasks.removeAll()
        failedAttempts.removeAll()
        clearPlayback()
        paragraphs = []
        paragraphIndex = 0
        currentParagraphIndex = 0
        currentBookId = nil
        state = .idle
        engineError = nil
        cancelSleepTimer()
    }

    /// Reading speed 0...1 → piper length_scale /（AI 引擎暂不支持变速，下一段生效）
    func setRate(_ doubleValue: Double) {
        rate = min(max(doubleValue, 0.3), 0.8)
    }

    // MARK: - Sleep Timer

    func enableSleepTimer(minutes: Int) {
        sleepTimerDeadline = Date().addingTimeInterval(Double(minutes) * 60)
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

    private func isCurrent(_ attempt: Attempt, generation: Int) -> Bool {
        generation == playbackGeneration && attempt.sequence == paragraphIndex
            && attempt.engine == activeEngine && (state == .playing || state == .paused)
    }

    private func speakCurrentParagraph() {
        guard state == .playing, playback == nil else { return }
        guard paragraphIndex < paragraphs.count else {
            stop()
            return
        }
        let entry = paragraphs[paragraphIndex]
        currentParagraphIndex = entry.index
        let attempt = Attempt(sequence: paragraphIndex, engine: activeEngine)
        guard currentAttempt != attempt else { return }
        // 已经失败的音频缓存/任务不能在恢复播放时绕过引擎上限。
        guard failedAttempts[attempt] == nil else { return }
        let generation = playbackGeneration
        let synthesis = synthesisTask(for: attempt)
        currentAttempt = attempt
        speechTask = Task { @MainActor [weak self] in
            do {
                let audio = try await synthesis.value
                guard !Task.isCancelled, let self,
                      self.isCurrent(attempt, generation: generation), self.currentAttempt == attempt else { return }
                self.speechTask = nil
                self.currentAttempt = nil
                // 保留任务中的音频，resume 后才创建/启动播放器。
                guard self.state == .playing else { return }
                self.playAudio(audio, attempt: attempt, generation: generation)
            } catch {
                guard !Task.isCancelled, let self,
                      self.isCurrent(attempt, generation: generation), self.currentAttempt == attempt else { return }
                self.speechTask = nil
                self.currentAttempt = nil
                self.fallback(reason: error.localizedDescription, attempt: attempt, generation: generation)
            }
        }
    }

    /// 预取失败也属于一次尝试：任务结果保留到该段前台消费，避免自动重试。
    private func synthesisTask(for attempt: Attempt) -> Task<Data, Error> {
        if let task = synthesisTasks[attempt] { return task }
        let text = paragraphs[attempt.sequence].firstLine
        let rate = self.rate
        let synthesizeAudio: Synthesis
        if let synthesisOverride {
            synthesizeAudio = synthesisOverride
        } else {
            let settings = settingsProvider()
            synthesizeAudio = { engine, text, rate in
                switch engine {
                case .piper: return try await Self.piperSynthesize(text: text, rate: rate)
                case .ai: return try await Self.synthesize(text: text, settings: settings)
                }
            }
        }
        let task = Task {
            try Task.checkCancellation()
            let audio = try await synthesizeAudio(attempt.engine, text, rate)
            try Task.checkCancellation()
            guard !audio.isEmpty else { throw ReadAloudError.emptyResponse }
            return audio
        }
        synthesisTasks[attempt] = task
        return task
    }

    /// 每个会话内，同一段每个引擎最多一次；双失败进入 idle，保留原因。
    private func fallback(reason: String, attempt: Attempt, generation: Int) {
        guard isCurrent(attempt, generation: generation), failedAttempts[attempt] == nil else { return }
        clearPlayback()
        failedAttempts[attempt] = "\(attempt.engine.displayName)：\(reason)"
        engineError = [Engine.piper, .ai].compactMap {
            failedAttempts[Attempt(sequence: attempt.sequence, engine: $0)]
        }.joined(separator: "；")
        let alternate = Attempt(sequence: attempt.sequence, engine: attempt.engine.alternate)
        guard failedAttempts[alternate] == nil else {
            let finalError = engineError
            stop()
            engineError = finalError
            return
        }
        activeEngine = alternate.engine
        // paused 时只切换记录；resume 统一驱动下一次尝试。
        speakCurrentParagraph()
    }

    /// 保留旧调用入口；resume 本身已处理暂停中的引擎切换。
    func resumeIfNeededAfterEngineSwitch() {
        speakCurrentParagraph()
    }

    private func prefetchNext(sequence: Int) {
        guard sequence < paragraphs.count else { return }
        _ = synthesisTask(for: Attempt(sequence: sequence, engine: activeEngine))
    }

    private func playAudio(_ data: Data, attempt: Attempt, generation: Int) {
        guard isCurrent(attempt, generation: generation), state == .playing else { return }
        let id = UUID()
        playbackID = id
        let completion: PlaybackCompletion = { [weak self] success in
            Task { @MainActor [weak self] in
                self?.playbackFinished(successfully: success, attempt: attempt, generation: generation, id: id)
            }
        }
        do {
            let player: Playback
            if let playbackFactory {
                player = try playbackFactory(data, completion)
            } else {
                let nativePlayer = try AVAudioPlayer(data: data)
                nativePlayer.delegate = self
                nativePlayer.rate = 1.0
                audioPlayer = nativePlayer
                playbackCompletion = completion
                player = Playback(play: { nativePlayer.play() }, pause: { nativePlayer.pause() },
                                  stop: { nativePlayer.stop() })
            }
            playback = player
            guard player.play() else { throw ReadAloudError.playbackFailed }
            prefetchNext(sequence: attempt.sequence + 1)
        } catch {
            fallback(reason: "音频播放失败：\(error.localizedDescription)", attempt: attempt, generation: generation)
        }
    }

    private func clearPlayback() {
        playbackID = nil
        playbackCompletion = nil
        playback?.stop()
        playback = nil
        audioPlayer = nil
    }

    private func playbackFinished(successfully: Bool, attempt: Attempt, generation: Int, id: UUID) {
        guard isCurrent(attempt, generation: generation), playbackID == id else { return }
        if !successfully {
            fallback(reason: "音频播放失败", attempt: attempt, generation: generation)
            return
        }
        clearPlayback()
        // 真正播完再重置本段预算，下一段可重新尝试两个引擎。
        synthesisTasks = synthesisTasks.filter { $0.key.sequence > attempt.sequence }
        failedAttempts.removeAll()
        engineError = nil
        paragraphIndex += 1
        if paragraphIndex < paragraphs.count {
            speakCurrentParagraph()
        } else {
            stop()
        }
    }

    // MARK: Piper 本地引擎（进程管道：stdin 文本 → stdout wav）

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

    // MARK: - AVAudioPlayerDelegate（只接收当前播放器的事件）

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard audioPlayer === player else { return }
        playbackCompletion?(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard audioPlayer === player else { return }
        playbackCompletion?(false)
    }
}

/// 听书引擎共享错误（PiperBridge 也用）
enum ReadAloudError: LocalizedError {
    case missingKey
    case badEndpoint
    case network
    case http(Int)
    case emptyResponse
    case playbackFailed
    case piperNotInstalled
    case piperFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "未配置 AI 语音 API Key"
        case .badEndpoint: return "TTS 端点地址无效"
        case .network: return "网络错误"
        case .http(let code): return "TTS 服务返回 HTTP \(code)"
        case .emptyResponse: return "TTS 服务返回空音频"
        case .playbackFailed: return "播放器无法开始播放"
        case .piperNotInstalled: return "Piper 引擎未安装"
        case .piperFailed(let detail): return "Piper 合成失败 \(detail.prefix(160))"
        }
    }
}
