import Foundation

/// 合并搜索的更新：先出第一批（约 1 秒内），再出完整合并结果。
/// HAo 自己的层：两家参照都没有合并搜索——HAo 是多平台并行搜 + 去重 + 网易优先。
enum SearchUpdate: Sendable {
    case partial([ProviderSong])
    case final([ProviderSong])
}

/// 多平台结果合并（纯函数，可单测）：
/// 同首歌（同一 haoID）合并句柄；网易来源的排前面，QQ 补位；同平台内保持搜索原顺序。
enum HaoSongMerger {
    static func merge(_ songs: [ProviderSong]) -> [ProviderSong] {
        var order: [String] = []
        var byID: [String: ProviderSong] = [:]
        for song in songs {
            if let existing = byID[song.haoID] {
                byID[song.haoID] = existing.merged(with: song)
            } else {
                order.append(song.haoID)
                byID[song.haoID] = song
            }
        }
        let merged = order.compactMap { byID[$0] }
        return merged.enumerated().sorted { a, b in
            let priorityA = MusicProvider.searchPriority.firstIndex(of: a.element.origin) ?? Int.max
            let priorityB = MusicProvider.searchPriority.firstIndex(of: b.element.origin) ?? Int.max
            if priorityA != priorityB { return priorityA < priorityB }
            return a.offset < b.offset
        }.map { $0.element }
    }
}

/// 网络曲库统一门面（Coda 的统一门面思路；HAo 的合并搜索是自己的层）。
/// 搜索 / 取流 / 歌词按当前启用的平台分支；不支持的功能不发请求（见 CapabilityCatalog）。
@MainActor
final class HaoMusicService: ObservableObject {
    let settings: MusicSettings
    let failureMemory = FailureMemory()
    let resolver: PlaybackResolver
    private let clients: [MusicProvider: any MusicProviderClient]
    private let unlockService: UnlockService

    convenience init(settings: MusicSettings) {
        self.init(
            settings: settings,
            clients: [.netease: NeteaseProvider(), .qq: QQProvider()]
        )
    }

    /// 测试 / 自定义客户端用：直接注入平台客户端。
    init(settings: MusicSettings, clients: [MusicProvider: any MusicProviderClient]) {
        self.settings = settings
        self.clients = clients
        self.unlockService = UnlockService(settings: settings)
        self.resolver = PlaybackResolver(
            settings: settings,
            failureMemory: failureMemory,
            unlockService: unlockService,
            clients: clients
        )
    }

    /// 合并搜索：网易 + QQ 并行搜，先回来的先出第一批，最后出完整合并结果。
    /// 哪个平台失败只丢它自己的结果，不影响另一个。
    func searchMerged(query: String) -> AsyncStream<SearchUpdate> {
        let providers = settings.searchProviders
        let clients = self.clients
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: [ProviderSong].self) { group in
                    for provider in providers {
                        guard let client = clients[provider],
                              CapabilityCatalog.supports(.search, provider: provider) else { continue }
                        group.addTask {
                            (try? await client.search(keyword: query, limit: 30)) ?? []
                        }
                    }
                    var merged: [ProviderSong] = []
                    for await songs in group {
                        merged = HaoSongMerger.merge(merged + songs)
                        continuation.yield(.partial(merged))
                    }
                    continuation.yield(.final(merged))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 歌词：按曲目来源平台取 LRC 文本；没有返回 nil（播放页诚实显示“暂无歌词”）。
    func lyrics(for track: Track) async -> String? {
        guard let provider = MusicProvider(rawValue: track.source),
              CapabilityCatalog.supports(.lyrics, provider: provider),
              let songID = track.providerItemID,
              let client = clients[provider] else { return nil }
        return try? await client.lyrics(songID: songID)
    }
}
