import SwiftUI

/// Measured width of the 新碟上架 shelf, reported by its background
/// GeometryReader so the two-row height can be sized from the fitted card
/// size (see HomeView.loadedBody).
private struct NewAlbumsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Measured width of a song-pair shelf （地区热门 / 喜欢的歌手推荐）,
/// reported the same way so each two-song column can size itself.
private struct SongShelfWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor
final class HomeViewModel: ObservableObject {
    /// Shared so the loaded page survives sidebar switches (no skeleton flash).
    static let shared = HomeViewModel()

    enum State {
        case idle, loading, loaded
        case error(String)
    }

    /// The personalized radar family — global playlist IDs whose content is
    /// generated per logged-in account (same list YesPlayMusic special-cases).
    static let radarPlaylistIDs = [
        3_136_952_023, // 私人雷达
        2_829_883_282, // 华语私人雷达
        2_829_816_518, // 欧美私人雷达
        2_829_896_389, // 日系私人雷达
    ]

    struct RadarPlaylist: Identifiable, Hashable {
        let id: Int
        let title: String
        let subtitle: String?
        let coverURL: String?
    }

    @Published var state: State = .idle
    @Published var recommendPlaylists: [PlaylistSummary] = []
    @Published var radarPlaylists: [RadarPlaylist] = []
    @Published var toplists: [ToplistItem] = []
    @Published var newAlbums: [AlbumSummary] = []
    @Published var topArtists: [ArtistSummary] = []
    @Published var dailyFirstCover: String?

    /// 地区热门: 全部 / 华语 / 欧美 / 日韩. 日韩 merges the Japanese (8) and
    /// Korean (16) lists, since the endpoint has no combined area.
    enum RegionalArea: Int, CaseIterable, Identifiable {
        case all = 0
        case chinese = 7
        case western = 96
        case japanKorea = -1

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .all: return String(localized: "全部")
            case .chinese: return String(localized: "华语")
            case .western: return String(localized: "欧美")
            case .japanKorea: return String(localized: "日韩")
            }
        }
    }

    @Published var regionalArea: RegionalArea = .all
    @Published var regionalSongs: [Track] = []
    @Published var regionalLoading = false
    private var regionalCache: [RegionalArea: [Track]] = [:]

    /// 喜欢的歌手推荐: songs similar to the top songs of the user's liked
    /// artists. Cached per liked-artist set; a refresh re-seeds it.
    @Published var likedArtistSongs: [Track] = []
    @Published var likedArtistLoading = false
    @Published var refreshNonce = 0
    private var likedArtistKey: String?
    private var previousArtistSeeds: Set<Int> = []

    /// Round-robin merge of per-source song lists, deduped, capped: every
    /// source stays represented instead of the fastest one filling the list.
    static func interleaveSongs(_ groups: [[Track]], excluding excluded: Set<Int> = [], limit: Int = 100) -> [Track] {
        var seen = excluded
        var result: [Track] = []
        let maxCount = groups.map(\.count).max() ?? 0
        for index in 0..<maxCount {
            for group in groups where group.indices.contains(index) {
                let track = group[index]
                if seen.insert(track.id).inserted { result.append(track) }
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// Up to `limit` seeds, preferring ones the previous batch did not use.
    static func pickSeeds(from candidates: [Int], avoiding previous: Set<Int>, limit: Int = 3) -> [Int] {
        var seen = Set<Int>()
        let unique = candidates.filter { seen.insert($0).inserted }
        return Array((unique.filter { !previous.contains($0) } + unique.filter { previous.contains($0) }).prefix(limit))
    }

    func loadRegional(area: RegionalArea) async {
        if let cached = regionalCache[area] {
            regionalSongs = cached
            return
        }
        regionalLoading = true
        defer { regionalLoading = false }
        let songs: [Track]
        do {
            switch area {
            case .japanKorea:
                async let japanese = try? MusicAPI.homeTopSongs(areaID: 8)
                async let korean = try? MusicAPI.homeTopSongs(areaID: 16)
                let (jp, kr) = await (japanese, korean)
                songs = Self.interleaveSongs([jp ?? [], kr ?? []], limit: 100)
            default:
                songs = try await MusicAPI.homeTopSongs(areaID: area.rawValue)
            }
        } catch {
            return
        }
        guard !songs.isEmpty else { return }
        regionalCache[area] = songs
        if regionalArea == area { regionalSongs = songs }
    }

    func loadLikedArtistSongs(artists: [ArtistSummary], excluding likedIDs: Set<Int>) async {
        let ids = artists.map(\.id).sorted()
        guard !ids.isEmpty else {
            likedArtistSongs = []
            likedArtistKey = nil
            return
        }
        let key = ids.map(String.init).joined(separator: ",")
        guard likedArtistKey != key else { return }
        likedArtistLoading = true
        defer { likedArtistLoading = false }
        let seeds = Self.pickSeeds(from: ids.shuffled(), avoiding: previousArtistSeeds)
        let groups = await withTaskGroup(of: [Track]?.self) { group in
            for id in seeds {
                group.addTask {
                    guard let top = try? await MusicAPI.artist(id: id).hotSongs.first else { return nil }
                    return try? await MusicAPI.similarSongs(id: top.id, limit: 12)
                }
            }
            var collected: [[Track]] = []
            for await songs in group { if let songs { collected.append(songs) } }
            return collected
        }
        guard !groups.isEmpty else { return }
        previousArtistSeeds = Set(seeds)
        likedArtistKey = key
        likedArtistSongs = Self.interleaveSongs(groups, excluding: likedIDs, limit: 36)
    }

    func load(loggedIn: Bool) async {
        if case .loaded = state { return }
        state = .loading

        async let playlistsTask = fetchRecommendPlaylists(loggedIn: loggedIn)
        async let toplistsTask = try? MusicAPI.toplists()
        async let albumsTask = try? MusicAPI.newAlbums(limit: 20)
        async let artistsTask = try? MusicAPI.topArtists()

        let playlists = await playlistsTask
        recommendPlaylists = playlists
        toplists = (await toplistsTask ?? []).filter {
            [19_723_756, 3_779_629, 2_884_035, 3_778_678, 60198].contains($0.id)
        }
        newAlbums = await albumsTask ?? []
        let artists = await artistsTask ?? []
        topArtists = Array(artists.shuffled().prefix(6))

        if loggedIn {
            if let daily = try? await MusicAPI.dailyRecommendSongs() {
                dailyFirstCover = daily.first?.album.picUrl
            }
            await loadRadarPlaylists()
        }

        state = playlists.isEmpty && newAlbums.isEmpty ? .error(String(localized: "网络连接失败")) : .loaded
    }

    func reload(loggedIn: Bool) async {
        state = .idle
        regionalCache = [:]
        regionalSongs = []
        regionalArea = .all
        likedArtistKey = nil
        likedArtistSongs = []
        refreshNonce &+= 1
        await load(loggedIn: loggedIn)
    }

    private func loadRadarPlaylists() async {
        let briefs = await withTaskGroup(of: (Int, MusicAPI.PlaylistBrief.Body?).self) { group in
            for id in Self.radarPlaylistIDs {
                group.addTask {
                    (id, try? await MusicAPI.playlistBrief(id: id))
                }
            }
            var byID: [Int: MusicAPI.PlaylistBrief.Body] = [:]
            for await (id, brief) in group {
                if let brief { byID[id] = brief }
            }
            return byID
        }
        radarPlaylists = Self.radarPlaylistIDs.compactMap { id in
            guard let brief = briefs[id] else { return nil }
            // Names arrive as "今天从《…》听起|私人雷达" — split into title/subtitle.
            let parts = (brief.name ?? "").components(separatedBy: "|")
            let title = parts.count > 1 ? parts.last! : (brief.name ?? String(localized: "雷达歌单"))
            let subtitle = parts.count > 1 ? parts.dropLast().joined(separator: "|") : nil
            return RadarPlaylist(id: id, title: title, subtitle: subtitle, coverURL: brief.coverImgUrl)
        }
    }

    private func fetchRecommendPlaylists(loggedIn: Bool) async -> [PlaylistSummary] {
        if loggedIn {
            async let recommend = try? MusicAPI.recommendResource()
            async let personalized = try? MusicAPI.personalizedPlaylists(limit: 30)
            let head = await recommend ?? []
            let tail = await personalized ?? []
            var seen = Set<Int>()
            return (head + tail).filter { seen.insert($0.id).inserted }
        }
        return (try? await MusicAPI.personalizedPlaylists(limit: 30)) ?? []
    }
}

struct HomeView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerService
    @StateObject private var model = HomeViewModel.shared
    /// Measured width of the 新碟上架 shelf, for sizing its two rows from
    /// the fitted card size (see loadedBody). Falls back to the screen
    /// width until the first measurement lands.
    @State private var newAlbumsWidth: CGFloat = 0
    /// Measured width of the song-pair shelves, for sizing each two-song
    /// column (see songPairShelf). Same fallback.
    @State private var songShelfWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            switch model.state {
            case .idle, .loading:
                loadingBody
            case .error(let message):
                ErrorStateView(message: message) {
                    Task { await model.reload(loggedIn: account.isLoggedIn) }
                }
                .frame(minHeight: 400)
            case .loaded:
                loadedBody
            }
        }
        .navigationTitle("推荐")
        .task(id: account.isLoggedIn) {
            await model.load(loggedIn: account.isLoggedIn)
        }
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonView(cornerRadius: Theme.Radius.large)
                            .frame(width: 230, height: 132)
                    }
                }
            }
            SkeletonShelf()
            SkeletonShelf()
        }
        .padding(Theme.Layout.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadedBody: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
            // Anonymous users go straight to recommended playlists;
            // the login entry lives in the sidebar / 我的 tab only.
            if account.isLoggedIn {
                featureCards
                    .padding(.top, 8)
            }

            if !model.recommendPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(Array(model.recommendPlaylists.prefix(12).enumerated()), id: \.element.id) { index, playlist in
                        playlistCard(playlist)
                            .staggeredAppearance(index: index, id: "home-rec-\(playlist.id)")
                    }
                }
            }

            if !model.radarPlaylists.isEmpty {
                Shelf(title: "雷达歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.radarPlaylists) { radar in
                        NavigationLink(value: Destination.radarPlaylist(radar.id)) {
                            CoverCardBody(
                                coverURL: radar.coverURL?.resizedImageURL(384),
                                title: radar.title,
                                subtitle: radar.subtitle,
                                titleLineLimit: Theme.Layout.shelfTitleLineLimit
                            ) {
                                playPlaylist(radar.id)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.toplists.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
                    SectionHeader(title: "排行榜")
                        .padding(.horizontal, Theme.Layout.contentInset)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.toplists) { toplist in
                            NavigationLink(value: Destination.playlist(toplist.id)) {
                                toplistRow(toplist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
            }

            regionalSection

            if !account.likedArtists.isEmpty {
                likedArtistSection
            }

            if !model.newAlbums.isEmpty {
                // Two rows like Coda's new-albums shelf: each column stacks
                // two album cards, and the columns scroll horizontally. Same
                // cards, same data, same tap. The rows are sized from the
                // fitted card size, not from coverShelfHeight (which assumes
                // 160pt cards): on a phone the cards are ~106pt, so the old
                // height left ~110pt of blank space under the shelf
                // (chen 2026-11-27). The width is measured in the
                // background so the section sizes itself — no GeometryReader
                // child to pin a height for.
                let width = newAlbumsWidth > 0 ? newAlbumsWidth : UIScreen.main.bounds.width
                let size = Theme.Layout.fittedShelfCardSize(availableWidth: width, leadingInset: Theme.Layout.contentInset)
                let twoRowHeight = (size + Theme.Layout.coverCardTextHeight) * 2 + 16
                VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
                    SectionHeader(title: "新碟上架")
                        .padding(.horizontal, Theme.Layout.contentInset)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(0..<(model.newAlbums.count + 1) / 2, id: \.self) { column in
                                VStack(alignment: .leading, spacing: 16) {
                                    albumCard(model.newAlbums[column * 2], size: size)
                                    if column * 2 + 1 < model.newAlbums.count {
                                        albumCard(model.newAlbums[column * 2 + 1], size: size)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .frame(height: twoRowHeight)
                    }
                    .shelfEdgeClip()
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: NewAlbumsWidthKey.self, value: proxy.size.width)
                        }
                    )
                }
                .onPreferenceChange(NewAlbumsWidthKey.self) { newAlbumsWidth = $0 }
            }

            if !model.topArtists.isEmpty {
                Shelf(title: "推荐歌手", rowHeight: Theme.Layout.artistShelfHeight) {
                    ForEach(model.topArtists) { artist in
                        artistCard(artist)
                    }
                }
            }

            PlayerClearanceSpacer()
        }
        .padding(.top, Theme.Layout.pageTopPadding)
        .padding(.bottom, Theme.Layout.contentInset - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feature cards

    private var featureCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
                if account.isLoggedIn {
                    NavigationLink(value: Destination.daily) {
                        FeatureCard(
                            title: "每日推荐",
                            subtitle: "根据你的口味生成",
                            icon: "calendar",
                            coverURL: model.dailyFirstCover?.resizedImageURL(512),
                            showsDate: true
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.startFM()
                    } label: {
                        FeatureCard(
                            title: "私人漫游",
                            subtitle: "从喜欢的歌开始漫游",
                            icon: "wave.3.right.circle.fill",
                            gradient: [Color(red: 0.16, green: 0.20, blue: 0.42),
                                       Color(red: 0.36, green: 0.24, blue: 0.62)]
                        )
                    }
                    .buttonStyle(.interactiveCard)

                    Button {
                        startHeartbeatMode()
                    } label: {
                        FeatureCard(
                            title: "心动模式",
                            subtitle: "你的红心歌曲和相似推荐",
                            icon: "heart.circle.fill",
                            gradient: [Color(red: 0.85, green: 0.19, blue: 0.41),
                                       Color(red: 0.98, green: 0.42, blue: 0.34)]
                        )
                    }
                    .buttonStyle(.interactiveCard)
                }
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
            }
            .padding(.vertical, 6)
        }
        .compatScrollClipDisabled()
        .shelfEdgeClip()
    }

    private func startHeartbeatMode() {
        guard let likedList = account.likedSongsPlaylist else { return }
        Task {
            guard let seed = account.likedTrackIDs.randomElement() else {
                ToastCenter.shared.show(String(localized: "先收藏一些喜欢的歌曲吧"))
                return
            }
            do {
                let tracks = try await MusicAPI.intelligenceList(songID: seed, playlistID: likedList.id)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(likedList.id),
                            context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // MARK: - Cards

    private func playlistCard(_ playlist: PlaylistSummary) -> some View {
        NavigationLink(value: Destination.playlist(playlist.id)) {
            CoverCardBody(
                coverURL: playlist.coverURL?.resizedImageURL(384),
                title: playlist.name,
                subtitle: playlist.copywriter,
                playCount: playlist.playCount,
                titleLineLimit: Theme.Layout.shelfTitleLineLimit
            ) {
                playPlaylist(playlist.id)
            }
        }
        .buttonStyle(.plain)
    }

    private func albumCard(_ album: AlbumSummary, size: CGFloat) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.artistName,
                size: size,
                titleLineLimit: Theme.Layout.shelfTitleLineLimit
            ) {
                Task {
                    if let detail = try? await MusicAPI.album(id: album.id) {
                        player.play(tracks: detail.songs, source: .album(album.id),
                                    context: .album(id: album.id, name: album.name))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func artistCard(_ artist: ArtistSummary) -> some View {
        NavigationLink(value: Destination.artist(artist.id)) {
            VStack(spacing: 10) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                    .frame(width: 128, height: 128)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    private func toplistRow(_ toplist: ToplistItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(toplist.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if toplist.tracks.isEmpty {
                    // No track previews: fall back to the update frequency.
                    // Guarded so a missing frequency leaves no empty line.
                    if let frequency = toplist.updateFrequency, !frequency.isEmpty {
                        Text(frequency)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    ForEach(Array(toplist.tracks.prefix(3).enumerated()), id: \.offset) { index, track in
                        Text("\(index + 1) \(track.first) - \(track.second)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - 地区热门 / 喜欢的歌手推荐

    /// Two songs per column, columns scrolling horizontally — the same shape
    /// as 新碟上架 (two album cards per column). Each column is one
    /// TrackListView of two tracks, so rows keep their play, download and
    /// menu behaviour. A column is most of the content width with the next
    /// one peeking in, so the shelf reads as swipeable.
    private func songPairShelf(tracks: [Track]) -> some View {
        let pairs = stride(from: 0, to: tracks.count, by: 2)
            .map { Array(tracks[$0..<min($0 + 2, tracks.count)]) }
        let width = songShelfWidth > 0 ? songShelfWidth : UIScreen.main.bounds.width
        let columnWidth = max(240, (width - Theme.Layout.contentInset * 2) * 0.86)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(pairs.indices, id: \.self) { index in
                    TrackListView(tracks: pairs[index], style: .compact, source: .none)
                        .frame(width: columnWidth)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
        .shelfEdgeClip()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SongShelfWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(SongShelfWidthKey.self) { songShelfWidth = $0 }
    }

    private var regionalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
            SectionHeader(title: "地区热门")
                .padding(.horizontal, Theme.Layout.contentInset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Spacer().frame(width: Theme.Layout.contentInset - 8)
                    ForEach(HomeViewModel.RegionalArea.allCases) { area in
                        Button {
                            model.regionalArea = area
                        } label: {
                            Text(area.title)
                        }
                        .buttonStyle(.chip(isSelected: model.regionalArea == area))
                    }
                    Spacer().frame(width: Theme.Layout.contentInset - 8)
                }
                .padding(.vertical, 2)
            }
            .shelfEdgeClip()
            if model.regionalLoading && model.regionalSongs.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if !model.regionalSongs.isEmpty {
                songPairShelf(tracks: Array(model.regionalSongs.prefix(10)))
            }
        }
        .task(id: "\(model.refreshNonce)-\(model.regionalArea.rawValue)") {
            await model.loadRegional(area: model.regionalArea)
        }
    }

    private var likedArtistSection: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
            SectionHeader(title: "喜欢的歌手推荐")
                .padding(.horizontal, Theme.Layout.contentInset)
            if model.likedArtistLoading && model.likedArtistSongs.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if !model.likedArtistSongs.isEmpty {
                songPairShelf(tracks: Array(model.likedArtistSongs.prefix(10)))
            }
        }
        .task(id: "\(model.refreshNonce)-\(account.likedArtists.map(\.id))") {
            await model.loadLikedArtistSongs(artists: account.likedArtists, excluding: account.likedTrackIDs)
        }
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

// MARK: - Feature card

struct FeatureCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    var coverURL: URL?
    var gradient: [Color] = [Color(red: 0.75, green: 0.16, blue: 0.22),
                             Color(red: 0.95, green: 0.35, blue: 0.28)]
    var showsDate = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let coverURL {
                CachedAsyncImage(url: coverURL)
                    .frame(width: 230, height: 132)
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.68)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.18), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 220)
            }

            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                    if showsDate {
                        Text("\(Calendar.current.component(.day, from: .now))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(y: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(14)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .frame(width: 230, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

/// Card body without its own Button wrapper (for use inside NavigationLink).
struct CoverCardBody: View {
    let coverURL: URL?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = Theme.Layout.cardSize
    var titleLineLimit = 2
    var onPlay: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.flexibleCardWidth) private var flexibleWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if playCount > 0 {
                        PlayCountBadge(count: playCount)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let onPlay {
                        PlayOverlayButton(visible: isHovering, action: onPlay)
                            .padding(8)
                    }
                }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(titleLineLimit)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            }
        }
        .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    @ViewBuilder
    private var artwork: some View {
        if flexibleWidth {
            CachedAsyncImage(url: coverURL)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            CachedAsyncImage(url: coverURL)
                .frame(width: size, height: size)
        }
    }
}
