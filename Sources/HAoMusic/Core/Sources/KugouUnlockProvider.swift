#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// 酷狗解锁源（Kumone 的 fallback 思路；VM 侧未验证：mobilecdn.kugou.com
/// 从本机不通，trackercdn 未实测——失败即跳过，不影响主流程）。
struct KugouUnlockProvider: UnlockSource {
    let id: AudioSourceID = .kugou
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
        return try await fetchStreamURL(hash: best.credential)
    }

    private func search(keyword: String) async throws -> [UnlockCandidate]? {
        var components = URLComponents(string: "https://mobilecdn.kugou.com/api/v3/search/song")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "5"),
            URLQueryItem(name: "showtype", value: "1"),
        ]
        guard let url = components?.url else { return nil }
        let data = try await get(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = json["data"] as? [String: Any],
              let info = dataObject["info"] as? [[String: Any]] else { return nil }
        return info.compactMap { item in
            guard let hash = item["hash"] as? String, !hash.isEmpty,
                  let name = item["songname"] as? String else { return nil }
            let duration = (item["duration"] as? Double) ?? 0
            return UnlockCandidate(
                title: name,
                artist: item["singername"] as? String ?? "",
                duration: duration,
                credential: hash
            )
        }
    }

    /// tracker 取流：key = MD5(hash + "kgcloudv2")。
    private func fetchStreamURL(hash: String) async throws -> SongURLResult? {
        let key = MD5.digestHex(hash + "kgcloudv2")
        var components = URLComponents(string: "https://trackercdn.kugou.com/i/v2/")
        components?.queryItems = [
            URLQueryItem(name: "cmd", value: "23"),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "pid", value: "1"),
            URLQueryItem(name: "behavior", value: "play"),
        ]
        guard let url = components?.url else { return nil }
        let data = try await get(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["status"] as? Int == 1,
              let urlString = json["url"] as? String, !urlString.isEmpty,
              let streamURL = URL(string: urlString) else { return nil }
        let bitrate = (json["bitrate"] as? Int) ?? 0
        // 解锁源只报实测档位，且最高只报到 320K（不谎报无损）。
        let quality: AudioQuality = bitrate >= 320_000 ? .higher : .standard
        return SongURLResult(url: streamURL, bitrate: bitrate, actualQuality: quality)
    }

    private func get(url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ResolveError.hard("酷狗请求失败")
            }
            return data
        } catch {
            throw ResolveErrorClassifier.classify(error)
        }
    }
}
