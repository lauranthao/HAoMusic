#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// 网易云客户端（eapi，匿名可用；会员不是必需的）。
///
/// 实测结论（2026-11-26，VM 直连验证）：
/// - 搜索通：/eapi/cloudsearch/pc，code 200，返回真实歌曲。
/// - 取流加密正确（与参考实现逐字节一致），但本机出口 IP 匿名取流全部 404
///   （eapi/weapi 都一样，应是服务端地域/登录限制）；代码里 404 按降档 + 解锁走，
///   需在国内真机 / 免费账号登录后验证。
struct NeteaseProvider: MusicProviderClient {
    let provider: MusicProvider = .netease
    private let session: URLSession

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

    // MARK: - 搜索

    func search(keyword: String, limit: Int) async throws -> [ProviderSong] {
        let object: [String: Any] = [
            "s": keyword, "type": 1, "limit": limit, "offset": 0, "total": true,
        ]
        let data = try await postEAPI(
            path: "/eapi/cloudsearch/pc", cryptoURL: "/api/cloudsearch/pc", object: object)
        let response = try decode(SearchResponse.self, from: data)
        guard response.code == 200 else {
            throw ResolveError.hard("网易搜索失败（code \(response.code)）")
        }
        return response.result.songs.map { song in
            ProviderSong.make(
                title: song.name,
                artist: song.ar.map { $0.name }.joined(separator: "、"),
                album: song.al.name,
                duration: Double(song.dt) / 1000,
                artworkURL: URL(string: song.al.picUrl ?? ""),
                handles: [.netease: "\(song.id)"],
                origin: .netease
            )
        }
    }

    // MARK: - 取流（内部自动降档）

    func songURL(songID: String, targetQuality: AudioQuality) async throws -> SongURLResult? {
        for level in AudioQuality.downgradeChain(from: targetQuality) {
            let object: [String: Any] = [
                "ids": "[\(songID)]",
                "level": level.neteaseLevel,
                "encodeType": level.neteaseEncodeType,
                "header": NeteaseCrypto.eapiHeader(),
            ]
            let data = try await postEAPI(
                path: "/eapi/song/enhance/player/url/v1",
                cryptoURL: "/api/song/enhance/player/url/v1",
                object: object)
            let response = try decode(SongURLResponse.self, from: data)
            guard let entry = response.data.first else { continue }
            // 有试听信息 = 只有试听片段，按播不了处理，继续降档。
            guard entry.code == 200,
                  let urlString = entry.url, !urlString.isEmpty,
                  entry.freeTrialInfo == nil,
                  let url = URL(string: urlString) else { continue }
            return SongURLResult(
                url: url,
                bitrate: entry.br,
                actualQuality: AudioQuality.fromBitrate(entry.br)
            )
        }
        return nil
    }

    // MARK: - 歌词

    func lyrics(songID: String) async throws -> String? {
        let object: [String: Any] = ["id": songID, "lv": -1, "tv": -1]
        let data = try await postEAPI(
            path: "/eapi/song/lyric", cryptoURL: "/api/song/lyric", object: object)
        let response = try decode(LyricResponse.self, from: data)
        let text = response.lrc?.lyric
        return (text?.isEmpty == false) ? text : nil
    }

    // MARK: - 内部

    private func postEAPI(path: String, cryptoURL: String, object: [String: Any]) async throws -> Data {
        guard let params = NeteaseCrypto.eapiParams(url: cryptoURL, object: object) else {
            throw ResolveError.hard("网易请求加密失败")
        }
        guard let url = URL(string: NeteaseCrypto.apiHost + path) else {
            throw ResolveError.hard("网易地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params["params"].map {
            "params=\($0)".data(using: .utf8) ?? Data()
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ResolveError.hard("网易请求失败")
            }
            return data
        } catch {
            throw ResolveErrorClassifier.classify(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ResolveError.hard("网易返回解析失败")
        }
    }

    // MARK: - 响应模型

    private struct SearchResponse: Decodable {
        let code: Int
        let result: SearchResult
    }

    private struct SearchResult: Decodable {
        let songCount: Int
        let songs: [SearchSong]
    }

    private struct SearchSong: Decodable {
        let id: Int
        let name: String
        let ar: [SearchArtist]
        let al: SearchAlbum
        let dt: Int
    }

    private struct SearchArtist: Decodable {
        let name: String
    }

    private struct SearchAlbum: Decodable {
        let name: String
        let picUrl: String?
    }

    private struct SongURLResponse: Decodable {
        let code: Int
        let data: [SongURLEntry]
    }

    private struct SongURLEntry: Decodable {
        let url: String?
        let br: Int
        let code: Int
        let freeTrialInfo: FreeTrialInfo?
    }

    private struct FreeTrialInfo: Decodable {
        let start: Int?
        let end: Int?
    }

    private struct LyricResponse: Decodable {
        let code: Int
        let lrc: LyricBody?
    }

    private struct LyricBody: Decodable {
        let lyric: String?
    }
}
