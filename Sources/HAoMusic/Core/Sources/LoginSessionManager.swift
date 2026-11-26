import Foundation

/// 登录会话管理器：两个平台的登录态唯一入口。
/// - 启动恢复：读本地会话；网易走服务端校验（account/get 明确拒绝才清掉，
///   网络瞬断不断登录），QQ 走结构检查（uin + skey 在就认）+ 顺手刷新资料。
/// - 扫码流程：二维码申请 / 轮询 / 确认后存会话的三步，界面层直接调这几个方法。
/// - 退出登录：清钥匙串 + 清内存态。
/// 凭证事实来源是 `box`（LoginSessionBox）：客户端闭包直接读它，
/// 登录/退出立即生效，不用重建客户端。
@MainActor
final class LoginSessionManager: ObservableObject {
    @Published private(set) var sessions: [MusicProvider: LoginSession] = [:]

    /// 客户端闭包读的会话盒子（与 sessions 保持同步）。
    let box = LoginSessionBox()

    private let store: any LoginSessionStore
    private let neteaseLogin: NeteaseLoginService
    private let qqLogin: QQLoginService

    init(
        store: (any LoginSessionStore)? = nil,
        neteaseLogin: NeteaseLoginService? = nil,
        qqLogin: QQLoginService? = nil
    ) {
        self.store = store ?? LoginSessionStoreFactory.make()
        self.neteaseLogin = neteaseLogin ?? NeteaseLoginService()
        self.qqLogin = qqLogin ?? QQLoginService()
    }

    func isLoggedIn(_ provider: MusicProvider) -> Bool {
        sessions[provider] != nil
    }

    func profile(for provider: MusicProvider) -> AccountProfile? {
        sessions[provider]?.profile
    }

    // MARK: - 启动恢复

    func restore() async {
        for provider in [MusicProvider.netease, .qq] {
            guard var session = store.load(platform: provider) else { continue }
            if session.isStale {
                store.delete(platform: provider)
                continue
            }
            switch provider {
            case .netease:
                do {
                    session.profile = try await neteaseLogin.fetchProfile(cookie: session.cookie)
                    apply(session)
                } catch {
                    // 网络瞬断不断登录（下次启动再验）；服务端明确拒绝才清掉。
                    if Self.isAuthFailure(error) {
                        store.delete(platform: provider)
                    } else {
                        apply(session)
                    }
                }
            case .qq:
                guard session.hasQQCookies else {
                    store.delete(platform: provider)
                    continue
                }
                apply(session)
                if let uin = CookieJar.value(named: "uin", in: session.cookie),
                   let profile = try? await qqLogin.fetchProfile(
                       uin: uin, cookie: session.cookie,
                       fallbackNickname: session.profile.nickname) {
                    session.profile = profile
                    apply(session)
                }
            default:
                break
            }
        }
    }

    /// fetchProfile 只在服务端明确拒绝（code != 200）时抛 hard；
    /// 网络问题是 transient/timeout——那不算凭证失效。
    /// 内部静态方法，供 harness 验分类逻辑。
    static func isAuthFailure(_ error: Error) -> Bool {
        if let resolveError = error as? ResolveError, case .hard = resolveError {
            return true
        }
        return false
    }

    // MARK: - 网易扫码

    func neteaseQR() async throws -> (unikey: String, image: Data) {
        let key = try await neteaseLogin.requestUnikey()
        let image = try await neteaseLogin.qrImage(unokey: key)
        return (key, image)
    }

    func neteasePoll(unikey: String) async throws -> (status: QRLoginStatus, cookie: String?) {
        try await neteaseLogin.check(unokey: unikey)
    }

    func completeNeteaseLogin(cookie: String) async throws -> LoginSession {
        let profile = try await neteaseLogin.fetchProfile(cookie: cookie)
        let session = LoginSession(
            platform: .netease, profile: profile, cookie: cookie, createdAt: Date())
        try store.save(session)
        apply(session)
        return session
    }

    // MARK: - QQ 扫码

    func qqQR() async throws -> (image: Data, qrsig: String) {
        try await qqLogin.requestQR()
    }

    func qqPoll(qrsig: String) async throws -> QQLoginService.QQPollResult {
        try await qqLogin.check(qrsig: qrsig)
    }

    func completeQQLogin(cookies: String, nickname: String?) async throws -> LoginSession {
        guard let uin = CookieJar.value(named: "uin", in: cookies) else {
            throw ResolveError.hard("QQ 登录成功但没拿到账号")
        }
        let profile = try await qqLogin.fetchProfile(
            uin: uin, cookie: cookies, fallbackNickname: nickname)
        let session = LoginSession(
            platform: .qq, profile: profile, cookie: cookies, createdAt: Date())
        try store.save(session)
        apply(session)
        return session
    }

    // MARK: - 退出

    func logout(provider: MusicProvider) {
        store.delete(platform: provider)
        box.remove(provider: provider)
        sessions.removeValue(forKey: provider)
    }

    // MARK: - 内部

    private func apply(_ session: LoginSession) {
        box.set(session)
        sessions[session.platform] = session
    }
}
