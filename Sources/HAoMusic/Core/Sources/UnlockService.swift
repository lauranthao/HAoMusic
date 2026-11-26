#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// 解锁源 ID：镜像（pyncmd 兼容，用户自填地址）→ 酷狗 → 酷我。
/// 顺序照 Kumone（镜像 → 酷狗 → 酷我）；竞速机制照 Coda（并行跑，最早成功者胜出）。
enum AudioSourceID: String, CaseIterable, Sendable {
    case mirror
    case kugou
    case kuwo

    var displayName: String {
        switch self {
        case .mirror: return "镜像"
        case .kugou: return "酷狗"
        case .kuwo: return "酷我"
        }
    }
}

/// 解锁源协议：按歌名/歌手/时长找替代音源。
protocol UnlockSource: Sendable {
    var id: AudioSourceID { get }
    func resolve(song: ProviderSong) async throws -> SongURLResult?
}

/// pyncmd 兼容镜像（用户自填地址；留空则不用）。
/// HAo 不内置任何第三方镜像地址（别人的服务随时可失效）。
struct MirrorUnlockSource: UnlockSource {
    let id: AudioSourceID = .mirror
    let baseURL: String
    private let session: URLSession

    init(baseURL: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 8
            self.session = URLSession(configuration: config)
        }
    }

    func resolve(song: ProviderSong) async throws -> SongURLResult? {
        guard let neteaseID = song.handle(for: .netease) else { return nil }
        var components = URLComponents(string: baseURL + "/api.php")
        components?.queryItems = [
            URLQueryItem(name: "types", value: "url"),
            URLQueryItem(name: "source", value: "netease"),
            URLQueryItem(name: "id", value: neteaseID),
            URLQueryItem(name: "br", value: "320"),
        ]
        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ResolveError.hard("镜像请求失败")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bitrate = json["br"] as? Int, bitrate > 0,
                  let urlString = json["url"] as? String, !urlString.isEmpty,
                  let streamURL = URL(string: urlString) else { return nil }
            return SongURLResult(
                url: streamURL,
                bitrate: bitrate * 1000,
                actualQuality: AudioQuality.fromBitrate(bitrate * 1000)
            )
        } catch {
            throw ResolveErrorClassifier.classify(error)
        }
    }
}

struct UnlockRaceOutcome: Sendable {
    let result: (SongURLResult, AudioSourceID)?
    /// 硬失败的源（超时不算，调用方只记硬失败）。
    let hardFailed: Set<AudioSourceID>
}

/// 解锁竞速（Coda 的规则）：
/// - 全部可用源同时跑，单源 8 秒超时，总上限 15 秒，最早成功者胜出；
/// - 源按 Kumone 的优先顺序启动：镜像 → 酷狗 → 酷我。
@MainActor
final class UnlockService {
    private let sources: [any UnlockSource]

    init(settings: MusicSettings) {
        var sources: [any UnlockSource] = []
        let mirror = settings.mirrorBaseURL.trimmingCharacters(in: .whitespaces)
        if !mirror.isEmpty {
            sources.append(MirrorUnlockSource(baseURL: mirror))
        }
        sources.append(KugouUnlockProvider())
        sources.append(KuwoUnlockProvider())
        self.sources = sources
    }

    /// 测试用：直接注入解锁源。
    init(sources: [any UnlockSource]) {
        self.sources = sources
    }

    func race(
        song: ProviderSong,
        excluding: Set<String>
    ) async -> UnlockRaceOutcome {
        let available = sources.filter { !excluding.contains($0.id.rawValue) }
        guard !available.isEmpty else {
            return UnlockRaceOutcome(result: nil, hardFailed: [])
        }
        do {
            return try await withTimeout(seconds: 15) {
                await Self.runRace(sources: available, song: song)
            }
        } catch {
            // 总超时：什么都不记，调用方按播不了处理。
            return UnlockRaceOutcome(result: nil, hardFailed: [])
        }
    }

    private static func runRace(
        sources: [any UnlockSource],
        song: ProviderSong
    ) async -> UnlockRaceOutcome {
        await withTaskGroup(of: (AudioSourceID, Result<SongURLResult?, Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let result = try await withTimeout(seconds: 8) {
                            try await source.resolve(song: song)
                        }
                        return (source.id, .success(result))
                    } catch {
                        return (source.id, .failure(error))
                    }
                }
            }
            var hardFailed: Set<AudioSourceID> = []
            var finished = 0
            for await (id, outcome) in group {
                finished += 1
                switch outcome {
                case .success(let urlResult):
                    if let urlResult {
                        group.cancelAll()
                        return UnlockRaceOutcome(result: (urlResult, id), hardFailed: hardFailed)
                    }
                    hardFailed.insert(id) // 源返回空 = 该源无地址（硬失败）
                case .failure(let error):
                    if case .hard = ResolveErrorClassifier.classify(error) {
                        hardFailed.insert(id)
                    }
                    // 超时 / 瞬断不记
                }
                if finished == sources.count {
                    break
                }
            }
            return UnlockRaceOutcome(result: nil, hardFailed: hardFailed)
        }
    }
}
