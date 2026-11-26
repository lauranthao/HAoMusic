import Foundation

/// 一首曲目。v1 只有本地曲目（source == "local"）；网络曲库后续接入。
struct Track: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double // 秒；0 表示未知
    var artworkURL: URL?
    var localFileURL: URL?
    var source: String

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String = "未知歌手",
        album: String = "",
        duration: Double = 0,
        artworkURL: URL? = nil,
        localFileURL: URL? = nil,
        source: String = "local"
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.localFileURL = localFileURL
        self.source = source
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
