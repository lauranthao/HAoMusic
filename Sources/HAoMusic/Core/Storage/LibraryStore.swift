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
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var localTracks: [Track] = []
    @Published private(set) var likedTrackIDs: [String] = []
    @Published private(set) var recentPlays: [RecentPlay] = []

    private let likedKey = "haoMusic.likedTrackIDs"
    private let recentKey = "haoMusic.recentPlays"
    private let localKey = "haoMusic.localTracks"
    private let maxRecentCount = 50

    init() {
        load()
    }

    var likedTracks: [Track] {
        localTracks.filter { likedTrackIDs.contains($0.id) }
    }

    var recentTracks: [Track] {
        recentPlays.compactMap { play in localTracks.first { $0.id == play.trackID } }
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
