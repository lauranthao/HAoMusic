import SwiftUI

/// 搜索页（HAo 自己的做法：两家参照都没有合并搜索）：
/// - “网络”在上：网易 + QQ 并行搜、去重合并，一行一首歌，行尾带平台小徽标；
///   先回来的平台先出第一批（约 1 秒内见结果），完整结果随后补齐；
/// - “本地曲库”在下：搜本机导入的音频；
/// - 点一行播整张合并列表（当队列），记 PlaySource.search；播过的歌进缓存 + 最近播放。
struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var musicService: HaoMusicService
    @State private var query = ""
    @State private var networkResults: [ProviderSong] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private var localResults: [Track] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return library.localTracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("搜歌名、歌手", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _ in scheduleSearch() }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("网络搜索：网易云 + QQ 音乐并行搜，同一首歌只显示一行。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            networkSection
                            localSection
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, HaoMusicDesign.horizontalPadding)
            .padding(.top, 8)
            .navigationTitle("搜索")
        }
    }

    // MARK: - 网络

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("网络", trailing: isSearching ? "搜索中…" : nil)
            if !isSearching && networkResults.isEmpty {
                Text("没有找到“\(query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(networkResults) { song in
                    MergedSongRow(song: song, onPlay: { play(song) })
                }
            }
        }
    }

    // MARK: - 本地

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("本地曲库", trailing: nil)
            if localResults.isEmpty {
                Text("本地没有匹配的歌曲")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(localResults) { track in
                    TrackRow(track: track, onPlay: {
                        if let index = library.localTracks.firstIndex(of: track) {
                            player.play(tracks: library.localTracks, startAt: index, source: .search)
                        }
                        library.recordPlayed(track)
                    })
                }
            }
        }
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 搜索与播放

    /// 300ms 防抖：打字不停不发请求；每次新查询取消上一次。
    private func scheduleSearch() {
        searchTask?.cancel()
        networkResults = []
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            for await update in musicService.searchMerged(query: q) {
                guard !Task.isCancelled else { return }
                switch update {
                case let .partial(songs):
                    networkResults = songs
                case let .final(songs):
                    networkResults = songs
                    isSearching = false
                }
            }
        }
    }

    private func play(_ song: ProviderSong) {
        let tracks = networkResults.map { $0.toTrack() }
        guard let index = networkResults.firstIndex(of: song) else { return }
        let track = tracks[index]
        player.play(tracks: tracks, startAt: index, source: .search)
        library.cacheNetworkTrack(track)
        library.recordPlayed(track)
    }
}

/// 合并搜索行：封面 + 标题/歌手 + 平台小徽标（这首歌在哪些平台有）。
/// 整行点按播放，♥ 只管收藏。
struct MergedSongRow: View {
    let song: ProviderSong
    var onPlay: () -> Void
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let track = song.toTrack()
        HStack(spacing: 12) {
            TrackCoverView(track: track, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(song.providers, id: \.self) { provider in
                    Text(provider.badge)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: { library.toggleLike(track) }) {
                Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                    .foregroundStyle(library.isLiked(track) ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }
}
