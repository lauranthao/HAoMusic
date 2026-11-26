import Foundation

/// 失败记忆：只记硬错误，不记超时（chen 的播放规则；超时窗口 10 分钟与
/// Coda 的解锁匹配缓存窗口一致）。
/// - 主源 / 解锁源明确说播不了（无地址、被拒绝）才记；
/// - 网络瞬断、单源超时、总超时都不记；
/// - 手动点歌先清掉这首歌的失败记忆（用户明确要这首歌）。
@MainActor
final class FailureMemory {
    /// 失败 10 分钟后过期（过期即忘掉，下次再试）。
    static let expiry: TimeInterval = 600

    private var failed: [String: [String: Date]] = [:]
    private let defaultsKey = "haoMusic.failureMemory"

    init() {
        load()
    }

    func recordHardFailure(songID: String, sourceKey: String) {
        failed[songID, default: [:]][sourceKey] = Date()
        save()
    }

    func failedSources(for songID: String, asOf: Date = Date()) -> Set<String> {
        pruneExpired(asOf: asOf)
        guard let sources = failed[songID] else { return [] }
        return Set(sources.keys)
    }

    /// 手动点歌先清（用户明确要这首歌）。
    func clear(songID: String) {
        failed.removeValue(forKey: songID)
        save()
    }

    func pruneExpired(asOf: Date = Date()) {
        let cutoff = asOf.addingTimeInterval(-Self.expiry)
        for (songID, sources) in failed {
            let kept = sources.filter { $0.value > cutoff }
            if kept.isEmpty {
                failed.removeValue(forKey: songID)
            } else {
                failed[songID] = kept
            }
        }
    }

    // MARK: - 持久化（只存本机）

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else {
            return
        }
        failed = decoded.mapValues { dict in
            dict.mapValues { Date(timeIntervalSince1970: $0) }
        }
        pruneExpired()
    }

    private func save() {
        let encoded = failed.mapValues { dict in
            dict.mapValues { $0.timeIntervalSince1970 }
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
