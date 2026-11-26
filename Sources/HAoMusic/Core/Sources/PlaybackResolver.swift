import Foundation

/// 解析结果的实际来源（播放页徽标只报实测来源与档位）。
enum ResolvedSource: Equatable, Sendable {
    case local
    case provider(MusicProvider)
    case unlock(AudioSourceID)
}

enum PlaybackResolution: Sendable {
    case ready(URL, AudioQuality?, ResolvedSource)
    case unplayable(String)
}

/// 播放解析管线（播放规则照 Kumone/Coda 的来，不另起炉灶）：
/// 1. 本地文件直接播；
/// 2. 手动点歌先清失败记忆；
/// 3. 主源取流（内部自动降档）；网络瞬断 400ms 后重试一次（Kumone）；
/// 4. 主源播不了 → 解锁竞速（Coda：并行跑，单源 8 秒，总 15 秒）；
/// 5. 硬错误记失败记忆，超时不记。
@MainActor
final class PlaybackResolver {
    private let settings: MusicSettings
    private let failureMemory: FailureMemory
    private let unlockService: UnlockService
    private let clients: [MusicProvider: any MusicProviderClient]

    init(
        settings: MusicSettings,
        failureMemory: FailureMemory,
        unlockService: UnlockService,
        clients: [MusicProvider: any MusicProviderClient]
    ) {
        self.settings = settings
        self.failureMemory = failureMemory
        self.unlockService = unlockService
        self.clients = clients
    }

    func resolve(track: Track, manual: Bool) async -> PlaybackResolution {
        if let localURL = track.localFileURL {
            return .ready(localURL, nil, .local)
        }
        if manual {
            failureMemory.clear(songID: track.id)
        }
        guard let provider = MusicProvider(rawValue: track.source),
              provider.isFullProvider,
              let songID = track.providerItemID else {
            return .unplayable("这首歌没有可播的音源")
        }

        var failed = failureMemory.failedSources(for: track.id)
        // 候选主源：origin 优先，合并搜索带过来的其余平台句柄按优先顺序补位。
        var candidates: [(MusicProvider, String)] = [(provider, songID)]
        let alts = track.altHandles.compactMap { (key, value) -> (MusicProvider, String)? in
            guard let alt = MusicProvider(rawValue: key), alt.isFullProvider else { return nil }
            return (alt, value)
        }.sorted { a, b in
            let priorityA = MusicProvider.searchPriority.firstIndex(of: a.0) ?? Int.max
            let priorityB = MusicProvider.searchPriority.firstIndex(of: b.0) ?? Int.max
            return priorityA < priorityB
        }
        candidates += alts
        // 全部候选主源 + 全部解锁源都刚失败过：直接判播不了，不再发请求。
        let allUnlockFailed = AudioSourceID.allCases
            .allSatisfy { failed.contains($0.rawValue) }
        let allCandidatesFailed = candidates.allSatisfy { failed.contains($0.0.rawValue) }
        if allCandidatesFailed && allUnlockFailed {
            return .unplayable("这首歌暂时播不了")
        }

        // 1) 主源取流（先 origin，再其余平台句柄；每个源内部自动降档）。
        for (index, (candidateProvider, candidateID)) in candidates.enumerated() {
            guard let client = clients[candidateProvider],
                  !failed.contains(candidateProvider.rawValue) else { continue }
            switch await tryPrimary(client: client, songID: candidateID, allowRetry: index == 0) {
            case let .ready(result):
                return .ready(result.url, result.actualQuality, .provider(candidateProvider))
            case .hardFailure:
                failureMemory.recordHardFailure(songID: track.id, sourceKey: candidateProvider.rawValue)
                failed.insert(candidateProvider.rawValue)
            case .notRecorded:
                break // 超时 / 瞬断重试后仍失败：不记
            }
        }

        // 2) 解锁竞速。
        guard settings.unlockEnabled else {
            return .unplayable("这首歌暂时播不了")
        }
        let unlockHandles: [MusicProvider: String] = {
            var handles: [MusicProvider: String] = [provider: songID]
            for (key, value) in track.altHandles {
                if let alt = MusicProvider(rawValue: key) {
                    handles[alt] = value
                }
            }
            return handles
        }()
        let song = ProviderSong.make(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkURL: track.artworkURL,
            handles: unlockHandles,
            origin: provider
        )
        let outcome = await unlockService.race(song: song, excluding: failed)
        for source in outcome.hardFailed {
            failureMemory.recordHardFailure(songID: track.id, sourceKey: source.rawValue)
        }
        if let (result, source) = outcome.result {
            return .ready(result.url, result.actualQuality, .unlock(source))
        }
        return .unplayable("这首歌暂时播不了")
    }

    private enum PrimaryOutcome {
        case ready(SongURLResult)
        case hardFailure
        case notRecorded
    }

    /// 主源取流：瞬断 400ms 后重试一次（只对第一个候选源重试，控制总耗时）；
    /// 重试后仍瞬断/超时不记失败记忆。
    private func tryPrimary(
        client: any MusicProviderClient,
        songID: String,
        allowRetry: Bool = true
    ) async -> PrimaryOutcome {
        for attempt in 0..<2 {
            do {
                if let result = try await client.songURL(
                    songID: songID, targetQuality: settings.targetQuality) {
                    return .ready(result)
                }
                return .hardFailure // 源内降档后仍无地址
            } catch {
                switch ResolveErrorClassifier.classify(error) {
                case .transient where attempt == 0 && allowRetry:
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                case .timeout:
                    return .notRecorded
                case .transient:
                    return .notRecorded
                case .hard:
                    return .hardFailure
                }
            }
        }
        return .notRecorded
    }
}
