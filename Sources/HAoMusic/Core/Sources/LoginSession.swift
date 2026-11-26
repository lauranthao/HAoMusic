#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// 登录后的账号资料（只存昵称/头像/ID，不存密码）。
struct AccountProfile: Codable, Sendable, Equatable {
    let platform: MusicProvider
    let userID: String
    let nickname: String
    let avatarURL: String?
}

/// 一次平台登录的会话：资料 + Cookie 头值 + 存入时间。
/// Cookie 是服务端发的登录凭证原文（网易 MUSIC_U/__csrf；QQ uin/skey/p_skey 等），
/// 每次请求原样带在 Cookie 头里；不做任何改写。
struct LoginSession: Codable, Sendable, Equatable {
    let platform: MusicProvider
    var profile: AccountProfile
    var cookie: String
    let createdAt: Date

    /// 本地软过期：超过 180 天强制重新扫码（服务端也可能更早让凭证失效，
    /// 那时由启动校验或账号页重新登录发现）。
    static let maxAgeDays = 180

    var isStale: Bool {
        Date().timeIntervalSince(createdAt) > Double(Self.maxAgeDays * 24 * 3600)
    }

    /// QQ 恢复校验用的结构检查：必须有 uin + skey 才算一条能用的会话。
    var hasQQCookies: Bool {
        CookieJar.value(named: "uin", in: cookie) != nil
            && CookieJar.value(named: "skey", in: cookie) != nil
    }
}

/// 扫码登录的轮询状态（纯状态机，可单测；网络 code → 状态的映射见 QRLoginStateMachine）。
enum QRLoginStatus: Equatable, Sendable {
    case waiting   // 等待扫码
    case scanned   // 已扫码，待手机上确认
    case confirmed // 已确认，登录成功
    case expired   // 二维码已过期
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .confirmed, .expired, .failed: return true
        case .waiting, .scanned: return false
        }
    }

    var label: String {
        switch self {
        case .waiting: return "等待扫码"
        case .scanned: return "已扫码，请在手机上确认"
        case .confirmed: return "登录成功"
        case .expired: return "二维码已过期"
        case .failed(let message): return message
        }
    }
}

/// 轮询 code → 扫码状态（纯函数）。
enum QRLoginStateMachine {
    /// 网易 /api/login/qrcode/check 的 code：801 等待、802 已扫、803 成功、800 过期。
    static func neteaseStatus(code: Int) -> QRLoginStatus {
        switch code {
        case 801: return .waiting
        case 802: return .scanned
        case 803: return .confirmed
        case 800: return .expired
        default: return .failed("网易返回未知状态（\(code)）")
        }
    }

    /// QQ ptqrlogin 的 ptuiCB code：'66' 等待、'67' 已扫待确认、'0' 成功、'65' 过期。
    static func qqStatus(code: String) -> QRLoginStatus {
        switch code {
        case "0": return .confirmed
        case "65": return .expired
        case "66": return .waiting
        case "67": return .scanned
        default: return .failed("QQ 返回未知状态（\(code)）")
        }
    }
}

/// Cookie 读写小工具（纯字符串操作，不依赖 HTTPCookieStorage，可单测）。
enum CookieJar {
    /// 解析一条 Set-Cookie 响应头值，只取第一个分号前的 name=value。
    static func parseSetCookie(_ header: String) -> (name: String, value: String)? {
        let first = header.split(separator: ";", maxSplits: 1).first.map(String.init) ?? header
        guard let eq = first.firstIndex(of: "=") else { return nil }
        let name = first[..<eq].trimmingCharacters(in: .whitespaces)
        let value = first[first.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (String(name), String(value))
    }

    /// 合并多条 Set-Cookie 到已有 jar（同名覆盖），返回新 jar。
    static func merge(_ setCookieValues: [String], into jar: [String: String]) -> [String: String] {
        var jar = jar
        for value in setCookieValues {
            if let (name, v) = parseSetCookie(value) { jar[name] = v }
        }
        return jar
    }

    /// jar → Cookie 请求头值（按 key 排序，保证确定性）。
    static func headerValue(_ jar: [String: String]) -> String {
        jar.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 从 Cookie 头字符串里取值。
    static func value(named name: String, in cookieHeader: String) -> String? {
        for part in cookieHeader.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == name { return kv[1] }
        }
        return nil
    }

    /// 从响应里取全部 Set-Cookie 头值（大小写不敏感）。
    static func setCookieValues(from response: HTTPURLResponse) -> [String] {
        var values: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let keyString = key as? String,
                  keyString.lowercased() == "set-cookie" else { continue }
            if let string = value as? String {
                values.append(string)
            } else if let array = value as? [String] {
                values.append(contentsOf: array)
            }
        }
        return values
    }
}

/// 线程安全的会话盒子：登录管理器与各平台客户端之间的唯一事实来源。
/// 用 NSLock 保护，@unchecked Sendable——管理器（MainActor）与客户端闭包
/// （@Sendable）都能同步读写，不需要经过 MainActor 跳转。
final class LoginSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [MusicProvider: LoginSession] = [:]

    func set(_ session: LoginSession) {
        lock.lock()
        defer { lock.unlock() }
        sessions[session.platform] = session
    }

    func remove(provider: MusicProvider) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: provider)
    }

    func session(for provider: MusicProvider) -> LoginSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[provider]
    }

    func cookie(for provider: MusicProvider) -> String? {
        session(for: provider)?.cookie
    }

    /// QQ 取流要用的真实 uin（未登录返回 nil，调用方回落到 "0"）。
    func uin(for provider: MusicProvider) -> String? {
        guard provider == .qq,
              let cookie = cookie(for: .qq) else { return nil }
        return CookieJar.value(named: "uin", in: cookie)
    }

    func all() -> [MusicProvider: LoginSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }
}
