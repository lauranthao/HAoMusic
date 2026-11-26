import Foundation

/// 跨平台统一曲目模型：一首歌在各平台的句柄都挂在这里。
///
/// HAo 自己的做法（与 Coda 不同）：
/// - 跨平台稳定 ID 不用 SHA-256，用 FNV-1a 64 位指纹：同一首歌（标题 + 歌手 + 时长桶）
///   在哪个平台搜到都是同一个 haoID，合并搜索靠它去重；纯 Swift 实现，无需 CryptoKit。
/// - handles 用平台 rawValue 当 key，避免枚举键的 Codable 坑。
struct ProviderSong: Identifiable, Equatable, Hashable, Codable, Sendable {
    let haoID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double // 秒；0 表示未知
    var artworkURL: URL?
    /// 各平台句柄：key 是 MusicProvider.rawValue，value 是平台内的歌曲 ID。
    /// QQ 的句柄是 "songmid|media_mid" 复合值，取流时再拆开。
    var handles: [String: String]
    var origin: MusicProvider

    var id: String { haoID }

    /// 该曲目在哪些平台有句柄（按搜索优先顺序排）。
    var providers: [MusicProvider] {
        MusicProvider.searchPriority.filter { handles[$0.rawValue] != nil }
            + MusicProvider.allCases.filter {
                !MusicProvider.searchPriority.contains($0) && handles[$0.rawValue] != nil
            }
    }

    func handle(for provider: MusicProvider) -> String? {
        handles[provider.rawValue]
    }

    static func make(
        title: String,
        artist: String,
        album: String = "",
        duration: Double = 0,
        artworkURL: URL? = nil,
        handles: [MusicProvider: String],
        origin: MusicProvider
    ) -> ProviderSong {
        let key = HaoSongID.key(title: title, artist: artist, duration: duration)
        return ProviderSong(
            haoID: HaoSongID.fingerprint(key),
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: artworkURL,
            handles: Dictionary(uniqueKeysWithValues: handles.map { ($0.key.rawValue, $0.value) }),
            origin: origin
        )
    }

    /// 两个平台搜到同一首歌时合并：句柄并集，origin 取优先平台，缺失字段互补。
    func merged(with other: ProviderSong) -> ProviderSong {
        var handles = self.handles
        for (key, value) in other.handles {
            handles[key] = value
        }
        let origin = MusicProvider.searchPriority.first(where: { handles[$0.rawValue] != nil })
            ?? self.origin
        return ProviderSong(
            haoID: haoID,
            title: title.isEmpty ? other.title : title,
            artist: artist.isEmpty ? other.artist : artist,
            album: album.isEmpty ? other.album : album,
            duration: duration > 0 ? duration : other.duration,
            artworkURL: artworkURL ?? other.artworkURL,
            handles: handles,
            origin: origin
        )
    }

    /// 转播放用的 Track：source 是 origin 平台，providerItemID 是该平台的歌曲 ID；
    /// 其余平台句柄放进 altHandles（主源播不了时先换平台再解锁）。
    func toTrack() -> Track {
        var altHandles = handles
        altHandles.removeValue(forKey: origin.rawValue)
        return Track(
            id: haoID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: artworkURL,
            source: origin.rawValue,
            providerItemID: handle(for: origin),
            altHandles: altHandles
        )
    }
}

/// 歌曲指纹：标题 + 歌手 + 时长桶（2 秒一桶，容忍各平台时长差一两秒）。
enum HaoSongID {
    /// 归一化去重 key（纯函数，可单测）。大小写、首尾空格、多余空白不影响去重。
    static func key(title: String, artist: String, duration: Double) -> String {
        let bucket = duration > 0 ? Int((duration / 2).rounded()) : 0
        return "\(normalize(title))\n\(normalize(artist))\n\(bucket)"
    }

    static func normalize(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// FNV-1a 64 位指纹，16 位十六进制。确定性、跨平台一致；不是密码学哈希，只做去重 key。
    static func fingerprint(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
