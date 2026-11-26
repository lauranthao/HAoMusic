import Foundation

/// 一次取流的结果：只报实测档位。
struct SongURLResult: Sendable {
    let url: URL
    let bitrate: Int // bps；0 表示未知
    let actualQuality: AudioQuality
}

/// 各平台取流客户端的统一接口（Coda 的统一门面思路；HAo 的接口形状自己定）。
/// songURL 内部负责本平台的自动降档：从目标档位往下试，直到有可播地址或全部试完；
/// 全部试完返回 nil（不是抛错），由 PlaybackResolver 决定要不要走解锁。
/// 抛错只用于传输/解析问题，由 PlaybackResolver 按瞬断/硬错误分类。
protocol MusicProviderClient: Sendable {
    var provider: MusicProvider { get }
    func search(keyword: String, limit: Int) async throws -> [ProviderSong]
    func songURL(songID: String, targetQuality: AudioQuality) async throws -> SongURLResult?
    func lyrics(songID: String) async throws -> String?
}

/// 把 URLSession/解码错误按瞬断/硬错误分类（PlaybackResolver 靠它决定重试还是记失败）。
/// 取消（CancellationError）算超时那一类：用户切歌/超时取消都不是服务器的硬拒绝，不记失败记忆。
enum ResolveErrorClassifier {
    static func classify(_ error: Error) -> ResolveError {
        if let resolveError = error as? ResolveError {
            return resolveError
        }
        if error is CancellationError {
            return .timeout
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .transient(urlError.localizedDescription)
            default:
                return .hard(urlError.localizedDescription)
            }
        }
        return .hard(error.localizedDescription)
    }
}
