import Foundation

struct RecentPlay: Codable, Identifiable, Equatable {
    let id: String
    let trackID: String
    let playedAt: Date

    init(trackID: String, playedAt: Date = Date()) {
        self.id = UUID().uuidString
        self.trackID = trackID
        self.playedAt = playedAt
    }
}

/// 本地曲库：喜欢的歌、最近播放、导入的本地音频。全部只存本机 UserDefaults。
/// 网络曲目元数据也缓存一份（只存标题/歌手/封面 URL/平台 ID，不存播放地址——
/// 地址会过期，每次播都重新解析），最近 100 首。
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var localTracks: [Track] = []
    @Published private(set) var likedTrackIDs: [String] = []
    @Published private(set) var recentPlays: [RecentPlay] = []
    /// 最近 100 首网络曲目元数据（去重：同平台同 ID 只留一条）。
    @Published private(set) var cachedNetworkTracks: [Track] = []

    private let likedKey = "haoMusic.likedTrackIDs"
    private let recentKey = "haoMusic.recentPlays"
    private let localKey = "haoMusic.localTracks"
    private let networkCacheKey = "haoMusic.cachedNetworkTracks"
    private let maxRecentCount = 50
    private let maxNetworkCacheCount = 100

    init() {
        load()
    }

    var likedTracks: [Track] {
        allKnownTracks.filter { likedTrackIDs.contains($0.id) }
    }

    var recentTracks: [Track] {
        recentPlays.compactMap { play in allKnownTracks.first { $0.id == play.trackID } }
    }

    /// 本地 + 已缓存的网络曲目（最近播放/喜欢按 ID 找歌时都从这里找）。
    private var allKnownTracks: [Track] {
        localTracks + cachedNetworkTracks
    }

    func cacheNetworkTrack(_ track: Track) {
        guard track.localFileURL == nil else { return }
        cachedNetworkTracks.removeAll {
            $0.id == track.id || ($0.source == track.source && $0.providerItemID == track.providerItemID)
        }
        cachedNetworkTracks.insert(track, at: 0)
        if cachedNetworkTracks.count > maxNetworkCacheCount {
            cachedNetworkTracks = Array(cachedNetworkTracks.prefix(maxNetworkCacheCount))
        }
        saveArray(cachedNetworkTracks, key: networkCacheKey)
    }

    func isLiked(_ track: Track) -> Bool {
        likedTrackIDs.contains(track.id)
    }

    func toggleLike(_ track: Track) {
        if likedTrackIDs.contains(track.id) {
            likedTrackIDs.removeAll { $0 == track.id }
        } else {
            likedTrackIDs.append(track.id)
        }
        saveLikes()
    }

    func recordPlayed(_ track: Track) {
        recentPlays.removeAll { $0.trackID == track.id }
        recentPlays.insert(RecentPlay(trackID: track.id), at: 0)
        if recentPlays.count > maxRecentCount {
            recentPlays = Array(recentPlays.prefix(maxRecentCount))
        }
        saveRecent()
    }

    func addLocalTrack(_ track: Track) {
        guard !localTracks.contains(where: { $0.id == track.id || $0.localFileURL == track.localFileURL }) else { return }
        localTracks.append(track)
        saveLocalTracks()
    }

    func removeLocalTrack(_ track: Track) {
        localTracks.removeAll { $0.id == track.id }
        likedTrackIDs.removeAll { $0 == track.id }
        recentPlays.removeAll { $0.trackID == track.id }
        saveLocalTracks()
        saveLikes()
        saveRecent()
    }

    // MARK: - 持久化

    private func load() {
        localTracks = loadArray(key: localKey)
        likedTrackIDs = loadArray(key: likedKey)
        recentPlays = loadArray(key: recentKey)
        cachedNetworkTracks = loadArray(key: networkCacheKey)
    }

    private func saveLikes() {
        saveArray(likedTrackIDs, key: likedKey)
    }

    private func saveRecent() {
        saveArray(recentPlays, key: recentKey)
    }

    private func saveLocalTracks() {
        saveArray(localTracks, key: localKey)
    }

    private func loadArray<T: Decodable>(key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private func saveArray<T: Encodable>(_ value: [T], key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
