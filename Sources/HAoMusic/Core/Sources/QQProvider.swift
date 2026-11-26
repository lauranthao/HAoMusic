#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// QQ 音乐客户端（匿名可用；会员不是必需的）。
///
/// 实测结论（2026-11-26，VM 直连验证）：
/// - 搜索通：client_search_cp，返回真实 songmid/media_mid。
/// - GetVkeyServer 匿名返回 500005（要登录）；CgiGetVkey 匿名通，返回 C400（128K m4a）。
///   所以 QQ 的降档链是：目标档位逐档试 GetVkeyServer → 全部失败后走 CgiGetVkey 拿 C400。
///   匿名只能到 128K，高档位需登录（后续再接）。
struct QQProvider: MusicProviderClient {
    let provider: MusicProvider = .qq
    private let session: URLSession
    private let guid: String
    /// 登录态才有的 Cookie（uin/skey/p_skey 等）。未登录时为 nil，请求与匿名时一字不差。
    private let cookieProvider: (@Sendable () -> String?)?
    /// 登录态才有的真实 uin；未登录回落到 "0"。
    private let uinProvider: (@Sendable () -> String?)?

    init(
        session: URLSession? = nil,
        guid: String? = nil,
        cookieProvider: (@Sendable () -> String?)? = nil,
        uinProvider: (@Sendable () -> String?)? = nil
    ) {
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
        // 设备 guid：本机生成一次存起来，不抄任何仓库里的固定值。
        if let guid {
            self.guid = guid
        } else if let saved = UserDefaults.standard.string(forKey: "haoMusic.qqGuid") {
            self.guid = saved
        } else {
            let generated = String(Int.random(in: 1_000_000_000...9_999_999_999))
            UserDefaults.standard.set(generated, forKey: "haoMusic.qqGuid")
            self.guid = generated
        }
        self.cookieProvider = cookieProvider
        self.uinProvider = uinProvider
    }

    // MARK: - 搜索

    func search(keyword: String, limit: Int) async throws -> [ProviderSong] {
        var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")
        components?.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "\(limit)"),
            URLQueryItem(name: "w", value: keyword),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else {
            throw ResolveError.hard("QQ 搜索地址无效")
        }
        let data = try await get(url: url)
        guard let json = try decodeJSONP(data) as? [String: Any],
              let dataObject = json["data"] as? [String: Any],
              let songObject = dataObject["song"] as? [String: Any],
              let list = songObject["list"] as? [[String: Any]] else {
            throw ResolveError.hard("QQ 搜索返回解析失败")
        }
        return list.compactMap { item in
            guard let songmid = item["songmid"] as? String,
                  let name = item["songname"] as? String else { return nil }
            let singers = (item["singer"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            let mediaMid = item["media_mid"] as? String ?? ""
            let albumMid = item["albummid"] as? String ?? ""
            let interval = item["interval"] as? Double ?? 0
            let artwork = albumMid.isEmpty ? nil : URL(string:
                "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg")
            // QQ 句柄是 "songmid|media_mid" 复合值，取流时拆开。
            return ProviderSong.make(
                title: name,
                artist: singers.joined(separator: "、"),
                album: item["albumname"] as? String ?? "",
                duration: interval,
                artworkURL: artwork,
                handles: [.qq: "\(songmid)|\(mediaMid)"],
                origin: .qq
            )
        }
    }

    // MARK: - 取流（内部自动降档）

    func songURL(songID: String, targetQuality: AudioQuality) async throws -> SongURLResult? {
        let parts = songID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let (songmid, mediaMid) = (parts[0], parts[1])

        // 降档链（任务要求）：目标档位 → F000 → M800 → M500 → C400。
        let targetFile = targetQuality.qqFilePrefix()
        var tried: [(prefix: String, ext: String)] = [targetFile]
        for file in [("F000", ".flac"), ("M800", ".mp3"), ("M500", ".mp3"), ("C400", ".m4a")] {
            if !tried.contains(where: { $0.prefix == file.0 }) {
                tried.append(file)
            }
        }
        for file in tried {
            let filename = "\(file.prefix)\(songmid)\(mediaMid)\(file.ext)"
            if let result = try await getVkeyServer(songmid: songmid, filename: filename) {
                return result
            }
        }
        // 2) 全部档位失败：CgiGetVkey 拿默认 C400（匿名可通）。
        return try await cgiGetVkey(songmid: songmid)
    }

    // MARK: - 歌词

    func lyrics(songID: String) async throws -> String? {
        let songmid = songID.split(separator: "|").first.map(String.init) ?? songID
        var components = URLComponents(
            string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")
        components?.queryItems = [
            URLQueryItem(name: "songmid", value: songmid),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "nobase64", value: "0"),
        ]
        guard let url = components?.url else { return nil }
        let data = try await get(url: url)
        guard let json = try decodeJSONP(data) as? [String: Any],
              let base64 = json["lyric"] as? String,
              let decoded = Data(base64Encoded: base64),
              let text = String(data: decoded, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 内部

    /// GetVkeyServer 请求体（内部方法，供 harness 验登录/匿名 uin 的差别）。
    /// 匿名：param.uin "0"、comm.uin 0；登录：真实 uin。
    func vkeyPayload(songmid: String, filename: String) -> [String: Any] {
        let uin = uinProvider?() ?? "0"
        return [
            "req_0": [
                "module": "vkey.GetVkeyServer",
                "method": "GetVkeyServer",
                "param": [
                    "guid": guid,
                    "songmid": [songmid],
                    "songtype": [0],
                    "uin": uin,
                    "loginflag": 1,
                    "platform": "20",
                    "filename": [filename],
                ],
            ],
            "comm": ["uin": Int(uin) ?? 0, "format": "json", "ct": 24, "cv": 0],
        ]
    }

    /// CgiGetVkey 请求体（内部方法，供 harness 验登录/匿名 uin 的差别）。
    func cgiGetVkeyPayload(songmid: String) -> [String: Any] {
        let uin = uinProvider?() ?? "0"
        return [
            "req_0": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "guid": guid,
                    "songmid": [songmid],
                    "songtype": [0],
                    "uin": uin,
                    "loginflag": 1,
                    "platform": "20",
                ],
            ],
            "comm": ["uin": Int(uin) ?? 0, "format": "json", "ct": 24, "cv": 0],
        ]
    }

    /// GetVkeyServer：按文件名取流。匿名返回 500005（无 data），按无地址处理，不抛错。
    /// 登录时带真实 uin + Cookie，服务端按账号给档位；匿名时 uin 仍是 "0"/0，与原来一字不差。
    private func getVkeyServer(songmid: String, filename: String) async throws -> SongURLResult? {
        let payload = vkeyPayload(songmid: songmid, filename: filename)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let dataString = String(data: data, encoding: .utf8) else { return nil }
        var components = URLComponents(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "data", value: dataString),
        ]
        guard let url = components?.url else { return nil }
        let raw = try await get(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let req0 = json["req_0"] as? [String: Any],
              req0["code"] as? Int == 0,
              let dataObject = req0["data"] as? [String: Any],
              let midInfo = (dataObject["midurlinfo"] as? [[String: Any]])?.first,
              let purl = midInfo["purl"] as? String, !purl.isEmpty,
              let sip = (dataObject["sip"] as? [String])?.first else { return nil }
        guard let streamURL = URL(string: sip + purl) else { return nil }
        let bitrate = bitrate(forFilename: filename)
        return SongURLResult(
            url: streamURL,
            bitrate: bitrate,
            actualQuality: AudioQuality.fromBitrate(bitrate)
        )
    }

    /// CgiGetVkey：匿名可通，返回默认 C400 文件（128K m4a）。
    /// 登录时带真实 uin + Cookie；匿名时与原来一字不差。
    private func cgiGetVkey(songmid: String) async throws -> SongURLResult? {
        let uin = uinProvider?() ?? "0"
        let payload = cgiGetVkeyPayload(songmid: songmid)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let dataString = String(data: data, encoding: .utf8) else { return nil }
        var components = URLComponents(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")
        components?.queryItems = [
            URLQueryItem(name: "-", value: "getplaysongvkey2682247447678878"),
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "loginUin", value: uin),
            URLQueryItem(name: "hostUin", value: uin),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
            URLQueryItem(name: "data", value: dataString),
        ]
        guard let url = components?.url else { return nil }
        let raw = try await get(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let req0 = json["req_0"] as? [String: Any],
              req0["code"] as? Int == 0,
              let dataObject = req0["data"] as? [String: Any],
              let testFile = (dataObject["testfilewifi"] as? String)
                ?? (dataObject["testfile2g"] as? String),
              !testFile.isEmpty,
              let sip = (dataObject["sip"] as? [String])?.dropFirst().first,
              let streamURL = URL(string: sip + testFile) else { return nil }
        return SongURLResult(
            url: streamURL,
            bitrate: 128_000,
            actualQuality: .standard
        )
    }

    private func bitrate(forFilename filename: String) -> Int {
        if filename.hasPrefix("F000") { return 900_000 }
        if filename.hasPrefix("M800") { return 320_000 }
        return 128_000
    }

    private func get(url: URL) async throws -> Data {
        let request = requestWithSessionHeaders(URLRequest(url: url))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ResolveError.hard("QQ 请求失败")
            }
            return data
        } catch {
            throw ResolveErrorClassifier.classify(error)
        }
    }

    /// 登录态才给请求加 Cookie 头；未登录返回原请求（匿名行为一字不差）。
    /// 内部方法，供 harness 验登录/匿名请求的差别。
    func requestWithSessionHeaders(_ request: URLRequest) -> URLRequest {
        guard let cookie = cookieProvider?(), !cookie.isEmpty else { return request }
        var request = request
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        return request
    }

    /// JSONP 去壳：取第一个 "{" 到最后一个 "}" 之间的内容。
    private func decodeJSONP(_ data: Data) throws -> Any {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            throw ResolveError.hard("QQ 返回解析失败")
        }
        let jsonText = String(text[start...end])
        guard let jsonData = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) else {
            throw ResolveError.hard("QQ 返回解析失败")
        }
        return object
    }
}
