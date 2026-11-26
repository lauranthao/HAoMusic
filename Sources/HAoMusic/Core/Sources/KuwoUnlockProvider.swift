#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
import Foundation

/// 酷我解锁源（Kumone 的 fallback 思路）。
///
/// 实测结论（2026-11-26，VM 直连验证）：
/// - search.kuwo.cn/r.s 能搜到歌，但返回的是单引号 JS 对象字面量（不是严格 JSON），
///   所以用 JavaScriptCore 求值解析。
/// - anti.s 转换未在 VM 实测；占位音频过滤按 Kumone 的规则：URL 含 "/nf/resource/" 的不要。
struct KuwoUnlockProvider: UnlockSource {
    let id: AudioSourceID = .kuwo
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 8
            config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0"]
            self.session = URLSession(configuration: config)
        }
    }

    func resolve(song: ProviderSong) async throws -> SongURLResult? {
        let query = "\(song.title) \(song.artist)"
        guard let candidates = try await search(keyword: query),
              let best = HaoSongMatcher.bestMatch(candidates: candidates, song: song) else {
            return nil
        }
        return try await convertURL(musicRID: best.credential)
    }

    private func search(keyword: String) async throws -> [UnlockCandidate]? {
        var components = URLComponents(string: "https://search.kuwo.cn/r.s")
        components?.queryItems = [
            URLQueryItem(name: "all", value: keyword),
            URLQueryItem(name: "ft", value: "music"),
            URLQueryItem(name: "itemset", value: "web_2013"),
            URLQueryItem(name: "client", value: "kt"),
            URLQueryItem(name: "pn", value: "0"),
            URLQueryItem(name: "rn", value: "5"),
            URLQueryItem(name: "rformat", value: "json"),
            URLQueryItem(name: "encoding", value: "utf8"),
        ]
        guard let url = components?.url else { return nil }
        let data = try await get(url: url)
        return parseSearchResponse(data)
    }

    /// r.s 返回单引号 JS 字面量：用 JavaScriptCore 求值成字典再取 abslist。
    /// Linux 上无 JavaScriptCore，返回空（本文件其余逻辑仍可类型检查）。
    private func parseSearchResponse(_ data: Data) -> [UnlockCandidate]? {
        #if canImport(JavaScriptCore)
        guard let text = String(data: data, encoding: .utf8),
              let context = JSContext(),
              let value = context.evaluateScript("(\(text))"),
              let object = value.toDictionary() as? [String: Any],
              let list = object["abslist"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let rid = item["MUSICRID"] as? String, !rid.isEmpty,
                  let name = item["SONGNAME"] as? String else { return nil }
            let duration = Double(item["DURATION"] as? String ?? "") ?? 0
            return UnlockCandidate(
                title: name,
                artist: item["ARTIST"] as? String ?? "",
                duration: duration,
                credential: rid
            )
        }
        #else
        return nil
        #endif
    }

    /// anti.s 转直链；11 秒占位音频（URL 含 /nf/resource/）不要。
    private func convertURL(musicRID: String) async throws -> SongURLResult? {
        var components = URLComponents(string: "https://antiserver.kuwo.cn/anti.s")
        components?.queryItems = [
            URLQueryItem(name: "type", value: "convert_url"),
            URLQueryItem(name: "br", value: "128kmp3"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "response", value: "url"),
            URLQueryItem(name: "rid", value: musicRID),
        ]
        guard let url = components?.url else { return nil }
        let data = try await get(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String, !urlString.isEmpty,
              !urlString.contains("/nf/resource/"),
              let streamURL = URL(string: urlString) else { return nil }
        return SongURLResult(url: streamURL, bitrate: 128_000, actualQuality: .standard)
    }

    private func get(url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ResolveError.hard("酷我请求失败")
            }
            return data
        } catch {
            throw ResolveErrorClassifier.classify(error)
        }
    }
}
