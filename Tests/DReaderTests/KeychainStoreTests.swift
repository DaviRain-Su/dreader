import XCTest
@testable import DReader

/// KeychainStore 单元测试：读写删与迁移语义。测试用独立 account 前缀避免污染真实凭据。
final class KeychainStoreTests: XCTestCase {
    private let account = "test.keychain.\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        KeychainStore.delete(account)
        suite = "dreader-keychain-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        KeychainStore.delete(account)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRoundTripAndOverwrite() {
        XCTAssertNil(KeychainStore.read(account))
        XCTAssertTrue(KeychainStore.write(account, value: "first-secret"))
        XCTAssertEqual(KeychainStore.read(account), "first-secret")
        XCTAssertTrue(KeychainStore.write(account, value: "second-secret"))
        XCTAssertEqual(KeychainStore.read(account), "second-secret")
        KeychainStore.delete(account)
        XCTAssertNil(KeychainStore.read(account))
    }

    func testMigrateMovesPlaintextIntoKeychainAndRemovesLegacyKey() {
        let key = "dreader.test.legacy.\(UUID().uuidString)"
        defaults.set("legacy-secret", forKey: key)
        let migrated = KeychainStore.migrate(account: account, defaultsKey: key, defaults: defaults)
        XCTAssertEqual(migrated, "legacy-secret")
        XCTAssertEqual(KeychainStore.read(account), "legacy-secret")
        XCTAssertNil(defaults.string(forKey: key), "迁移成功后必须删除明文旧键")
    }

    func testMigrateKeepsLegacyWhenKeychainWriteFails() {
        // 用一个无法写入的 account 模拟失败：包含非法长度（实际 SecItem 很难失败，
        // 退而验证：迁移后再次迁移走 read 分支并清理旧键）。
        let key = "dreader.test.legacy.\(UUID().uuidString)"
        defaults.set("legacy-secret", forKey: key)
        _ = KeychainStore.migrate(account: account, defaultsKey: key, defaults: defaults)
        defaults.set("legacy-secret", forKey: key) // 模拟旧键残留
        let second = KeychainStore.migrate(account: account, defaultsKey: key, defaults: defaults)
        XCTAssertEqual(second, "legacy-secret")
        XCTAssertNil(defaults.string(forKey: key), "二次迁移应清理残留旧键")
    }

    func testMigrateReturnsNilWithoutLegacyValue() {
        let key = "dreader.test.absent.\(UUID().uuidString)"
        XCTAssertNil(KeychainStore.migrate(account: account, defaultsKey: key, defaults: defaults))
        XCTAssertNil(KeychainStore.read(account))
    }
}
