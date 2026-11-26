#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// 网易云扫码登录（公开的二维码登录流程，与 NeteaseCloudMusicApi 的
/// /login/qr/key、/login/qr/create、/login/qr/check、/user/account 一致，
/// 自己实现，不抄任何仓库的代码）：
///   1. unikey：GET /api/login/qrcode/unikey?type=1 → { code, unikey }
///   2. 二维码：GET /api/login/qrcode/create?key=&qrimg=true&type=1 → data.qrimg（base64 data URL）
///   3. 轮询：GET /api/login/qrcode/check?key=&type=1 → code 801 等待 / 802 已扫 / 803 成功（带 cookie）/ 800 过期
///   4. 资料：POST /api/nuser/account/get（带 Cookie）→ profile
/// 免费账号即可；不涉及会员购买与 VIP。
struct NeteaseLoginService: Sendable {
    private let session: URLSession
    static let host = "https://music.163.com"

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.httpAdditionalHeaders = NeteaseCrypto.defaultHeaders()
            self.session = URLSession(configuration: config)
        }
    }

    /// 第 1 步：申请 unikey。
    func requestUnikey() async throws -> String {
        guard let url = URL(string: Self.host + "/api/login/qrcode/unikey?type=1") else {
            throw ResolveError.hard("网易登录地址无效")
        }
        let data = try await get(url: url)
        return try Self.parseUnikey(data)
    }

    /// 第 2 步：取二维码图片（PNG 字节）。
    func qrImage(unokey: String) async throws -> Data {
        var components = URLComponents(string: Self.host + "/api/login/qrcode/create")
        components?.queryItems = [
            URLQueryItem(name: "key", value: unokey),
            URLQueryItem(name: "qrimg", value: "true"),
            URLQueryItem(name: "type", value: "1"),
        ]
        guard let url = components?.url else {
            throw ResolveError.hard("网易登录地址无效")
        }
        let data = try await get(url: url)
        return try Self.parseQRImage(data)
    }

    /// 第 3 步：轮询一次。803 成功时带回登录 cookie。
    func check(unokey: String) async throws -> (status: QRLoginStatus, cookie: String?) {
        var components = URLComponents(string: Self.host + "/api/login/qrcode/check")
        components?.queryItems = [
            URLQueryItem(name: "key", value: unokey),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "timestamp", value: "\(Int(Date().timeIntervalSince1970 * 1000))"),
        ]
        guard let url = components?.url else {
            throw ResolveError.hard("网易登录地址无效")
        }
        let data = try await get(url: url)
        return try Self.parseCheck(data)
    }

    /// 第 4 步：用 cookie 取账号资料（code != 200 = 凭证已失效）。
    func fetchProfile(cookie: String) async throws -> AccountProfile {
        guard let url = URL(string: Self.host + "/api/nuser/account/get") else {
            throw ResolveError.hard("网易登录地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let data = try await data(for: request)
        return try Self.parseProfile(data)
    }

    // MARK: - 纯解析（可单测）

    static func parseUnikey(_ data: Data) throws -> String {
        struct Response: Decodable { let code: Int; let unikey: String? }
        let response = try decode(Response.self, from: data)
        guard response.code == 200, let key = response.unikey, !key.isEmpty else {
            throw ResolveError.hard("网易登录二维码申请失败")
        }
        return key
    }

    static func parseQRImage(_ data: Data) throws -> Data {
        struct Response: Decodable {
            let code: Int
            let data: QRData?
        }
        struct QRData: Decodable { let qrurl: String?; let qrimg: String? }
        let response = try decode(Response.self, from: data)
        guard response.code == 200,
              let qrimg = response.data?.qrimg,
              let comma = qrimg.firstIndex(of: ","),
              let png = Data(base64Encoded: String(qrimg[qrimg.index(after: comma)...])),
              !png.isEmpty else {
            throw ResolveError.hard("网易登录二维码生成失败")
        }
        return png
    }

    static func parseCheck(_ data: Data) throws -> (status: QRLoginStatus, cookie: String?) {
        struct Response: Decodable { let code: Int; let cookie: String? }
        let response = try decode(Response.self, from: data)
        return (QRLoginStateMachine.neteaseStatus(code: response.code), response.cookie)
    }

    static func parseProfile(_ data: Data) throws -> AccountProfile {
        struct Response: Decodable { let code: Int; let profile: ProfileBody? }
        struct ProfileBody: Decodable {
            let userId: Int
            let nickname: String
            let avatarUrl: String?
        }
        let response = try decode(Response.self, from: data)
        guard response.code == 200, let profile = response.profile else {
            throw ResolveError.hard("登录已过期，请重新扫码")
        }
        return AccountProfile(
            platform: .netease,
            userID: "\(profile.userId)",
            nickname: profile.nickname,
            avatarURL: profile.avatarUrl
        )
    }

    // MARK: - 内部

    private func get(url: URL) async throws -> Data {
        try await data(for: URLRequest(url: url))
    }

    private func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ResolveError.hard("网易登录请求失败")
            }
            return data
        } catch {
            throw ResolveErrorClassifier.classify(error)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ResolveError.hard("网易登录返回解析失败")
        }
    }
}
