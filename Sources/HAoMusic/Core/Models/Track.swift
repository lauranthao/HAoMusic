import Foundation

/// 一首曲目。本地曲目 source == "local"；网络曲目 source 是平台（netease/qq），
/// providerItemID 是该平台内的歌曲 ID（QQ 是 "songmid|media_mid" 复合值）。
/// altHandles 是合并搜索带过来的其他平台句柄：主源播不了时先试它（同首歌换个平台），
/// 再走解锁。key 是 MusicProvider.rawValue。
struct Track: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double // 秒；0 表示未知
    var artworkURL: URL?
    var localFileURL: URL?
    var source: String
    var providerItemID: String?
    var altHandles: [String: String] = [:]

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String = "未知歌手",
        album: String = "",
        duration: Double = 0,
        artworkURL: URL? = nil,
        localFileURL: URL? = nil,
        source: String = "local",
        providerItemID: String? = nil,
        altHandles: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.localFileURL = localFileURL
        self.source = source
        self.providerItemID = providerItemID
        self.altHandles = altHandles
    }

    /// 本地文件曲目：从文件 URL 建一个 Track，标题取文件名。
    static func localFile(url: URL, duration: Double = 0) -> Track {
        Track(
            title: url.deletingPathExtension().lastPathComponent,
            duration: duration,
            localFileURL: url,
            source: "local"
        )
    }
}
