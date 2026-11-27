import SwiftUI

struct ArtistDetailView: View {
    let artistID: Int

    @State private var artist: ArtistSummary?
    @State private var hotSongs: [Track] = []
    @State private var albums: [AlbumSummary] = []
    @State private var epsAndSingles: [AlbumSummary] = []
    @State private var similar: [ArtistSummary] = []
    @State private var isFollowed = false
    @State private var isUpdatingFollow = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompact: Bool {
        #if os(iOS)
        return LayoutSizeClass.isCompact(horizontal: horizontalSizeClass, vertical: verticalSizeClass,
                                         fallback: UIDevice.current.userInterfaceIdiom == .phone)
        #else
        return false
        #endif
    }

    var body: some View {
        TrackListScrollView(trackIDs: hotSongs.map(\.id), style: .compact, spacing: isCompact ? 16 : 26) {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 26) {
                if let artist {
                    if isCompact {
                        compactHeader(artist).padding(.top, 12)
                    } else {
                        regularHeader(artist).padding(.horizontal, Theme.Layout.contentInset).padding(.top, 16)
                    }
                    if !hotSongs.isEmpty {
                        SectionHeader(title: "热门单曲") {
                            openDestination(.artistSection(artistID, .songs))
                        }
                        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
                    }
                } else if isLoading {
                    loadingHeader
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                        .frame(minHeight: 400)
                }
            }
        } rows: { layout in
            TrackListView(tracks: hotSongs, style: .compact, source: .artist(artistID),
                          context: artist.map { .artist(id: artistID, name: $0.name) }, layout: layout)
                .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
        } footer: {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 26) {
                if !albums.isEmpty {
                    SectionHeader(title: "专辑") {
                        openDestination(.artistSection(artistID, .albums))
                    }
                    .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            ForEach(albums) { album in
                                albumCard(album)
                            }
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                        }
                    }
                }

                if !epsAndSingles.isEmpty {
                    SectionHeader(title: "EP 与单曲") {
                        openDestination(.artistSection(artistID, .singles))
                    }
                    .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            ForEach(epsAndSingles) { album in
                                albumCard(album)
                            }
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                        }
                    }
                }

                if !similar.isEmpty {
                    SectionHeader(title: "相似歌手") {
                        openDestination(.artistSection(artistID, .similar))
                    }
                    .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            ForEach(similar) { sim in
                                NavigationLink(value: Destination.artist(sim.id)) {
                                    VStack(spacing: 8) {
                                        CachedAsyncImage(url: sim.picUrl?.resizedImageURL(256))
                                            .frame(width: isCompact ? 80 : 100, height: isCompact ? 80 : 100)
                                            .clipShape(Circle())
                                        Text(sim.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .frame(width: isCompact ? 80 : 100)
                                }
                                .buttonStyle(.interactiveCard)
                            }
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                        }
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        #if os(macOS)
        .navigationTitle(artist?.name ?? String(localized: "歌手"))
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .detailArtworkBackground(artist?.picUrl)
        .task(id: artistID) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await MusicAPI.artist(id: artistID)
            artist = response.artist
            hotSongs = response.hotSongs
            isFollowed = response.artist.followed
            isLoading = false

            if let result = try? await MusicAPI.artistAlbums(id: artistID, limit: 60) {
                albums = result.hotAlbums.filter { $0.size > 1 }
                epsAndSingles = result.hotAlbums.filter { $0.size <= 1 }
            }
            if account.isLoggedIn {
                similar = (try? await MusicAPI.similarArtists(id: artistID)) ?? []
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Compact Header

    // Coda-style hero: large circular photo, alias, counts, then the
    // follow / 播放 / more row.
    private func compactHeader(_ artist: ArtistSummary) -> some View {
        PlaylistDetailHero(
            coverURL: artist.picUrl,
            title: artist.name,
            subtitle: artist.alias.isEmpty ? String(localized: "歌手") : artist.alias.joined(separator: " / "),
            avatarURL: nil,
            metadataText: "\(artist.musicSize) 首歌曲 · \(artist.albumSize) 张专辑",
            circularArtwork: true,
            showsAvatar: false
        ) {
            PlaylistPrimaryActions(
                isSaved: isFollowed,
                canSave: account.isLoggedIn && !isLoading,
                canPlay: !hotSongs.isEmpty,
                isSaving: isUpdatingFollow,
                onToggleSaved: toggleFollow,
                onPlayAll: {
                    player.play(tracks: hotSongs, source: .artist(artistID),
                                context: .artist(id: artistID, name: artist.name))
                },
                showsSaveButton: account.isLoggedIn,
                saveAccessibilityLabel: isFollowed ? String(localized: "取消关注歌手") : String(localized: "关注歌手")
            ) {
                Menu {
                    DownloadCollectionButton(tracks: hotSongs, owner: "artist:\(artistID)",
                                             name: "\(artist.name) · 热门单曲", menuPresentation: true)
                    if account.authenticatedAccountID != nil, artistID > 0 {
                        MusicBlacklistButton(target: .artist(artistID), title: "减少推荐")
                    }
                } label: {
                    PlaylistMoreLabel()
                }
                .accessibilityLabel("更多操作")
            }
        }
    }

    // MARK: - Regular Header

    private func regularHeader(_ artist: ArtistSummary) -> some View {
        HStack(alignment: .center, spacing: 28) {
            CachedAsyncImage(url: artist.picUrl?.resizedImageURL(512))
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("歌手")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(artist.name)
                    .font(.largeTitle.weight(.bold))
                if !artist.alias.isEmpty {
                    Text(artist.alias.joined(separator: " / "))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text("\(artist.musicSize) 首歌曲 · \(artist.albumSize) 张专辑")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 6)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: hotSongs, source: .artist(artistID),
                                context: .artist(id: artistID, name: artist.name))
                    } label: {
                        Label("播放热门", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)

                    if account.isLoggedIn {
                        Button {
                            toggleFollow()
                        } label: {
                            Label(isFollowed ? String(localized: "已关注") : String(localized: "关注"),
                                  systemImage: isFollowed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                        blacklistMenu
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var blacklistMenu: some View {
        if account.authenticatedAccountID != nil, artistID > 0 {
            Menu {
                MusicBlacklistButton(target: .artist(artistID), title: "减少推荐")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            .accessibilityLabel("更多操作")
        }
    }

    private func albumCard(_ album: AlbumSummary) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.publishYear
            )
        }
        .buttonStyle(.interactiveCard)
    }

    private func toggleFollow() {
        guard !isUpdatingFollow, account.isLoggedIn else { return }
        isUpdatingFollow = true
        Task {
            defer { isUpdatingFollow = false }
            do {
                try await MusicAPI.subscribeArtist(id: artistID, subscribe: !isFollowed)
                isFollowed.toggle()
                // The 我的 page reads the followed artists from the account:
                // refresh them now so the shelf shows this artist without
                // opening 收藏 first.
                await account.refreshSublists()
                ToastCenter.shared.show(isFollowed ? String(localized: "已关注歌手") : String(localized: "已取消关注"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .center, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? 50 : 90)
                .clipShape(Circle())
                .frame(width: isCompact ? 100 : 180, height: isCompact ? 100 : 180)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 150 : 180, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 100, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}

enum ArtistSection: String, Hashable {
    case songs, albums, singles, similar

    var title: String {
        switch self {
        case .songs: return String(localized: "热门单曲")
        case .albums: return String(localized: "专辑")
        case .singles: return String(localized: "EP 与单曲")
        case .similar: return String(localized: "相似歌手")
        }
    }
}

/// One artist section, full page: songs list, album/single grids or a
/// similar-artists grid, with load-more for albums and singles.
/// (Coda's ArtistSectionView, same structure.)
struct ArtistSectionView: View {
    let artistID: Int
    let section: ArtistSection

    @State private var artistName: String?
    @State private var songs: [Track] = []
    @State private var albums: [AlbumSummary] = []
    @State private var artists: [ArtistSummary] = []
    @State private var offset = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if section == .songs {
                    TrackListView(tracks: songs, style: .compact, source: .artist(artistID),
                                  context: artistName.map { .artist(id: artistID, name: $0) })
                        .padding(.horizontal, 6)
                } else {
                    CardGrid {
                        if section == .similar {
                            ForEach(artists) { artist in
                                NavigationLink(value: Destination.artist(artist.id)) {
                                    VStack(spacing: 8) {
                                        CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                                            .frame(width: 100, height: 100)
                                            .clipShape(Circle())
                                        Text(artist.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .frame(width: 100)
                                }
                                .buttonStyle(.interactiveCard)
                            }
                        } else {
                            ForEach(albums) { album in
                                NavigationLink(value: Destination.album(album.id)) {
                                    CoverCardBody(
                                        coverURL: album.picUrl?.resizedImageURL(384),
                                        title: album.name,
                                        subtitle: album.publishYear
                                    )
                                }
                                .buttonStyle(.interactiveCard)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if let error {
                    ErrorStateView(message: error) { Task { await loadMore() } }
                } else if hasMore {
                    Button("加载更多") { Task { await loadMore() } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else if songs.isEmpty && albums.isEmpty && artists.isEmpty {
                    Text("暂无内容").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 16)
        }
        .navigationTitle(section.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { if !didLoad { await loadMore() } }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            switch section {
            case .songs:
                let result = try await MusicAPI.artist(id: artistID)
                try Task.checkCancellation()
                artistName = result.artist.name
                songs = result.hotSongs
                hasMore = false
            case .similar:
                let result = try await MusicAPI.similarArtists(id: artistID)
                try Task.checkCancellation()
                artists = result
                hasMore = false
            case .albums, .singles:
                let result = try await MusicAPI.artistAlbums(id: artistID, limit: 60, offset: offset)
                try Task.checkCancellation()
                let existing = Set(albums.map(\.id))
                albums += result.hotAlbums.filter {
                    !existing.contains($0.id) && (section == .albums ? $0.size > 1 : $0.size <= 1)
                }
                offset += result.hotAlbums.count
                hasMore = !result.hotAlbums.isEmpty && (result.more ?? (result.hotAlbums.count == 60))
            }
            didLoad = true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
