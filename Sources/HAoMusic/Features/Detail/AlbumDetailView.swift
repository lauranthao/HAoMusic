import SwiftUI

struct AlbumDetailView: View {
    let albumID: Int

    @State private var album: AlbumDetail?
    @State private var tracks: [Track] = []
    @State private var otherAlbums: [AlbumSummary] = []
    @State private var isSubscribed = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showFullDescription = false
    @State private var isSubscribing = false
    @State private var searchText = ""
    @State private var loadGeneration = 0
    @ObservedObject private var downloads = DownloadManager.shared

    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore
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

    /// Only a collection with songs to show may replace the online page,
    /// otherwise an empty list would hide the error and its retry button.
    private var savedCollectionID: String? {
        let id = "album:\(albumID)"
        return downloads.downloadedSongs(in: id).isEmpty ? nil : id
    }

    var body: some View {
        Group {
            if let savedCollectionID, !downloads.network.connected || errorMessage != nil {
                DownloadedMusicView(collectionID: savedCollectionID)
            } else { onlineContent }
        }
        .task(id: "\(albumID):\(downloads.network.connected)") {
            if downloads.network.connected || savedCollectionID == nil { await load() }
        }
        .toolbar {
            if errorMessage != nil, downloads.network.connected, album != nil || savedCollectionID != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重试")
                        .help("重试")
                }
            }
        }
    }

    /// Songs shown in the list (and played by 播放): the in-album search
    /// filters by song, artist or album name; empty query shows everything.
    private var displayedTracks: [Track] {
        guard let query = TrackSearch.query(searchText) else { return tracks }
        return tracks.filter { TrackSearch.matches($0, query: query) }
    }

    private var onlineContent: some View {
        TrackListScrollView(trackIDs: displayedTracks.map(\.id), spacing: isCompact ? 16 : 20) {
            if let album {
                if isCompact {
                    compactHeader(album).padding(.top, 12)
                } else {
                    regularHeader(album).padding(.horizontal, Theme.Layout.contentInset).padding(.top, 16)
                }
            } else if isLoading {
                loadingHeader
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) { Task { await load() } }
                    .frame(minHeight: 400)
            }
        } rows: { layout in
            TrackListView(tracks: displayedTracks, source: .album(albumID),
                          context: album.map { .album(id: albumID, name: $0.name) }, layout: layout)
                .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
        } footer: {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                if !otherAlbums.isEmpty {
                    SectionHeader(title: "该歌手的其他专辑")
                        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
                        .padding(.top, 12)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            ForEach(otherAlbums) { item in
                                NavigationLink(value: Destination.album(item.id)) {
                                    CoverCardBody(
                                        coverURL: item.picUrl?.resizedImageURL(384),
                                        title: item.name,
                                        subtitle: Formatters.date(fromMS: item.publishTime)
                                    )
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
        .navigationTitle(album?.name ?? String(localized: "专辑"))
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .detailArtworkBackground(album?.picUrl)
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let response = try await MusicAPI.album(id: albumID)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            album = response.album
            tracks = response.songs
            isLoading = false
            if let dynamic = try? await MusicAPI.albumDynamic(id: albumID) {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                isSubscribed = dynamic.isSub ?? false
            }
            if let artistID = response.album.artist?.id,
               let albums = try? await MusicAPI.artistAlbums(id: artistID, limit: 12) {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                otherAlbums = albums.hotAlbums.filter { $0.id != albumID }
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Compact Header

    // Coda-style hero: search bar above a large centred cover, title,
    // artist row, metadata, then the star / 播放 / more row.
    private func compactHeader(_ album: AlbumDetail) -> some View {
        PlaylistHeader(filter: $searchText, placeholder: String(localized: "在专辑中搜索")) {
            PlaylistDetailHero(
                coverURL: album.picUrl,
                title: album.name,
                subtitle: album.artist?.name ?? String(localized: "专辑"),
                avatarURL: album.artist?.picUrl,
                metadataText: album.publishTime > 0
                    ? "\(tracks.count) 首歌曲 · \(totalDuration) · \(Formatters.date(fromMS: album.publishTime))"
                    : "\(tracks.count) 首歌曲 · \(totalDuration)",
                subtitleDestination: album.artist.map { Destination.artist($0.id) }
            ) {
                PlaylistPrimaryActions(
                    isSaved: isSubscribed,
                    canSave: account.isLoggedIn && !isLoading,
                    canPlay: !displayedTracks.isEmpty,
                    isSaving: isSubscribing,
                    onToggleSaved: toggleSubscribe,
                    onPlayAll: {
                        player.play(tracks: displayedTracks, source: .album(albumID),
                                    context: .album(id: albumID, name: album.name))
                    },
                    saveAccessibilityLabel: isSubscribed ? String(localized: "取消收藏专辑") : String(localized: "收藏专辑")
                ) {
                    Menu {
                        if let artist = album.artist {
                            NavigationLink(value: Destination.artist(artist.id)) {
                                Label("查看歌手", systemImage: "person.fill")
                            }
                        }
                        if let description = album.description, !description.isEmpty {
                            Button { showFullDescription = true } label: {
                                Label("专辑简介", systemImage: "text.alignleft")
                            }
                        }
                        DownloadCollectionButton(tracks: tracks, owner: "album:\(albumID)",
                                                 name: album.name, menuPresentation: true)
                    } label: {
                        PlaylistMoreLabel()
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .sheet(isPresented: $showFullDescription) {
            NavigationStack {
                ScrollView {
                    Text(album.description ?? "")
                        .font(.system(size: 14))
                        .padding(20)
                }
                .navigationTitle("专辑简介")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("完成") { showFullDescription = false }
                    }
                }
            }
        }
    }

    // MARK: - Regular Header

    private func regularHeader(_ album: AlbumDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: album.picUrl?.resizedImageURL(512))
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(album.subType?.isEmpty == false ? album.subType! : String(localized: "专辑"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(album.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let artist = album.artist {
                    NavigationLink(value: Destination.artist(artist.id)) {
                        Text(artist.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                Text("\(tracks.count) 首 · \(totalDuration) · \(Formatters.date(fromMS: album.publishTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = album.description, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: tracks, source: .album(albumID),
                                context: .album(id: albumID, name: album.name))
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)

                    DownloadCollectionButton(tracks: tracks, owner: "album:\(albumID)", name: album.name)

                    if account.isLoggedIn {
                        Button {
                            toggleSubscribe()
                        } label: {
                            Label(isSubscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                                  systemImage: isSubscribed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
    }

    private var totalDuration: String {
        let totalMS = tracks.reduce(into: 0) { $0 += $1.durationMS }
        return Formatters.longDuration(TimeInterval(totalMS) / 1000)
    }

    private func toggleSubscribe() {
        guard !isSubscribing else { return }
        isSubscribing = true
        Task {
            defer { isSubscribing = false }
            do {
                try await MusicAPI.subscribeAlbum(id: albumID, subscribe: !isSubscribed)
                isSubscribed.toggle()
                // The 我的 page reads the collected albums from the account:
                // refresh them now so the shelf shows this album without
                // opening 收藏 first.
                await account.refreshSublists()
                ToastCenter.shared.show(isSubscribed ? String(localized: "已收藏专辑") : String(localized: "已取消收藏"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? Theme.Radius.standard : Theme.Radius.large)
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 160 : 200, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
