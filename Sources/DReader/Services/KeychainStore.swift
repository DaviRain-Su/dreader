import Foundation
import Security

/// 凭据专用 Keychain 读写（kSecClassGenericPassword）。
/// 只存令牌/Cookie/密钥，不存一般偏好；迁移语义：读到旧 UserDefaults 值后
/// 写入 Keychain 并删除旧键，失败则保留旧值下次重试。
enum KeychainStore {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain 操作失败（\(status)）"
            }
        }
    }

    private static let service = "com.dreader.mac.credentials"

    /// 读不到或发生错误时返回 nil（不抛：调用方多为启动路径）。
    static func read(_ account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写入（存在则更新）。返回是否成功；失败时调用方应保留旧存储。
    @discardableResult
    static func write(_ account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 迁移：旧 UserDefaults 明文值 → Keychain。成功后删除旧键；
    /// Keychain 写入失败时保留旧值（下次启动重试），返回迁移后的当前值。
    static func migrate(account: String, defaultsKey: String,
                        defaults: UserDefaults = .standard) -> String? {
        if let existing = read(account) {
            // 已在 Keychain：清掉可能残留的旧明文键。
            if defaults.string(forKey: defaultsKey) != nil {
                defaults.removeObject(forKey: defaultsKey)
            }
            return existing
        }
        guard let legacy = defaults.string(forKey: defaultsKey), !legacy.isEmpty else { return nil }
        guard write(account, value: legacy) else { return legacy } // 失败：继续用旧值
        defaults.removeObject(forKey: defaultsKey)
        return legacy
    }
}
