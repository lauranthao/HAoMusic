import Foundation
import Security

// MARK: - Coda shared types carried over with the QQ platform
//
// From Coda (Wow-CaiCai/Coda, AGPL-3.0):
//   Core/Storage/MusicAccountManager.swift (MusicAccountValidity)
//   Core/Storage/MusicProvider.swift (MusicProviderError, ProviderCredentialDefaults)
// Only change: the keychain service namespace is HAo Music's own bundle id
// (com.haostudio.music.music-accounts) instead of Coda's.

enum MusicAccountValidity: String {
    case checking = "验证中…"
    case valid = "有效"
    case invalid = "失效"
    case unknown = "暂无法验证"
}

enum MusicProviderError: LocalizedError {
    case unsupported, missingTrack, storage(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unsupported: return "当前音乐平台暂不支持此功能"
        case .missingTrack: return "歌曲来源信息已失效，请重新加载歌单或搜索"
        case .storage(let code): return "账号凭证保存失败（\(code)）"
        }
    }
}

/// Adapter persistence and saved account sessions live in this app's keychain.
/// No cookies or tokens are written to UserDefaults or logs.
final class ProviderCredentialDefaults {
    static let shared = ProviderCredentialDefaults()
    private let service = "com.haostudio.music.music-accounts"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] }
    private(set) var lastError: OSStatus?
    #if os(macOS)
    // Providers repeatedly read their defaults during request signing. Ask for
    // each credential once per process, including after cancelled authorization.
    // Successful writes replace this cache so a new login takes effect at once.
    private let credentialLock = NSRecursiveLock()
    private var cachedCredentials: [String: Data] = [:]
    private var attemptedReads: Set<String> = []
    #endif
    func data(forKey key: String) -> Data? {
        #if os(macOS)
        credentialLock.lock()
        defer { credentialLock.unlock() }
        if attemptedReads.contains(key) { return cachedCredentials[key] }
        #endif
        var q = query
        q[kSecAttrAccount as String] = key
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        lastError = status == errSecSuccess ? nil : status
        let data = status == errSecSuccess ? result as? Data : nil
        #if os(macOS)
        attemptedReads.insert(key)
        cachedCredentials[key] = data
        #endif
        return data
    }
    func dictionary(forKey key: String) -> [String: Any]? {
        guard let data = data(forKey: key) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func string(forKey key: String) -> String? { data(forKey: key).flatMap { String(data: $0, encoding: .utf8) } }
    @discardableResult func set(_ value: Any, forKey key: String) -> Bool {
        #if os(macOS)
        credentialLock.lock()
        defer { credentialLock.unlock() }
        #endif
        let data: Data?
        if let bytes = value as? Data { data = bytes }
        else if let text = value as? String { data = Data(text.utf8) }
        else { data = try? JSONSerialization.data(withJSONObject: value) }
        guard let data else { return false }
        var q = query
        q[kSecAttrAccount as String] = key
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        lastError = status == errSecSuccess ? nil : status
        #if os(macOS)
        if status == errSecSuccess {
            attemptedReads.insert(key)
            cachedCredentials[key] = data
        }
        #endif
        return status == errSecSuccess
    }
    func removeObject(forKey key: String) {
        #if os(macOS)
        credentialLock.lock()
        defer { credentialLock.unlock() }
        #endif
        var q = query; q[kSecAttrAccount as String] = key
        let status = SecItemDelete(q as CFDictionary)
        lastError = status == errSecSuccess || status == errSecItemNotFound ? nil : status
        #if os(macOS)
        if status == errSecSuccess || status == errSecItemNotFound {
            attemptedReads.insert(key)
            cachedCredentials[key] = nil
        }
        #endif
    }
}
