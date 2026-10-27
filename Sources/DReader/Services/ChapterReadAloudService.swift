import Foundation
import AVFoundation

/// Whole-chapter read-aloud (听书) service.
/// Queues chapter paragraphs one by one, reports progress, and supports a soft sleep timer.
@Observable
final class ChapterReadAloudService: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
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
        speakCurrentParagraph()
    }

    func pause() {
        guard state == .playing else { return }
        synthesizer.pauseSpeaking(at: .word)
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        synthesizer.continueSpeaking()
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
        let utterance = AVSpeechUtterance(string: entry.firstLine)
        utterance.rate = Float(rate)
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.4
        //Voice selection: prefer zh-TW-compatible default Chinese voice
        if let voice = AVSpeechSynthesisVoice(language: "zh-CN") ?? AVSpeechSynthesisVoice(language: "zh-TW") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
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
}
