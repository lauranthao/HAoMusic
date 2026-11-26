import SwiftUI

@MainActor
final class ExploreViewModel: ObservableObject {
    /// Shared so category selection and loaded pages survive sidebar switches.
    static let shared = ExploreViewModel()

    static let categories: [String] = [
        "全部", "推荐歌单", "精品歌单", "排行榜", "官方",
        "华语", "流行", "摇滚", "民谣", "电子", "轻音乐", "说唱", "爵士", "古典",
        "影视原声", "ACG", "古风", "怀旧", "治愈", "放松", "伤感", "快乐",
        "学习", "工作", "运动", "驾车", "夜晚",
    ]

    @Published var selectedCategory = "全部"
    @Published var playlists: [PlaylistSummary] = []
    @Published var toplists: [ToplistItem] = []
    @Published var isLoading = false
    @Published var hasMore = true
    private var offset = 0
    private var highQualityBefore = 0
    private var loadTask: Task<Void, Never>?

    func select(_ category: String) {
        guard category != selectedCategory || playlists.isEmpty else { return }
        selectedCategory = category
        playlists = []
        offset = 0
        highQualityBefore = 0
        hasMore = true
        loadTask?.cancel()
        loadTask = Task { await loadMore() }
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        switch selectedCategory {
        case "排行榜":
            if let lists = try? await MusicAPI.toplists() {
                toplists = lists
            }
            hasMore = false
        case "推荐歌单":
            if let result = try? await MusicAPI.personalizedPlaylists(limit: 100) {
                playlists = result
            }
            hasMore = false
        case "精品歌单":
            if let result = try? await MusicAPI.highQualityPlaylists(before: highQualityBefore) {
                let existing = Set(playlists.map(\.id))
                playlists += result.playlists.filter { !existing.contains($0.id) }
                highQualityBefore = result.lasttime ?? 0
                hasMore = result.more ?? false
            } else {
                hasMore = false
            }
        default:
            let cat = selectedCategory == "官方" ? "官方" : selectedCategory
            if let result = try? await MusicAPI.topPlaylists(
                category: cat == "全部" ? "全部" : cat, offset: offset
            ) {
                let existing = Set(playlists.map(\.id))
                playlists += result.playlists.filter { !existing.contains($0.id) }
                offset += 50
                hasMore = (result.more ?? false) && offset < 500
            } else {
                hasMore = false
            }
        }
    }

    /// The 发现 home view shows a 排行榜 entry row, so toplists are needed
    /// even before the 排行榜 category is selected.
    func loadToplistsIfNeeded() async {
        guard toplists.isEmpty else { return }
        if let lists = try? await MusicAPI.toplists() {
            toplists = lists
        }
    }
}

struct ExploreView: View {
    @StateObject private var model = ExploreViewModel.shared
    @EnvironmentObject private var player: PlayerService

    /// Quick-entry categories for the 发现 palace (the full 27 stay
    /// reachable from the chip row in the category view).
    private static let hotCategories: [(name: String, icon: String, gradient: [Color])] = [
        ("华语", "mic.fill", [Color(red: 0.93, green: 0.29, blue: 0.29), Color(red: 1.0, green: 0.48, blue: 0.27)]),
        ("流行", "music.note", [Color(red: 0.15, green: 0.39, blue: 0.92), Color(red: 0.22, green: 0.74, blue: 0.97)]),
        ("摇滚", "guitars.fill", [Color(red: 0.06, green: 0.65, blue: 0.65), Color(red: 0.13, green: 0.77, blue: 0.37)]),
        ("民谣", "leaf.fill", [Color(red: 0.71, green: 0.33, blue: 0.04), Color(red: 0.96, green: 0.62, blue: 0.04)]),
        ("电子", "waveform", [Color(red: 0.06, green: 0.46, blue: 0.44), Color(red: 0.18, green: 0.83, blue: 0.75)]),
        ("说唱", "text.bubble.fill", [Color(red: 0.12, green: 0.16, blue: 0.29), Color(red: 0.28, green: 0.33, blue: 0.42)]),
        ("爵士", "music.quarternote.3", [Color(red: 0.49, green: 0.18, blue: 0.07), Color(red: 0.92, green: 0.35, blue: 0.05)]),
        ("古典", "music.note.list", [Color(red: 0.07, green: 0.31, blue: 0.29), Color(red: 0.08, green: 0.72, blue: 0.65)]),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.selectedCategory == "全部" {
                    discoverHome
                } else {
                    categoryView
                }

                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("发现")
        .task {
            if model.playlists.isEmpty, model.toplists.isEmpty {
                await model.loadMore()
            }
            await model.loadToplistsIfNeeded()
        }
    }

    // MARK: - 发现 home (全部)

    private var discoverHome: some View {
        Group {
            if let hero = model.playlists.first {
                heroBanner(hero)
                    .padding(.top, 8)
                    .padding(.horizontal, Theme.Layout.contentInset)
            }

            VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
                SectionHeader(title: "热门分类")
                    .padding(.horizontal, Theme.Layout.contentInset)
                categoryPalace
                    .padding(.horizontal, Theme.Layout.contentInset)
            }

            if !model.toplists.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
                    SectionHeader(title: "排行榜")
                        .padding(.horizontal, Theme.Layout.contentInset)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(model.toplists) { toplist in
                                toplistEntryCard(toplist)
                            }
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                    }
                    .shelfEdgeClip()
                }
            }

            VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
                SectionHeader(title: "热门歌单")
                    .padding(.horizontal, Theme.Layout.contentInset)
                // The hero already shows the first playlist; skip it here
                // so it is not duplicated one row below.
                playlistGridView(Array(model.playlists.dropFirst()))
            }
        }
    }

    // MARK: - Category view

    private var categoryView: some View {
        Group {
            Button {
                model.select("全部")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("发现")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.horizontal, Theme.Layout.contentInset)

            categoryChips

            if model.selectedCategory == "排行榜" {
                ToplistGrid(toplists: model.toplists)
                    .padding(.horizontal, Theme.Layout.contentInset)
            } else {
                playlistGridView(model.playlists)
            }
        }
    }

    // MARK: - Hero banner

    private func heroBanner(_ playlist: PlaylistSummary) -> some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationLink(value: Destination.playlist(playlist.id)) {
                ZStack(alignment: .bottomLeading) {
                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(1024))
                        .aspectRatio(16 / 10, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                    LinearGradient(
                        colors: [.black.opacity(0.72), .black.opacity(0.25), .clear],
                        startPoint: .bottom, endPoint: .top
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今日主推")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(playlist.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(Formatters.playCount(playlist.playCount))
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(16)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            // Sibling of the link, not nested inside it, so the tap
            // reliably reaches the play action instead of navigating.
            Button {
                playPlaylist(playlist.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("播放")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }

    // MARK: - Category palace

    private var categoryPalace: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                      GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 14
        ) {
            ForEach(Self.hotCategories, id: \.name) { category in
                Button {
                    model.select(category.name)
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            LinearGradient(colors: category.gradient,
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: category.icon)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text(category.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 排行榜 entry row

    private func toplistEntryCard(_ toplist: ToplistItem) -> some View {
        NavigationLink(value: Destination.playlist(toplist.id)) {
            HStack(spacing: 10) {
                CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(toplist.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let top = toplist.tracks.first {
                        Text("1 \(top.first) - \(top.second)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let frequency = toplist.updateFrequency, !frequency.isEmpty {
                        Text(frequency)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(width: 220, alignment: .leading)
            .background(.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Playlist grid

    private func playlistGridView(_ playlists: [PlaylistSummary]) -> some View {
        Group {
            CardGrid {
                ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                    NavigationLink(value: Destination.playlist(playlist.id)) {
                        CoverCardBody(
                            coverURL: playlist.coverURL?.resizedImageURL(384),
                            title: playlist.name,
                            playCount: playlist.playCount
                        ) {
                            playPlaylist(playlist.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .staggeredAppearance(index: index % 10, id: "explore-\(playlist.id)")
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)

            if model.isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if model.hasMore {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        Task { await model.loadMore() }
                    }
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Spacer().frame(width: Theme.Layout.contentInset - 8)
                ForEach(ExploreViewModel.categories, id: \.self) { category in
                    Button {
                        model.select(category)
                    } label: {
                        Text(LocalizedStringKey(category))
                    }
                    .buttonStyle(.chip(isSelected: model.selectedCategory == category))
                }
                Spacer().frame(width: Theme.Layout.contentInset - 8)
            }
            .padding(.vertical, 2)
        }
        .shelfEdgeClip()
    }

    private func playPlaylist(_ id: Int) {
        Task {
            guard let detail = try? await MusicAPI.playlistDetail(id: id) else { return }
            var tracks = detail.playlist.tracks
            if tracks.isEmpty {
                let ids = detail.playlist.trackIds.map(\.id)
                tracks = (try? await MusicAPI.songDetails(ids: Array(ids.prefix(500))))?.songs ?? []
            }
            player.play(tracks: tracks, source: .playlist(id),
                        context: .playlist(id: id, name: detail.playlist.name))
        }
    }
}

// MARK: - Toplist grid

struct ToplistGrid: View {
    let toplists: [ToplistItem]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)],
            alignment: .leading, spacing: 20
        ) {
            ForEach(toplists) { toplist in
                NavigationLink(value: Destination.playlist(toplist.id)) {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(toplist.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(toplist.updateFrequency ?? "")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(toplist.tracks.prefix(3).enumerated()), id: \.offset) { i, preview in
                                    Text("\(i + 1). \(preview.first) - \(preview.second)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ToplistsView: View {
    @State private var toplists: [ToplistItem] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ToplistGrid(toplists: toplists)
                    .padding(Theme.Layout.contentInset)
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("排行榜")
        .task {
            if toplists.isEmpty {
                toplists = (try? await MusicAPI.toplists()) ?? []
            }
        }
    }
}
