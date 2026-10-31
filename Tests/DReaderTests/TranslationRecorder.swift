import XCTest
@testable import DReader

/// 测试用并发安全记录器(闭包在任意 executor 运行)
final class TranslationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    private var strings: [String] = []
    private var dict: [Int: String] = [:]
    private var failures = 0

    func append(_ index: Int, _ text: String? = nil) {
        lock.lock()
        items.append(index)
        if let text {
            strings.append(text)
            dict[index] = text
        }
        lock.unlock()
    }

    func recordFailure() {
        lock.lock()
        failures += 1
        lock.unlock()
    }

    var snapshotIndices: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var snapshotTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return strings
    }

    var snapshotDict: [Int: String] {
        lock.lock()
        defer { lock.unlock() }
        return dict
    }

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}
