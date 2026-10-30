import Foundation
import XCTest
@testable import DReader

@MainActor
final class QwenEngineTests: XCTestCase {
    func testChunkerPreservesTextPunctuationAndOriginalIDs() {
        let long = String(repeating: "天地玄黄", count: 40)
        let pieces = QwenTextChunker.chunks(for: [
            .init(id: 7, text: "“你回来了。”他停顿一下，“我们慢慢谈。”"),
            .init(id: 7, text: long),
            .init(id: 9, text: "短句。"),
        ], limit: 40)
        XCTAssertTrue(pieces.allSatisfy { $0.text.count <= 40 })
        XCTAssertEqual(pieces.map(\.id), Array(repeating: 7, count: pieces.count - 1) + [9])
        XCTAssertEqual(pieces.map(\.text).joined(), "“你回来了。”他停顿一下，“我们慢慢谈。”" + long + "短句。")
        XCTAssertTrue(pieces.first?.text.contains("“你回来了。”") == true)
    }

    func testChunkerSplitsLongUnbrokenTextWithoutLosingCharacters() {
        let text = String(repeating: "长", count: 257)
        let chunks = QwenTextChunker.chunks(for: text, limit: 80)
        XCTAssertEqual(chunks.map(\.count), [80, 80, 80, 17])
        XCTAssertEqual(chunks.joined(), text)
    }

    func testQwenMigrationDoesNotOverrideExplicitChoices() {
        typealias Engine = ReaderSettings.ReadAloudEngine
        XCTAssertEqual(Engine.migrated(from: Engine.piper.rawValue, migrationDone: false), .qwen)
        XCTAssertEqual(Engine.migrated(from: nil, migrationDone: false), .qwen)
        XCTAssertEqual(Engine.migrated(from: Engine.piper.rawValue, migrationDone: true), .piper)
        XCTAssertEqual(Engine.migrated(from: Engine.ai.rawValue, migrationDone: false), .ai)
        XCTAssertEqual(Engine.migrated(from: Engine.ai.rawValue, migrationDone: true), .ai)
    }

    func testWorkerReadsReadyAndBufferedWAVFrames() async throws {
        let fixture = #"""
        use strict; use warnings; binmode STDOUT; $| = 1;
        sub frame { print pack('Q<', length($_[0])), $_[0]; }
        my $ready = '{"ok":true}';
        my $wav = 'RIFF' . pack('V', 38) . 'WAVEfmt ' . pack('V', 16)
            . pack('vvVVvv', 1, 1, 24000, 48000, 2, 16) . 'data' . pack('V', 2) . "\0\0";
        frame($ready);
        my $bytes = pack('Q<', length($wav)) . $wav;
        print substr($bytes, 0, 5);
        print substr($bytes, 5), pack('Q<', length($wav)), $wav;
        while (<STDIN>) { }
        """#
        let worker = QwenWorker(processFactory: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", fixture]
            return process
        })
        defer { worker.shutdown() }
        for _ in 0..<2 {
            let audio = try await worker.synthesize(text: "测试", voice: .serena)
            XCTAssertEqual(String(decoding: audio.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(audio.count, 46)
        }
    }

    func testWorkerCancellationInterruptsReadAndCanRestart() async throws {
        let slow = #"""
        use strict; use warnings; binmode STDOUT; $| = 1;
        my $ready = '{"ok":true}'; print pack('Q<', length($ready)), $ready;
        $SIG{TERM} = sub { exit 0; };
        while (<STDIN>) { select undef, undef, undef, 60; }
        """#
        let good = #"""
        use strict; use warnings; binmode STDOUT; $| = 1;
        sub frame { print pack('Q<', length($_[0])), $_[0]; }
        frame('{"ok":true}');
        my $wav = 'RIFF' . pack('V', 38) . 'WAVEfmt ' . pack('V', 16)
            . pack('vvVVvv', 1, 1, 24000, 48000, 2, 16) . 'data' . pack('V', 2) . "\0\0";
        frame($wav);
        while (<STDIN>) { }
        """#
        var launches = 0
        let worker = QwenWorker(processFactory: {
            launches += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", launches == 1 ? slow : good]
            return process
        }, requestTimeout: 30)
        let task = Task { try await worker.synthesize(text: "等待取消", voice: .serena) }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后不应继续返回音频")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
        worker.shutdown()
        let audio = try await worker.synthesize(text: "重启", voice: .uncleFu)
        XCTAssertEqual(String(decoding: audio.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(launches, 2)
    }

    func testWorkerTimeoutIsFiniteAndReported() async throws {
        let fixture = #"""
        use strict; use warnings; binmode STDOUT; $| = 1;
        my $ready = '{"ok":true}'; print pack('Q<', length($ready)), $ready;
        $SIG{TERM} = sub { exit 0; };
        while (<STDIN>) { select undef, undef, undef, 60; }
        """#
        let worker = QwenWorker(processFactory: {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", fixture]
            return process
        }, requestTimeout: 0.15)
        defer { worker.shutdown() }
        do {
            _ = try await worker.synthesize(text: "超时", voice: .serena)
            XCTFail("超时进程不应被当作成功")
        } catch let error as QwenWorkerError {
            guard case .timeout = error else { return XCTFail("错误类型应为 timeout，实际为 \(error)") }
        }
    }

    func testIncompleteModelIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try QwenInstallation.validateModel(at: directory))
    }
}
