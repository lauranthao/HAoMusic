import Foundation

/// 播放队列里的一项。解析后的播放地址存在这里（本地文件 URL 或解析出的网络地址）。
struct PlaybackItem: Identifiable, Equatable {
    let id: String
    let track: Track
    /// 解析出的网络播放地址（本地文件不用解析）。
    var resolvedURL: URL?
    /// 实测档位（只报实测；本地文件为 nil）。
    var resolvedQuality: AudioQuality?
    /// 实际来源（主源 / 解锁源 / 本地）。
    var resolvedSource: ResolvedSource?
    /// 从哪里点进来的（每次播放都记）。
    var playSource: PlaySource

    init(track: Track, playSource: PlaySource = .unknown) {
        self.id = track.id
        self.track = track
        self.playSource = playSource
    }

    var playURL: URL? { resolvedURL ?? track.localFileURL }

    /// 需要解析的网络曲目（没有本地文件、来源不是 local）。
    var needsResolution: Bool {
        track.localFileURL == nil && track.source != "local"
    }
}
