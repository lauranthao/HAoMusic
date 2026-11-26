import Foundation

/// 解锁候选打分（纯函数，可单测）：标题 + 歌手 + 时长三项打分。
/// 标题完全一致 0.5、包含 0.3；歌手完全一致 0.3、包含 0.15；
/// 时长差 2 秒内 0.2、5 秒内 0.1。0.6 分以上才认是同一首歌。
struct UnlockCandidate: Sendable {
    let title: String
    let artist: String
    let duration: Double
    /// 平台内的取流凭证（酷狗 hash / 酷我 MUSICRID）。
    let credential: String
}

enum HaoSongMatcher {
    static func score(candidate: UnlockCandidate, song: ProviderSong) -> Double {
        let title = HaoSongID.normalize(candidate.title)
        let wantTitle = HaoSongID.normalize(song.title)
        var score = 0.0
        if !title.isEmpty && title == wantTitle {
            score += 0.5
        } else if !title.isEmpty && (title.contains(wantTitle) || wantTitle.contains(title)) {
            score += 0.3
        }
        let artist = HaoSongID.normalize(candidate.artist)
        let wantArtist = HaoSongID.normalize(song.artist)
        if !artist.isEmpty && artist == wantArtist {
            score += 0.3
        } else if !artist.isEmpty && (artist.contains(wantArtist) || wantArtist.contains(artist)) {
            score += 0.15
        }
        if song.duration > 0 && candidate.duration > 0 {
            let diff = abs(candidate.duration - song.duration)
            if diff <= 2 {
                score += 0.2
            } else if diff <= 5 {
                score += 0.1
            }
        }
        return score
    }

    /// 最高分候选；低于 0.6 分不认。
    static func bestMatch(candidates: [UnlockCandidate], song: ProviderSong) -> UnlockCandidate? {
        candidates
            .map { ($0, score(candidate: $0, song: song)) }
            .filter { $0.1 >= 0.6 }
            .max(by: { $0.1 < $1.1 })?
            .0
    }
}
