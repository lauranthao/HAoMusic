import Foundation

/// 播放队列里的一项。解析后的播放地址存在这里（v1 即本地文件 URL）。
struct PlaybackItem: Identifiable, Equatable {
    let id: String
    let track: Track

    init(track: Track) {
        self.id = track.id
        self.track = track
    }

    var playURL: URL? { track.localFileURL }
}
