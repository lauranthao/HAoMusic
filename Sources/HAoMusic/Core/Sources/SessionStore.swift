#if canImport(Security)
import Security
#endif
import Foundation

/// 登录会话的持久化接口：按平台存一条会话。
protocol LoginSessionStore: Sendable {
    func save(_ session: LoginSession) throws
    func load(platform: MusicProvider) -> LoginSession?
    func delete(platform: MusicProvider)
}

enum SessionStoreError: Error {
    case encodeFailed
    /// 钥匙串状态码（OSStatus 就是 Int32；Linux 上没有 Security 也能编译）。
    case keychain(Int32)
}

/// 会话存取的构造：有 Security 就用钥匙串，否则走 UserDefaults。
/// iOS 上 Security 一定存在，走钥匙串；Linux 测试宿主没有 Security 才走后者。
enum LoginSessionStoreFactory {
    static func make() -> any LoginSessionStore {
        #if canImport(Security)
        return KeychainSessionStore()
        #else
        return UserDefaultsSessionStore()
        #endif
    }
}

#if canImport(Security)
/// 钥匙串存储（iOS 真机）：通用密码项，service 固定，account = 平台。
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly：首次解锁后后台也能读，
/// 且不随备份迁移到别的设备。
final class KeychainSessionStore: LoginSessionStore, @unchecked Sendable {
    private let service = "com.haostudio.music.login"

    func save(_ session: LoginSession) throws {
        guard let data = try? JSONEncoder().encode(session) else {
            throw SessionStoreError.encodeFailed
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: session.platform.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SessionStoreError.keychain(status)
        }
    }

    func load(platform: MusicProvider) -> LoginSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: platform.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(LoginSession.self, from: data)
    }

    func delete(platform: MusicProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: platform.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#else
/// UserDefaults 存储：只在没有 Security 的平台（Linux 测试宿主）编译。
/// iOS 上不用它——会话凭证进钥匙串。
final class UserDefaultsSessionStore: LoginSessionStore, @unchecked Sendable {
    private let defaults = UserDefaults.standard

    private func key(for platform: MusicProvider) -> String {
        "haoMusic.loginSession.\(platform.rawValue)"
    }

    func save(_ session: LoginSession) throws {
        guard let data = try? JSONEncoder().encode(session) else {
            throw SessionStoreError.encodeFailed
        }
        defaults.set(data, forKey: key(for: session.platform))
    }

    func load(platform: MusicProvider) -> LoginSession? {
        guard let data = defaults.data(forKey: key(for: platform)) else { return nil }
        return try? JSONDecoder().decode(LoginSession.self, from: data)
    }

    func delete(platform: MusicProvider) {
        defaults.removeObject(forKey: key(for: platform))
    }
}
#endif
