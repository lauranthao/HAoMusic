import SwiftUI


struct PlaylistDetailView: View {
    let playlistID: Int
    var isLikedList = false
    var recommendationContext: RecommendationContext?

    @StateObject private var model: PlaylistContent
    @ObservedObject private var downloads = DownloadManager.shared
    // This page only sends playback commands; individual rows observe playback.
    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showFullDescription = false
    @State private var isSubscribing = false
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    init(playlistID: Int, isLikedList: Bool = false, recommendationContext: RecommendationContext? = nil) {
        self.playlistID = playlistID
        self.isLikedList = isLikedList
        self.recommendationContext = recommendationContext
        _model = StateObject(wrappedValue: PlaylistContent(playlistID: playlistID))
    }

    private var isOwnPlaylist: Bool {
        model.detail?.creator?.userId == account.profile?.userId
    }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    /// The account's own 我喜欢的音乐, whose 更多 menu also offers sorting.
    private var isOwnLikedSongs: Bool {
        model.detail?.specialType == 5 && isOwnPlaylist
    }

    /// The in-list search is permanent on iOS (macOS keeps its search field
    /// in the action row).
    private var supportsPlaylistSearch: Bool {
        #if os(iOS)
        return model.detail != nil
        #else
        return false
        #endif
    }

    /// Loading notes that mention search: always on the liked list, and on
    /// any other playlist while it is being searched.
    private var showsSearchLoadingNotes: Bool {
        supportsPlaylistSearch && (isOwnLikedSongs || TrackSearch.query(model.filter) != nil)
    }

    var body: some View {
        onlineContent
            .task(id: "\(playlistID):\(account.offlineScope ?? ""):\(downloads.network.isKnown):\(downloads.network.connected)") {
                await loadPlaylist()
            }
            .toolbar {
                if model.errorMessage != nil, downloads.network.connected, model.detail != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await loadPlaylist() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("重试")
                            .help("重试")
                    }
                }
            }
    }

    private func loadPlaylist() async {
        await model.load(allowNetwork: !downloads.network.isKnown || downloads.network.connected,
                         summary: account.userPlaylists.first { $0.id == playlistID })
    }

    @ViewBuilder
    private var onlineContent: some View {
        #if os(macOS)
        Group {
            if model.loadedScope == account.offlineScope, let detail = model.detail {
                let tracks = model.filteredTracks
                TrackTable(
                    trackIDs: tracks.map(\.id),
                    header: AnyView(regularHeader(detail)
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)
                        .padding(.bottom, 20)),
                    footer: AnyView(VStack(spacing: 20) {
                        playlistStatus(detail)
                        PlayerClearanceSpacer()
                    }.padding(.top, 20)),
                    headerHeight: 246,
                    footerHeight: desktopFooterHeight(detail)
                ) { index in
                    AnyView(trackList(tracks, layout: .singleRow(index))
                        .padding(.horizontal, Theme.Layout.contentInset - 10))
                }
            } else {
                ScrollView { playlistContents }
            }
        }
        .clipped()
        .navigationTitle(model.detail?.name ?? String(localized: "歌单"))
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                playlistContents
            }
            .id("playlistTop")
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .detailArtworkBackground(model.detail?.coverImgUrl)
    }

    #if os(macOS)
    private func desktopFooterHeight(_ detail: PlaylistDetail) -> CGFloat {
        let clearance = Theme.Layout.playerChromeClearance + Theme.Layout.scrollBreathingMargin + 20
        if model.isLoading || model.isLoadingMore { return clearance + 60 }
        if model.tracks.isEmpty { return clearance + 100 }
        if model.tracks.count < detail.trackCount { return clearance + 40 }
        return clearance
    }
    #endif

    private func trackList(_ tracks: [Track], layout: TrackListView.Layout = .stack) -> some View {
        TrackListView(
            tracks: tracks,
            privileges: model.privileges,
            source: .playlist(playlistID),
            context: model.detail.map { .playlist(id: playlistID, name: $0.name) },
            removableFromPlaylistID: isOwnPlaylist ? playlistID : nil,
            onRemoved: { track in Task { await model.remove(track) } },
            recommendationContext: recommendationContext,
            onRecommendationReplaced: { model.replaceRecommendation($0, with: $1) },
            layout: layout,
            // A search result plays the whole playlist from that song.
            queue: model.orderedTracks
        )
    }

    @ViewBuilder
    private var playlistContents: some View {
        if model.loadedScope == account.offlineScope, let detail = model.detail {
            let filteredTracks = model.filteredTracks
            if isCompact {
                compactHeader(detail)
                    .padding(.top, 12)
            } else {
                regularHeader(detail)
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.top, 16)
            }

            #if os(iOS)
            if supportsPlaylistSearch && TrackSearch.query(model.filter) != nil {
                SongSearchSummary(
                    count: filteredTracks.count,
                    isSettled: !model.isLoadingMore && model.errorMessage == nil,
                    onClear: { model.filter = "" },
                    horizontalPadding: isCompact ? 16 : Theme.Layout.contentInset
                )
            }
            #endif

            trackList(filteredTracks)
                .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)

            playlistStatus(detail)
        } else if model.isLoading {
            loadingHeader
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await loadPlaylist() }
            }
            .frame(minHeight: 400)
        } else {
            EmptyStateView(icon: "music.note.list", title: "联网后载入歌曲")
                .frame(minHeight: 400)
        }
        PlayerClearanceSpacer()
    }

    @ViewBuilder
    private func playlistStatus(_ detail: PlaylistDetail) -> some View {
        if model.isLoading || model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                #if os(iOS)
                if showsSearchLoadingNotes {
                    Text("正在加载歌单，搜索结果会继续更新…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                #endif
                Spacer()
            }
            .padding(.vertical, 12)
        } else if model.tracks.isEmpty {
            Text(detail.trackCount == 0 ? String(localized: "歌单暂无歌曲") : String(localized: "联网后载入歌曲"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if model.tracks.count < detail.trackCount {
            Text("已载入 \(model.tracks.count)/\(detail.trackCount) 首")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        }

        #if os(iOS)
        if showsSearchLoadingNotes, model.tracks.count < detail.trackCount, let message = model.errorMessage {
            VStack(spacing: 8) {
                Text("歌单未完整加载，搜索结果可能不完整")
                    .font(.subheadline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await loadPlaylist() } }
                    .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        }
        #endif
    }

    // MARK: - Compact (Mobile) Header

    // Coda-style hero: search bar above a large centred cover, creator row,
    // counts, then the star / 播放 / more row.
    private func compactHeader(_ detail: PlaylistDetail) -> some View {
        PlaylistHeader(filter: $model.filter, placeholder: String(localized: "在歌单中搜索")) {
            PlaylistDetailHero(
                coverURL: detail.coverImgUrl,
                title: isLikedList ? String(localized: "我喜欢的音乐") : detail.name,
                subtitle: detail.creator?.nickname ?? String(localized: "网易云音乐"),
                avatarURL: detail.creator?.avatarUrl,
                metadataText: "\(detail.trackCount) 首歌曲 · \(Formatters.playCount(detail.playCount)) 次播放",
                showsAvatar: detail.creator != nil
            ) {
                PlaylistPrimaryActions(
                    isSaved: detail.subscribed,
                    canSave: account.isLoggedIn && !isOwnPlaylist,
                    canPlay: !playable.isEmpty,
                    isSaving: isSubscribing,
                    onToggleSaved: { toggleSubscribe(detail) },
                    onPlayAll: {
                        player.play(tracks: playable, source: .playlist(playlistID),
                                    context: model.detail.map { .playlist(id: playlistID, name: $0.name) })
                    },
                    showsSaveButton: !isOwnPlaylist && account.isLoggedIn,
                    saveAccessibilityLabel: detail.subscribed ? String(localized: "取消收藏歌单") : String(localized: "收藏歌单")
                ) {
                    Menu {
                        if let description = detail.description, !description.isEmpty {
                            Button { showFullDescription = true } label: {
                                Label("歌单简介", systemImage: "text.alignleft")
                            }
                        }
                        if isLikedList {
                            Button(action: startHeartbeat) {
                                Label("心动", systemImage: "heart.circle")
                            }
                            .disabled(playable.isEmpty)
                        }
                        if isOwnPlaylist, !isLikedList {
                            Button("删除歌单", role: .destructive) { showDeleteConfirm = true }
                        }
                        Menu {
                            Picker("排序方式", selection: $model.sortOrder) {
                                ForEach(PlaylistTrackSort.allCases, id: \.self) { order in
                                    Text(LocalizedStringKey(order.rawValue)).tag(order)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Label("排序方式", systemImage: "arrow.up.arrow.down")
                        }
                        DownloadCollectionButton(tracks: model.tracks, owner: "playlist:\(playlistID)",
                                                 name: detail.name, enabled: model.canDownloadAll,
                                                 menuPresentation: true)
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
                    Text(detail.description ?? "")
                        .font(.system(size: 14))
                        .padding(20)
                }
                .navigationTitle("歌单简介")
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
        .alert("删除歌单", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { deletePlaylist() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除“\(detail.name)”吗？")
        }
    }

    private func deletePlaylist() {
        Task {
            do {
                try await MusicAPI.deletePlaylist(id: playlistID)
                await account.refreshLibrary()
                ToastCenter.shared.show(String(localized: "歌单已删除"))
                dismiss()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // MARK: - Regular (Desktop / iPad) Header

    private func regularHeader(_ detail: PlaylistDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(512))
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(isLikedList ? String(localized: "我喜欢的音乐") : String(localized: "歌单"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(detail.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let creator = detail.creator {
                    HStack(spacing: 6) {
                        CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                            .frame(width: 18, height: 18)
                            .clipShape(Circle())
                        Text(creator.nickname)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放 · 更新于 \(Formatters.date(fromMS: detail.updateTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = detail.description, !description.isEmpty {
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

                actionRow(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
    }

    private func actionRow(_ detail: PlaylistDetail) -> some View {
        HStack(spacing: 10) {
            Button {
                player.play(tracks: playable, source: .playlist(playlistID),
                            context: .playlist(id: playlistID, name: detail.name))
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(.pressable)
            .disabled(playable.isEmpty)

            if isLikedList {
                Button {
                    startHeartbeat()
                } label: {
                    Label("心动模式", systemImage: "heart.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            } else if !isOwnPlaylist, account.isLoggedIn {
                Button {
                    toggleSubscribe(detail)
                } label: {
                    Label(detail.subscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                          systemImage: detail.subscribed ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            }

            downloadButton(detail)

            #if os(macOS)
            Spacer()

            ListFilterField(placeholder: "搜索歌单内歌曲", text: $model.filter)
            #endif
        }
    }

    private var playable: [Track] {
        let tracks = model.orderedTracks
        if SettingsManager.shared.canResolveUnblockedTracks { return tracks }
        return tracks.filter { track in
            downloads.offlineTracksByID[track.id] != nil || track.playability(privilege: model.privileges[track.id],
                           isLoggedIn: account.isLoggedIn,
                           vipType: account.vipType) == .playable
        }
    }

    private func startHeartbeat() {
        Task {
            guard let seed = playable.randomElement() else { return }
            do {
                let tracks = try await MusicAPI.intelligenceList(songID: seed.id, playlistID: playlistID)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(playlistID), context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func toggleSubscribe(_ detail: PlaylistDetail) {
        guard !isSubscribing else { return }
        isSubscribing = true
        Task {
            defer { isSubscribing = false }
            do {
                try await MusicAPI.subscribePlaylist(id: detail.id, subscribe: !detail.subscribed)
                model.detail?.subscribed.toggle()
                await account.refreshLibrary()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func downloadButton(_ detail: PlaylistDetail, compact: Bool = false) -> some View {
        DownloadCollectionButton(tracks: model.tracks, owner: "playlist:\(playlistID)", name: detail.name,
                                 enabled: model.canDownloadAll, compact: compact)
            .accessibilityHint("等待歌单完整加载后下载全部歌曲")
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? Theme.Radius.standard : Theme.Radius.large)
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 160 : 220, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
