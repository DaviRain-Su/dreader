import Foundation
import XCTest
@testable import DReader

@MainActor
final class ReadAloudRegressionTests: XCTestCase {
    private typealias Engine = ChapterReadAloudService.Engine

    private struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 故意不响应取消，让测试能交付 stop/start 之前的过期结果。
    private actor Synthesizer {
        struct Request: Sendable {
            let id: Int
            let engine: Engine
            let text: String
        }

        private var requests: [Request] = []
        private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

        func synthesize(engine: Engine, text: String) async throws -> Data {
            let id = requests.count
            requests.append(Request(id: id, engine: engine, text: text))
            return try await withCheckedThrowingContinuation { pending[id] = $0 }
        }

        func allRequests() -> [Request] { requests }

        func succeed(_ id: Int, audio: Data = Data("fixture audio".utf8)) {
            pending.removeValue(forKey: id)?.resume(returning: audio)
        }

        func fail(_ id: Int, message: String = "fixture failure") {
            pending.removeValue(forKey: id)?.resume(throwing: FixtureError(message: message))
        }

        func cancelAll() {
            let continuations = Array(pending.values)
            pending.removeAll()
            continuations.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    private final class Player: @unchecked Sendable {
        private(set) var playCount = 0
        private(set) var pauseCount = 0
        private(set) var stopCount = 0
        let completion: ChapterReadAloudService.PlaybackCompletion

        init(completion: @escaping ChapterReadAloudService.PlaybackCompletion) {
            self.completion = completion
        }

        var playback: ChapterReadAloudService.Playback {
            ChapterReadAloudService.Playback(
                play: { self.playCount += 1; return true },
                pause: { self.pauseCount += 1 },
                stop: { self.stopCount += 1 })
        }

        func finish(successfully: Bool = true) { completion(successfully) }
    }

    private final class Players {
        var players: [Player] = []
        var failCreation = false

        func make(_ data: Data, completion: @escaping ChapterReadAloudService.PlaybackCompletion) throws -> ChapterReadAloudService.Playback {
            if failCreation { throw FixtureError(message: "fixture decode failure") }
            let player = Player(completion: completion)
            players.append(player)
            return player.playback
        }
    }

    private func makeService(_ synth: Synthesizer, players: Players, engine: Engine = .piper) -> ChapterReadAloudService {
        addTeardownBlock { await synth.cancelAll() }
        return ChapterReadAloudService(preferredEngine: engine, synthesizeAudio: { engine, text, _ in
            try await synth.synthesize(engine: engine, text: text)
        }, makePlayback: { data, completion in
            try players.make(data, completion: completion)
        })
    }

    private func waitUntil(_ predicate: () async -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureError(message: "等待朗读状态超时")
    }

    private func settleCallbacks() async throws {
        // 让排队中的主线程回调与不响应取消的 fixture 结果获得执行机会。
        for _ in 0..<5 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testPiperReadyThenRealPipeFrameRoundTripsAndRestarts() async throws {
        // 自写 Perl fixture，仅用系统解释器；不执行 Piper、Python 或模型。
        let fixture = #"""
        use strict;
        use warnings;
        binmode STDIN;
        binmode STDOUT;
        $| = 1;
        sub frame {
            my ($payload) = @_;
            print pack('Q<', length($payload)), $payload;
        }
        frame('{"ok":true}');
        while (defined(my $request = <STDIN>)) {
            chomp $request;
            frame($request);
        }
        """#
        let bridge = PiperBridge(processFactory: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", fixture]
            return process
        })
        defer { bridge.shutdown() }

        for (text, scale) in [("第一段\n含换行", 1.2), ("第二段", 0.8)] {
            let audio = try await bridge.synthesize(text: text, lengthScale: scale)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: audio) as? [String: Any])
            XCTAssertEqual(request["text"] as? String, text)
            XCTAssertEqual(request["length_scale"] as? Double, scale)
        }
        bridge.shutdown()
        let restarted = try await bridge.synthesize(text: "重启后的段落", lengthScale: 1)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: restarted) as? [String: Any])
        XCTAssertEqual(request["text"] as? String, "重启后的段落")
    }

    func testPiperReadyRetainsCoalescedFrameBytesAndThrowsErrorFrame() async throws {
        // ready、响应帧及错误帧一次写入，覆盖 ready 后缓冲被清空的回归。
        let fixture = #"""
        use strict;
        use warnings;
        binmode STDIN;
        binmode STDOUT;
        $| = 1;
        my $ready = '{"ok":true}';
        my $audio = 'buffered wav fixture';
        my $error = 'fixture synthesis rejected';
        print pack('Q<', length($ready)), $ready,
              pack('Q<', length($audio)), $audio,
              pack('Q<', 0), pack('Q<', length($error)), $error;
        while (<STDIN>) { }
        """#
        let bridge = PiperBridge(processFactory: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", fixture]
            return process
        })
        defer { bridge.shutdown() }
        let audio = try await bridge.synthesize(text: "首段", lengthScale: 1)
        XCTAssertEqual(audio, Data("buffered wav fixture".utf8))
        do {
            _ = try await bridge.synthesize(text: "失败段", lengthScale: 1)
            XCTFail("协议错误帧应抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fixture synthesis rejected"))
        }
    }

    func testReadAloudKeepsSourceSegmentIDsIndependentOfPlaybackSequence() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), segments: [
            .init(id: 4, text: "甲。"), .init(id: 9, text: "第二段正文")
        ], startSegmentID: 4)
        try await waitUntil { await synth.allRequests().count == 1 }
        XCTAssertEqual(service.currentSegmentID, 4)
        XCTAssertEqual(service.currentParagraphIndex, 4)
        await synth.succeed(0)
        try await waitUntil {
            let requests = await synth.allRequests()
            return players.players.count == 1 && requests.count == 2
        }
        players.players[0].finish()
        try await waitUntil { service.currentSegmentID == 9 }
        XCTAssertEqual(service.currentParagraphIndex, 9)
        let requests = await synth.allRequests()
        XCTAssertEqual(requests.map(\.text), ["甲。", "第二段正文"], "短段应保留，预取顺序也不改变原始定位 ID")
    }

    func testBothSynthesisFailuresStopAfterOneAttemptPerEngineAndKeepError() async throws {
        for firstEngine in [Engine.piper, .ai] {
            let synth = Synthesizer()
            let players = Players()
            let service = makeService(synth, players: players, engine: firstEngine)
            defer { service.stop() }
            service.start(bookId: UUID(), paragraphs: ["唯一的一段"])
            try await waitUntil { await synth.allRequests().count == 1 }
            await synth.fail(0, message: "first failure")
            try await waitUntil { await synth.allRequests().count == 2 }
            await synth.fail(1, message: "second failure")
            try await waitUntil { service.state == .idle && service.engineError != nil }
            let finalError = try XCTUnwrap(service.engineError)
            XCTAssertTrue(finalError.contains("first failure"))
            XCTAssertTrue(finalError.contains("second failure"))
            XCTAssertTrue(finalError.contains("Piper"))
            XCTAssertTrue(finalError.contains("AI 语音"))
            service.resume()
            service.resumeIfNeededAfterEngineSwitch()
            try await settleCallbacks()
            let requests = await synth.allRequests()
            XCTAssertEqual(requests.map(\.engine), [firstEngine, firstEngine.alternate])
            XCTAssertEqual(service.engineError, finalError)
            XCTAssertTrue(players.players.isEmpty)
            service.stop()
            XCTAssertNil(service.engineError, "手动 stop 应保留取消语义，不留下失败提示")
        }
    }

    func testPlaybackFailuresAlsoHaveFiniteEngineBudget() async throws {
        let synth = Synthesizer()
        let players = Players()
        players.failCreation = true
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["播放器无法解码"])
        try await waitUntil { await synth.allRequests().count == 1 }
        await synth.succeed(0)
        try await waitUntil { await synth.allRequests().count == 2 }
        await synth.succeed(1)
        try await waitUntil { service.state == .idle }
        try await settleCallbacks()
        let requests = await synth.allRequests()
        XCTAssertEqual(requests.map(\.engine), [.piper, .ai])
        XCTAssertTrue(service.engineError?.contains("fixture decode failure") == true)
    }

    func testFallbackSuccessPlaysAndResetsBudgetAfterParagraphProgress() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["第一段文字", "第二段文字"])
        try await waitUntil { await synth.allRequests().count == 1 }
        await synth.fail(0)
        try await waitUntil { await synth.allRequests().count == 2 }
        await synth.succeed(1)
        try await waitUntil {
            let requests = await synth.allRequests()
            return players.players.count == 1 && requests.count == 3
        }
        XCTAssertEqual(players.players[0].playCount, 1)
        XCTAssertEqual(service.activeEngine, .ai)
        let firstError = try XCTUnwrap(service.engineError)
        XCTAssertTrue(firstError.contains("Piper"))
        players.players[0].finish()
        try await waitUntil { service.currentParagraphIndex == 1 }
        XCTAssertNil(service.engineError)
        await synth.fail(2, message: "第二段 AI 失败")
        try await waitUntil { await synth.allRequests().count == 4 }
        let requests = await synth.allRequests()
        XCTAssertEqual(requests.map(\.engine), [.piper, .ai, .ai, .piper])
        XCTAssertEqual(requests.map(\.text), ["第一段文字", "第一段文字", "第二段文字", "第二段文字"])
        await synth.succeed(3)
        try await waitUntil { players.players.count == 2 }
        players.players[1].finish()
        try await waitUntil { service.state == .idle }
        XCTAssertNil(service.engineError)
    }

    func testInFlightPrefetchIsReusedAndFailureCannotRetrySameEngine() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["正在播放的段落", "已经预取的段落"])
        try await waitUntil { await synth.allRequests().count == 1 }
        await synth.succeed(0)
        try await waitUntil {
            let requests = await synth.allRequests()
            return players.players.count == 1 && requests.count == 2
        }
        // 前台进入下一段时，该段的同引擎预取仍在途中。
        players.players[0].finish()
        try await waitUntil { service.currentParagraphIndex == 1 }
        try await settleCallbacks()
        var requests = await synth.allRequests()
        XCTAssertEqual(requests.count, 2)
        await synth.fail(1, message: "prefetch failed")
        try await waitUntil { await synth.allRequests().count == 3 }
        await synth.fail(2, message: "alternate failed")
        try await waitUntil { service.state == .idle }
        try await settleCallbacks()
        requests = await synth.allRequests()
        XCTAssertEqual(requests.filter { $0.text == "已经预取的段落" }.map(\.engine), [.piper, .ai])
        XCTAssertTrue(service.engineError?.contains("prefetch failed") == true)
        XCTAssertTrue(service.engineError?.contains("alternate failed") == true)
    }

    func testFailedPrefetchIsConsumedWithoutRetryingOriginalEngine() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["第一段继续播放", "下一段预取失败"])
        try await waitUntil { await synth.allRequests().count == 1 }
        await synth.succeed(0)
        try await waitUntil {
            let requests = await synth.allRequests()
            return players.players.count == 1 && requests.count == 2
        }
        await synth.fail(1, message: "completed prefetch failure")
        try await settleCallbacks()
        XCTAssertEqual(service.currentParagraphIndex, 0)
        XCTAssertNil(service.engineError, "预取失败应留到前台进入该段时再报告")
        players.players[0].finish()
        try await waitUntil { await synth.allRequests().count == 3 }
        await synth.fail(2, message: "fallback also failed")
        try await waitUntil { service.state == .idle }
        try await settleCallbacks()
        let requests = await synth.allRequests()
        XCTAssertEqual(requests.filter { $0.text == "下一段预取失败" }.map(\.engine), [.piper, .ai])
        XCTAssertTrue(service.engineError?.contains("completed prefetch failure") == true)
    }

    func testCachedPrefetchPlaybackFailureDoesNotResynthesizeSameEngine() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["第一段播放", "第二段缓存"])
        try await waitUntil { await synth.allRequests().count == 1 }
        await synth.succeed(0)
        try await waitUntil {
            let requests = await synth.allRequests()
            return players.players.count == 1 && requests.count == 2
        }
        await synth.succeed(1)
        players.failCreation = true
        players.players[0].finish()
        try await waitUntil { await synth.allRequests().count == 3 }
        await synth.succeed(2)
        try await waitUntil { service.state == .idle }
        try await settleCallbacks()
        let requests = await synth.allRequests()
        XCTAssertEqual(requests.filter { $0.text == "第二段缓存" }.map(\.engine), [.piper, .ai])
        XCTAssertNotNil(service.engineError)
    }

    func testSynthesisCompletingWhilePausedWaitsForResume() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["暂停期间合成完成"])
        try await waitUntil { await synth.allRequests().count == 1 }
        service.pause()
        await synth.succeed(0)
        try await settleCallbacks()
        XCTAssertEqual(service.state, .paused)
        XCTAssertTrue(players.players.isEmpty)
        service.resume()
        try await waitUntil { players.players.count == 1 }
        XCTAssertEqual(players.players[0].playCount, 1)
        let requests = await synth.allRequests()
        XCTAssertEqual(requests.count, 1)
        service.pause()
        XCTAssertEqual(players.players[0].pauseCount, 1)
        service.resume()
        XCTAssertEqual(players.players[0].playCount, 2)
    }

    func testPausedFailureUsesFallbackOnResumeOnlyOnce() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["暂停中失败"])
        try await waitUntil { await synth.allRequests().count == 1 }
        service.pause()
        await synth.fail(0)
        try await waitUntil { service.activeEngine == .ai }
        service.resumeIfNeededAfterEngineSwitch()
        try await settleCallbacks()
        var requests = await synth.allRequests()
        XCTAssertEqual(requests.count, 1)
        service.resume()
        service.resumeIfNeededAfterEngineSwitch()
        try await waitUntil { await synth.allRequests().count == 2 }
        await synth.succeed(1)
        try await waitUntil { players.players.count == 1 }
        requests = await synth.allRequests()
        XCTAssertEqual(requests.map(\.engine), [.piper, .ai])
        XCTAssertEqual(players.players[0].playCount, 1)
    }

    func testStopDiscardsUncooperativeSynthesisSuccessAndFailure() async throws {
        for success in [true, false] {
            let synth = Synthesizer()
            let players = Players()
            let service = makeService(synth, players: players)
            service.start(bookId: UUID(), paragraphs: ["取消中的合成"])
            try await waitUntil { await synth.allRequests().count == 1 }
            service.stop()
            if success { await synth.succeed(0) }
            else { await synth.fail(0) }
            try await settleCallbacks()
            let requests = await synth.allRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(service.state, .idle)
            XCTAssertNil(service.currentBookId)
            XCTAssertNil(service.engineError)
            XCTAssertTrue(players.players.isEmpty)
        }
    }

    func testNewStartIsolatesOldPrefetchAndPlaybackCompletion() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["旧会话首段", "旧会话预取"])
        try await waitUntil { await synth.allRequests().count == 1 }
        await synth.succeed(0)
        try await waitUntil {
            let requests = await synth.allRequests()
            return players.players.count == 1 && requests.count == 2
        }
        let oldPlayer = players.players[0]
        let book = UUID()
        service.start(bookId: book, paragraphs: ["新会话首段", "新会话下一段"])
        try await waitUntil { await synth.allRequests().count == 3 }
        await synth.succeed(1, audio: Data("stale cached audio".utf8))
        oldPlayer.finish()
        try await settleCallbacks()
        XCTAssertEqual(service.currentBookId, book)
        XCTAssertEqual(service.currentParagraphIndex, 0)
        XCTAssertEqual(players.players.count, 1)
        XCTAssertNil(service.engineError)
        await synth.fail(2, message: "new first failure")
        try await waitUntil { await synth.allRequests().count == 4 }
        await synth.fail(3, message: "new fallback failure")
        try await waitUntil { service.state == .idle }
        let requests = await synth.allRequests()
        XCTAssertEqual(requests.filter { $0.text == "新会话首段" }.map(\.engine), [.piper, .ai])
        XCTAssertTrue(service.engineError?.contains("new fallback failure") == true)
    }

    func testNewStartResetsExhaustedBudgetAndIgnoresOldFailure() async throws {
        let synth = Synthesizer()
        let players = Players()
        let service = makeService(synth, players: players)
        defer { service.stop() }
        service.start(bookId: UUID(), paragraphs: ["相同的段落"])
        try await waitUntil { await synth.allRequests().count == 1 }
        service.start(bookId: UUID(), paragraphs: ["相同的段落"])
        try await waitUntil { await synth.allRequests().count == 2 }
        await synth.fail(0, message: "stale failure")
        try await settleCallbacks()
        XCTAssertEqual(service.activeEngine, .piper)
        XCTAssertNil(service.engineError)
        await synth.fail(1)
        try await waitUntil { await synth.allRequests().count == 3 }
        await synth.fail(2)
        try await waitUntil { service.state == .idle }
        service.start(bookId: UUID(), paragraphs: ["相同的段落"])
        try await waitUntil { await synth.allRequests().count == 4 }
        XCTAssertNil(service.engineError)
        await synth.succeed(3)
        try await waitUntil { players.players.count == 1 }
        let requests = await synth.allRequests()
        XCTAssertEqual(requests.map(\.engine), [.piper, .piper, .ai, .piper])
        players.players[0].finish()
        try await waitUntil { service.state == .idle }
    }
}
