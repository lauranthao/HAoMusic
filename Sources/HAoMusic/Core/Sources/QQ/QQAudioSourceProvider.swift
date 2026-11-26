import Foundation

// MARK: - Coda helpers carried over with the QQ platform

/// From Coda (Wow-CaiCai/Coda, AGPL-3.0), Core/Storage/MusicProvider.swift.
func providerLocalized(_ chinese: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

/// From Coda (Wow-CaiCai/Coda, AGPL-3.0), Core/API/QishuiMusicAPI.swift.
/// Only the reference structs are needed here — ProviderPlaylist carries an
/// optional Qishui playlist reference; the Qishui platform itself is NOT copied.
struct QishuiTrackReference: Codable, Hashable, Sendable {
    let trackID: String
    var albumID: String? = nil
    var artists: [ProviderArtist]? = nil
}

struct QishuiPlaylistReference: Codable, Hashable, Sendable {
    let playlistID: String
    let type: Int
    var radio: QishuiRadioReference? = nil
}

struct QishuiRadioReference: Codable, Hashable, Sendable {
    let flowType: Int
    let triggerInfo: String
}

/// Minimal stand-in for Coda's AudioQualityOption: QQMusicAPI only uses
/// `estimatedBitrate` to estimate a probed stream's bitrate.
struct AudioQualityOption {
    static func estimatedBitrate(byteCount: Double?, durationSeconds: Double?) -> Double? {
        guard let byteCount, let durationSeconds, byteCount.isFinite, durationSeconds.isFinite,
              byteCount > 0, durationSeconds > 0 else { return nil }
        let bitrate = byteCount * 8 / durationSeconds
        return bitrate.isFinite && bitrate > 0 ? bitrate : nil
    }
}

/// Catalog search kind for QQMusicAPI.catalogSearch (Coda used
/// NeteaseAPI.SearchType here; HAo Music defines its own so the QQ code
/// does not depend on Coda's NetEase client).
enum QQCatalogSearchType {
    case songs
    case artists
    case albums
    case playlists
}

// MARK: - QQ unlock provider (Kumone AudioSourceProvider surface)

/// QQ 音乐作为灰歌解锁源：按歌名+歌手在 QQ 搜歌，标题/歌手/时长匹配后
/// 用 vkey 流程取播放地址（自带高→低档位降级 + 多 CDN 探测）。
/// 登录不是必需的；登录后（QQMusicAuth）播放成功率更高。
struct QQAudioSourceProvider: AudioSourceProvider {
    var id: AudioSourceID { .qq }
    var displayName: String { String(localized: "QQ 音乐") }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        let keyword = AudioSourceTrackMatcher.keyword(for: track)
        let results = try await QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 10)
        for candidate in results {
            guard let mid = candidate.qqMid, !mid.isEmpty else { continue }
            let durationMS = Int(candidate.duration * 1000)
            guard AudioSourceTrackMatcher.matches(
                track: track, title: candidate.name, artist: candidate.artists, durationMS: durationMS
            ) else { continue }
            // Remember the first match for 10 minutes so a repeat tap skips
            // the search; the vkey result itself is already cached 10 minutes
            // inside QQMusicAPI.
            await UnblockMatchCache.shared.store(
                .qq(mid: mid, mediaMid: candidate.qqMediaMid), for: .qq, trackID: track.id)
            guard let urlString = try await QQMusicAPI.shared.songURL(
                songmid: mid, mediaMid: candidate.qqMediaMid
            ), let url = URL(string: urlString) else { continue }
            return ResolvedAudioSource(id: .qq, displayName: displayName, url: url)
        }
        return nil
    }

    /// The cached match path: no search, straight to the vkey flow.
    /// A stale match falls back to a full search in the caller.
    func resolve(match: UnblockMatch, track: Track) async throws -> ResolvedAudioSource? {
        guard case .qq(let mid, let mediaMid) = match else { return nil }
        guard let urlString = try await QQMusicAPI.shared.songURL(
            songmid: mid, mediaMid: mediaMid
        ), let url = URL(string: urlString) else { return nil }
        return ResolvedAudioSource(id: .qq, displayName: displayName, url: url)
    }
}
