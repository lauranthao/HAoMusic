import Foundation
import os

// HAo Music: plaintext upstream hosts (no puzzle/obfuscation).
// Same API surface as the Kumone original so the rest of the codebase
// (NeteaseAPI, UpstreamGate, sync) works unchanged. The hosts are built in
// (163/126) instead of being asked on first launch, so `hosts` is never nil
// and `isConfigured` is always true.
enum Upstream {

    /// Stored endpoint configuration.
    struct Hosts: Codable, Equatable, Sendable {
        /// Web, login and the encrypted API: `music.<api>.com`.
        let api: Int
        /// Signed audio and images: `*.music.<cdn>.net`.
        let cdn: Int
    }

    private static let defaultsKey = "upstream.hosts"
    private static let fixed = Hosts(api: 163, cdn: 126)
    private static let state = OSAllocatedUnfairLock<Hosts?>(initialState: load())

    private static func load() -> Hosts? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Hosts.self, from: data) else {
            return fixed
        }
        return decoded
    }

    static var hosts: Hosts? { state.withLock { $0 } }
    static var isConfigured: Bool { hosts != nil }

    /// Stores the hosts. Pass `persist: false` from tests.
    static func configure(_ hosts: Hosts, persist: Bool = true) {
        state.withLock { $0 = hosts }
        if persist, let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Restores the built-in hosts.
    static func reset() {
        state.withLock { $0 = fixed }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static let didChange = Notification.Name("Upstream.didChange")

    // MARK: - Hosts

    static var webHost: String? { hosts.map { "music.\($0.api).com" } }
    static var interfaceHost: String? { hosts.map { "interface.music.\($0.api).com" } }
    /// Suffix every audio CDN host ends with, leading dot included.
    static var cdnSuffix: String? { hosts.map { ".music.\($0.cdn).net" } }

    static func webURL(_ pathAndQuery: String) -> URL? {
        webHost.flatMap { URL(string: "https://\($0)\(pathAndQuery)") }
    }

    static func songPageURL(id: Int) -> URL? { webURL("/#/song?id=\(id)") }

    // MARK: - Protocol identifiers

    /// Source identifier used in request headers, cache keys, offline records
    /// and account scopes.
    static let tag = "netease"

    /// Client name for the User-Agent.
    static var clientName: String { tag.prefix(1).uppercased() + tag.dropFirst() + "Music" }

    /// The scope offline downloads and sync records carry for an account.
    static func accountScope(userID: Int) -> String { "\(tag):\(userID)" }
}
