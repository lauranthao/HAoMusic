#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// QQ 音乐扫码登录（公开的 ptlogin 二维码流程，第三方客户端都在用的同一套，
/// 自己实现，不抄任何仓库的代码）：
///   1. 二维码：GET ssl.ptlogin2.qq.com/ptqrshow?appid=716027609… → PNG 字节，
///      响应 Set-Cookie 里带 qrsig
///   2. 轮询：GET ssl.ptlogin2.qq.com/ptqrlogin?ptqrtoken=hash33(qrsig)… →
///      ptuiCB('66'…等待 / '67'…已扫待确认 / '0'…成功，带跳转链接与昵称 / '65'…过期）
///      成功时响应 Set-Cookie 带 uin/skey/p_skey 等，再跟一次跳转链接收齐最终 cookie
///   3. 资料：GET c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_home_page?uin=… → creator.nick/headpic；
///      接口不通也不让登录失败，用扫码回调的昵称 + qlogo 头像兜底
/// 免费账号即可；不涉及会员购买与 VIP。
struct QQLoginService: Sendable {
    private let session: URLSession
    static let ptloginHost = "https://ssl.ptlogin2.qq.com"
    static let appID = "716027609"

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                "Referer": "https://y.qq.com/",
            ]
            self.session = URLSession(configuration: config)
        }
    }

    /// 一次轮询的结果。
    struct QQPollResult: Sendable {
        let status: QRLoginStatus
        /// 确认成功时：合并后的 Cookie 头值（uin/skey/p_skey/qrsig…）。
        let cookies: String?
        /// ptuiCB 第 6 个参数里的昵称（成功时才有）。
        let nickname: String?
    }

    /// 第 1 步：取二维码图片 + qrsig。
    func requestQR() async throws -> (image: Data, qrsig: String) {
        var components = URLComponents(string: Self.ptloginHost + "/ptqrshow")
        components?.queryItems = [
            URLQueryItem(name: "appid", value: Self.appID),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(format: "%.16f", Double.random(in: 0..<1))),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "0"),
        ]
        guard let url = components?.url else {
            throw ResolveError.hard("QQ 登录地址无效")
        }
        let (data, response) = try await data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty else {
            throw ResolveError.hard("QQ 登录二维码申请失败")
        }
        let jar = CookieJar.merge(CookieJar.setCookieValues(from: http), into: [:])
        guard let qrsig = jar["qrsig"], !qrsig.isEmpty else {
            throw ResolveError.hard("QQ 登录二维码申请失败")
        }
        return (data, qrsig)
    }

    /// 第 2 步：轮询一次。成功时跟一次跳转链接收齐最终 cookie。
    func check(qrsig: String) async throws -> QQPollResult {
        var components = URLComponents(string: Self.ptloginHost + "/ptqrlogin")
        components?.queryItems = [
            URLQueryItem(name: "u1", value: "https://y.qq.com/portal/profile.html"),
            URLQueryItem(name: "ptqrtoken", value: "\(Self.ptqrToken(qrsig: qrsig))"),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(Int(Date().timeIntervalSince1970 * 1000))"),
            URLQueryItem(name: "js_ver", value: "21072610"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "login_sig", value: ""),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: Self.appID),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "0"),
        ]
        guard let url = components?.url else {
            throw ResolveError.hard("QQ 登录地址无效")
        }
        var request = URLRequest(url: url)
        request.setValue("qrsig=\(qrsig)", forHTTPHeaderField: "Cookie")
        let (body, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: body, encoding: .utf8),
              let parsed = Self.parsePtuiCB(text) else {
            throw ResolveError.hard("QQ 扫码状态解析失败")
        }
        let status = QRLoginStateMachine.qqStatus(code: parsed.code)
        guard status == .confirmed else {
            return QQPollResult(status: status, cookies: nil, nickname: nil)
        }
        var jar = CookieJar.merge(
            CookieJar.setCookieValues(from: http), into: ["qrsig": qrsig])
        if let redirect = URL(string: parsed.url) {
            var follow = URLRequest(url: redirect)
            follow.setValue(CookieJar.headerValue(jar), forHTTPHeaderField: "Cookie")
            if let (_, followResponse) = try? await data(for: follow),
               let followHTTP = followResponse as? HTTPURLResponse {
                jar = CookieJar.merge(
                    CookieJar.setCookieValues(from: followHTTP), into: jar)
            }
        }
        return QQPollResult(
            status: .confirmed,
            cookies: CookieJar.headerValue(jar),
            nickname: parsed.nickname.isEmpty ? nil : parsed.nickname
        )
    }

    /// 第 3 步：取账号资料。接口不通也不抛错——用扫码回调的昵称 + qlogo 头像兜底。
    func fetchProfile(
        uin: String, cookie: String, fallbackNickname: String?
    ) async throws -> AccountProfile {
        var components = URLComponents(
            string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_home_page")
        components?.queryItems = [
            URLQueryItem(name: "uin", value: uin),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf-8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
        ]
        guard let url = components?.url else {
            throw ResolveError.hard("QQ 登录地址无效")
        }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        let (data, _) = try await data(for: request)
        let parsed = Self.parseProfile(data)
        return AccountProfile(
            platform: .qq,
            userID: uin,
            nickname: parsed?.nickname ?? fallbackNickname ?? "QQ 用户",
            avatarURL: parsed?.avatar ?? Self.qlogoAvatar(uin: uin)
        )
    }

    /// QQ 头像（只凭 uin 就能取的公开地址）。
    static func qlogoAvatar(uin: String) -> String {
        "https://q1.qlogo.cn/g?b=qq&nk=\(uin)&s=100"
    }

    // MARK: - 纯函数（可单测）

    /// ptqrtoken 算法（ptlogin 公开算法）：h = 0；对 qrsig 每个字符 h += (h << 5) + code；
    /// 返回 h & 0x7fffffff。
    /// 注意：必须用 wrapping 运算（&+ / &<<）——普通 +/<< 在字符稍多时就会整数溢出，
    /// Swift 默认会直接 trap（harness 实测抓到过）；JS 原实现是 32 位语义，
    /// wrapping 后取低 31 位与原实现结果一致。
    static func ptqrToken(qrsig: String) -> Int {
        var hash = 0
        for scalar in qrsig.unicodeScalars {
            hash = hash &+ ((hash &<< 5) &+ Int(scalar.value))
        }
        return hash & 0x7fffffff
    }

    /// 解析 ptuiCB('code','0','url','0','msg','nickname') 回调。
    /// 注意：非成功状态只有 5 个参数（没有昵称）；成功时才有第 6 个。
    /// 参数之间可能带空格，逐项 trim。昵称里带逗号/单引号是已知边界
    /// （这时昵称可能被截断，登录不受影响）。
    static func parsePtuiCB(_ text: String) -> (code: String, url: String, nickname: String)? {
        guard let start = text.firstIndex(of: "("),
              let end = text.lastIndex(of: ")") else { return nil }
        let inner = String(text[text.index(after: start)..<end])
        var parts: [String] = []
        var current = ""
        var inQuote = false
        for ch in inner {
            if ch == "'" { inQuote.toggle(); continue }
            if ch == "," && !inQuote { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        guard trimmed.count >= 5 else { return nil }
        return (trimmed[0], trimmed[2], trimmed.count >= 6 ? trimmed[5] : "")
    }

    /// 解析资料页：code == 0 才认；昵称/头像任一缺了就返回已有的那部分。
    static func parseProfile(_ data: Data) -> (nickname: String?, avatar: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let dataObject = json["data"] as? [String: Any] else { return nil }
        let creator = dataObject["creator"] as? [String: Any]
        let nickname = (creator?["nick"] as? String) ?? (dataObject["nick"] as? String)
        let avatar = (creator?["headpic"] as? String) ?? (dataObject["headpic"] as? String)
        return (nickname, avatar)
    }

    // MARK: - 内部

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ResolveErrorClassifier.classify(error)
        }
    }
}
