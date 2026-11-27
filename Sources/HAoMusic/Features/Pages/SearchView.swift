import SwiftUI

/// Search history: the user's own submitted queries, most-recent-first,
/// kept on device (UserDefaults, cap 10). Nothing leaves the device.
@MainActor
final class SearchHistory: ObservableObject {
    static let shared = SearchHistory()
    private static let storageKey = "search.history"
    private static let limit = 10

    @Published private(set) var records: [String] = []

    private init() {
        records = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        records.removeAll { $0 == trimmed }
        records.insert(trimmed, at: 0)
        if records.count > Self.limit { records = Array(records.prefix(Self.limit)) }
        UserDefaults.standard.set(records, forKey: Self.storageKey)
    }

    func clear() {
        records = []
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case all = "综合"
        case songs = "单曲"
        case artists = "歌手"
        case albums = "专辑"
        case playlists = "歌单"

        var id: String { rawValue }
    }

    var query: String
    @Published var tab: Tab = .all
    @Published var songs: [Track] = []
    @Published var artists: [ArtistSummary] = []
    @Published var albums: [AlbumSummary] = []
    @Published var playlists: [PlaylistSummary] = []
    @Published var loadedTabs: Set<Tab> = []
    @Published private var loadingTabs: Set<Tab> = []
    /// Bumped on every query change so responses to an older query are dropped.
    private var generation = 0

    var isLoading: Bool { !loadingTabs.isEmpty }

    init(query: String) {
        self.query = query
        // A query this page was opened with (macOS toolbar submit) is a
        // submitted search too.
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SearchHistory.shared.record(query)
        }
    }

    /// A submitted search: record it, then run it like setQuery + load.
    func submit(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SearchHistory.shared.record(trimmed)
        setQuery(trimmed)
    }

    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        generation &+= 1
        loadedTabs.removeAll()
        loadingTabs.removeAll()
        songs = []
        artists = []
        albums = []
        playlists = []
    }

    /// Songs from NetEase and QQ, searched in parallel and merged: a QQ
    /// song that duplicates a NetEase result (same name + artist +
    /// duration within 2 seconds) is dropped, NetEase wins. QQ is capped
    /// at 5 seconds so a slow QQ never delays the NetEase results.
    /// Either source failing alone still shows the other's results; nil
    /// only when both fail, so the tab retries.
    private func mergedSongs(for query: String, limit: Int) async -> [Track]? {
        async let neteaseTask = try? MusicAPI.search(query, type: .songs, limit: limit)
        async let qqTask = qqSongs(for: query, limit: limit)
        let (neteaseResult, qqTracks) = await (neteaseTask, qqTask)
        let neteaseTracks = neteaseResult?.songs ?? []
        guard neteaseResult != nil || !qqTracks.isEmpty else { return nil }
        return neteaseTracks + qqTracks.filter { candidate in
            !neteaseTracks.contains { existing in
                existing.name.lowercased() == candidate.name.lowercased()
                && existing.artistNames.lowercased() == candidate.artistNames.lowercased()
                && abs(existing.durationMS - candidate.durationMS) <= 2000
            }
        }
    }

    private func qqSongs(for query: String, limit: Int) async -> [Track] {
        await withTaskGroup(of: [Track].self) { group in
            group.addTask {
                guard let songs = try? await QQMusicAPI.shared.searchSongs(keyword: query, limit: limit) else { return [] }
                return songs.compactMap { song -> Track? in
                    guard let mid = song.qqMid, !mid.isEmpty else { return nil }
                    return Track(qqSong: song)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    func load(tab: Tab) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !loadedTabs.contains(tab) else { return }
        let requestGeneration = generation
        loadedTabs.insert(tab)
        loadingTabs.insert(tab)
        defer {
            if generation == requestGeneration { loadingTabs.remove(tab) }
        }

        // A failed request leaves the tab unloaded so submitting again retries
        // instead of keeping an empty result for this query.
        switch tab {
        case .all:
            async let songsTask = mergedSongs(for: trimmed, limit: 12)
            async let artistsTask = try? MusicAPI.search(trimmed, type: .artists, limit: 10)
            async let albumsTask = try? MusicAPI.search(trimmed, type: .albums, limit: 10)
            async let playlistsTask = try? MusicAPI.search(trimmed, type: .playlists, limit: 10)
            let (songResult, artistResult, albumResult, playlistResult) =
                await (songsTask, artistsTask, albumsTask, playlistsTask)
            guard generation == requestGeneration else { return }
            songs = songResult ?? []
            artists = artistResult?.artists ?? []
            albums = albumResult?.albums ?? []
            playlists = playlistResult?.playlists ?? []
            if songResult == nil || artistResult == nil || albumResult == nil || playlistResult == nil {
                loadedTabs.remove(tab)
            }
        case .songs:
            let merged = await mergedSongs(for: trimmed, limit: 100)
            guard generation == requestGeneration else { return }
            if let merged { songs = merged } else { loadedTabs.remove(tab) }
        case .artists:
            let result = try? await MusicAPI.search(trimmed, type: .artists, limit: 50)
            guard generation == requestGeneration else { return }
            if let result { artists = result.artists ?? artists } else { loadedTabs.remove(tab) }
        case .albums:
            let result = try? await MusicAPI.search(trimmed, type: .albums, limit: 50)
            guard generation == requestGeneration else { return }
            if let result { albums = result.albums ?? albums } else { loadedTabs.remove(tab) }
        case .playlists:
            let result = try? await MusicAPI.search(trimmed, type: .playlists, limit: 50)
            guard generation == requestGeneration else { return }
            if let result { playlists = result.playlists ?? playlists } else { loadedTabs.remove(tab) }
        }
    }
}

struct SearchView: View {
    @StateObject private var model: SearchViewModel
    @StateObject private var history = SearchHistory.shared
    @State private var searchText: String = ""

    init(query: String) {
        _model = StateObject(wrappedValue: SearchViewModel(query: query))
        _searchText = State(initialValue: query)
    }

    /// Run a search from a chip (history or hot word): show it in the field,
    /// record it, and load.
    private func runSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchText = trimmed
        model.submit(trimmed)
        Task { await model.load(tab: model.tab) }
    }

    var body: some View {
        searchContent
        #if os(iOS)
        // iPad enters SearchView from the sidebar, where the desktop window
        // toolbar search field is unavailable. On macOS, MainWindow owns the
        // only search field and navigates here with its submitted query.
        // Keep the field pinned under the title. The default drawer collapses
        // until the page scrolls, and the empty search page has nothing to
        // scroll, so the field stayed hidden on the iPhone Search tab.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索歌曲、歌手、专辑、歌单"
        )
        .onSubmit(of: .search) {
            model.submit(searchText)
            Task { await model.load(tab: model.tab) }
        }
        .onChange(of: searchText) { newValue in
            model.setQuery(newValue)
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if searchText == newValue {
                    await model.load(tab: model.tab)
                }
            }
        }
        #endif
        .navigationTitle(searchText.isEmpty ? "搜索" : String(localized: "搜索：\(searchText)"))
        .task(id: model.tab) {
            await model.load(tab: model.tab)
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        #if os(macOS)
        if model.tab == .songs, !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            TrackListScrollView(trackIDs: model.songs.map(\.id)) {
                VStack(spacing: 20) {
                    tabPicker
                    if model.isLoading && currentEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
            } rows: { layout in
                TrackListView(tracks: model.songs, layout: layout)
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
            } footer: {
                PlayerClearanceSpacer()
            }
        } else {
            mixedResults.clipped()
        }
        #else
        mixedResults
        #endif
    }

    private var mixedResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    tabPicker

                    if model.isLoading && currentEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        tabContent
                    }
                } else {
                    emptySearchPrompt
                }
                PlayerClearanceSpacer()
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $model.tab) {
            ForEach(SearchViewModel.Tab.allCases) { tab in
                Text(LocalizedStringKey(tab.rawValue)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 12)
    }

    private var emptySearchPrompt: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !history.records.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("搜索记录")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Button("清除") { history.clear() }
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Spacer().frame(width: Theme.Layout.contentInset - 8)
                            ForEach(history.records, id: \.self) { record in
                                Button { runSearch(record) } label: { Text(record) }
                                    .buttonStyle(.chip(isSelected: false))
                            }
                            Spacer().frame(width: Theme.Layout.contentInset - 8)
                        }
                        .padding(.vertical, 2)
                    }
                    .shelfEdgeClip()
                }
            }

            if history.records.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 60)
                    Text("探索海量华语流行与经典音乐")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("输入歌曲名称、歌手名或歌单关键字开始搜索")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
            }
        }
        .padding(.top, 12)
    }

    private var currentEmpty: Bool {
        switch model.tab {
        case .all: return model.songs.isEmpty && model.artists.isEmpty
        case .songs: return model.songs.isEmpty
        case .artists: return model.artists.isEmpty
        case .albums: return model.albums.isEmpty
        case .playlists: return model.playlists.isEmpty
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .all:
            if !model.songs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "单曲") {
                        model.tab = .songs
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: Array(model.songs.prefix(6)))
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            if !model.artists.isEmpty {
                Shelf(title: "歌手", seeAll: { model.tab = .artists }) {
                    artistCards(model.artists.prefix(8))
                }
            }
            if !model.albums.isEmpty {
                Shelf(title: "专辑", seeAll: { model.tab = .albums }) {
                    albumCards(model.albums.prefix(8))
                }
            }
            if !model.playlists.isEmpty {
                Shelf(title: "歌单", seeAll: { model.tab = .playlists }) {
                    playlistCards(model.playlists.prefix(8))
                }
            }
            if currentEmpty, !model.isLoading {
                EmptyStateView(icon: "magnifyingglass", title: "没有找到相关结果")
                    .frame(minHeight: 300)
            }
        case .songs:
            TrackListView(tracks: model.songs)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        case .artists:
            CardGrid(minWidth: 140) {
                artistCards(model.artists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .albums:
            CardGrid {
                albumCards(model.albums)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .playlists:
            CardGrid {
                playlistCards(model.playlists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func artistCards(_ items: some Collection<ArtistSummary>) -> some View {
        ForEach(Array(items)) { artist in
            // Value-based link on the shared route (Coda): pushed pages get
            // the back row and navigation-path lifecycle handling.
            NavigationLink(value: Destination.artist(artist.id)) {
                VStack(spacing: 10) {
                    CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(width: 140)
            }
            .buttonStyle(.plain)
        }
    }

    private func albumCards(_ items: some Collection<AlbumSummary>) -> some View {
        ForEach(Array(items)) { album in
            NavigationLink(value: Destination.album(album.id)) {
                CoverCardBody(
                    coverURL: album.picUrl?.resizedImageURL(384),
                    title: album.name,
                    subtitle: album.artistName
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistCards(_ items: some Collection<PlaylistSummary>) -> some View {
        ForEach(Array(items)) { playlist in
            NavigationLink(value: Destination.playlist(playlist.id)) {
                CoverCardBody(
                    coverURL: playlist.coverURL?.resizedImageURL(384),
                    title: playlist.name,
                    playCount: playlist.playCount
                )
            }
            .buttonStyle(.plain)
        }
    }
}
