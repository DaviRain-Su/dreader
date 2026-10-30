import AVFoundation
import Foundation
import XCTest
@testable import DReader

@MainActor
final class QwenRealEngineTests: XCTestCase {
    func testPersistentQwenGeneratesBothVoicesAndRestartsAfterCancellation() async throws {
        guard ProcessInfo.processInfo.environment["DREADER_QWEN_REAL_TEST"] == "1" else {
            throw XCTSkip("仅在显式真实模型验收时运行")
        }
        XCTAssertEqual(QwenInstallation.status(), .ready)
        try QwenInstallation.validateModel(at: QwenInstallation.modelDirectory)
        let worker = QwenWorker.shared
        defer { worker.shutdown() }
        var reports: [[String: Any]] = []

        for voice in [ReaderSettings.QwenVoice.serena, .uncleFu] {
            for index in 1...2 {
                let started = Date()
                let audio = try await worker.synthesize(
                    text: index == 1 ? "今天我们一起读一小段文字。" : "这是连续播放的第二段。",
                    voice: voice
                )
                let elapsed = Date().timeIntervalSince(started)
                let player = try AVAudioPlayer(data: audio)
                XCTAssertEqual(player.format.sampleRate, 24000)
                XCTAssertEqual(player.format.channelCount, 1)
                XCTAssertGreaterThan(player.duration, 0.1)
                XCTAssertTrue(player.play())
                XCTAssertTrue(player.isPlaying)
                player.pause()
                XCTAssertFalse(player.isPlaying)
                player.stop()
                let url = URL(fileURLWithPath: "/Users/davirian/dreader/.build/tts-evaluation-20261030/production-\(voice.backendName)-\(index).wav")
                try audio.write(to: url, options: .atomic)
                reports.append([
                    "voice": voice.backendName, "chunk": index,
                    "synthesisSeconds": elapsed, "audioSeconds": player.duration,
                    "file": url.path,
                ])
            }
        }

        let cancelled = Task {
            try await worker.synthesize(
                text: String(repeating: "这一段用于验证停止时不会留下无法取消的合成任务。", count: 8),
                voice: .serena
            )
        }
        try await Task.sleep(for: .milliseconds(80))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("长时间合成应可被取消")
        } catch { /* 取消和进程结束都属于本测试预期 */ }
        worker.shutdown()
        let restarted = try await worker.synthesize(text: "取消以后可以重新开始。", voice: .serena)
        let player = try AVAudioPlayer(data: restarted)
        XCTAssertGreaterThan(player.duration, 0.1)

        let reportURL = URL(fileURLWithPath: "/Users/davirian/dreader/.build/tts-evaluation-20261030/Qwen生产验证.json")
        try JSONSerialization.data(withJSONObject: [
            "installation": QwenInstallation.root.path,
            "modelHashVerified": true,
            "voices": reports,
            "cancelAndRestart": true,
        ], options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
    }

    func testDefaultReadAloudServiceUsesPersistentQwenForConsecutiveChunks() async throws {
        guard ProcessInfo.processInfo.environment["DREADER_QWEN_REAL_TEST"] == "1" else {
            throw XCTSkip("仅在显式真实模型验收时运行")
        }
        var audio: [Data] = []
        var completions: [ChapterReadAloudService.PlaybackCompletion] = []
        let service = ChapterReadAloudService(makePlayback: { data, completion in
            audio.append(data)
            completions.append(completion)
            return ChapterReadAloudService.Playback(play: { true }, pause: {}, stop: {})
        })
        service.settingsProvider = { ReaderSettings() }
        defer {
            service.stop()
            QwenWorker.shared.shutdown()
        }
        service.start(bookId: UUID(), segments: [
            .init(id: 1, text: "默认听书服务的第一段。"),
            .init(id: 2, text: "默认听书服务的第二段。"),
        ])
        let deadline = Date().addingTimeInterval(90)
        while audio.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(service.activeEngine, .qwen)
        XCTAssertEqual(String(decoding: audio[0].prefix(4), as: UTF8.self), "RIFF")
        completions[0](true)
        while audio.count < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(service.currentSegmentID, 2)
        XCTAssertEqual(service.activeEngine, .qwen)
        XCTAssertEqual(String(decoding: audio[1].prefix(4), as: UTF8.self), "RIFF")
    }
}
