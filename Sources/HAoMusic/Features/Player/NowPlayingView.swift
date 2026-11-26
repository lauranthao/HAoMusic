import SwiftUI

/// Immersive full-window now-playing page: artwork-tinted gradient backdrop,
/// large artwork on the left, big synced lyrics on the right.
struct NowPlayingView: View {
    let onOpenDestination: (Destination) -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    #endif
    #if os(iOS)
    @Environment(\.dismissNowPlayingAction) private var dismissNowPlayingAction
    @Environment(\.dismissNowPlayingDragAction) private var dismissNowPlayingDragAction
    @Environment(\.dismissNowPlayingThenAction) private var dismissNowPlayingThenAction
    #endif

    #if os(iOS)
    @State private var loadedArtwork = CachedImageState()
    @State private var loadedArtworkColors: ArtworkColors = .fallback
    #endif
    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var showLyricsOnMobile = false
    @State private var showQueueOnMobile = false
    /// Lyrics or comments in the regular page's right column (macOS, iPad).
    @State private var regularColumnPage = RegularColumnPage.lyrics
    #if os(iOS)
    @State private var showSoundEffects = false
    /// Held here rather than by the controls so the panel can sit above the
    /// whole page, with a catcher that closes it on a tap anywhere else.
    @State private var showsVolumeControl = false
    #endif

    #if os(iOS)
    // Coda's portrait player state (copied verbatim from Coda's
    // NowPlayingView). Only used on iPhone in the default immersive mode.
    // Restore the last explicit lyric/artwork choice across presentations and launches.
    @AppStorage("player.singleColumnLyricsVisible") private var showsSingleColumnLyrics = true
    @State private var portraitLyricsEntrancePresented = true
    @State private var portraitLyricsEntranceStartedAt: ContinuousClock.Instant?
    @State private var portraitLyricsExitStartedAt: ContinuousClock.Instant?
    @State private var portraitPreparedLyricsTrackID: Int?
    @State private var portraitArtworkPageFrame: CGRect = .zero
    @State private var portraitControlsCollapsed = false
    @State private var portraitControlsHeight: CGFloat = 320
    @State private var portraitControlsActivityGeneration = 0
    @State private var portraitControlsInteractionActive = false
    @Environment(\.accessibilityVoiceOverEnabled) private var playerVoiceOverEnabled
    /// Which portrait panel is showing (lyrics / queue / comments).
    private enum IPadPanel { case lyrics, queue, comments }
    @State private var iPadPanel: IPadPanel = .lyrics
    /// Track whose comments are open. HAo token (Int?) — Coda keeps a
    /// SongCommentsStore here; HAo's comments view takes just the track.
    @State private var iPadComments: Int?
    @State private var playlistTrack: Track?
    @ScaledMetric(relativeTo: .title3) private var iPadMetadataHeight: CGFloat = 56
    #endif

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            ZStack {
                #if os(iOS)
                if usesCodaPortrait(size: geo.size) {
                    // Coda's portrait player verbatim (members in the
                    // extension at the end of this file): touch shield,
                    // fluid backdrop, big cover with everything below it.
                    // No top header — chen 2026-11-26.
                    NowPlayingTouchShield()
                        .ignoresSafeArea()
                    codaBackdrop
                    portraitLayout(size: geo.size)
                } else {
                    backdrop
                    nowPlayingLayout(isCompact: isCompact, size: geo.size)
                }
                #else
                backdrop
                nowPlayingLayout(isCompact: isCompact, size: geo.size)
                #endif
            }
            // Pin to the screen width so an intrinsically-wide child can never
            // stretch the ZStack and push the corner overlays off-screen.
            .frame(width: geo.size.width)
            #if os(iOS)
            // The portrait track row's add-to-playlist button reads this.
            .environment(\.playlistPanelSelected, playlistTrack != nil)
            #endif
            #if os(iOS)
            .overlayPreferenceValue(CompactVolumeButtonAnchorKey.self) { anchor in
                volumeLayer(buttonAnchor: anchor)
            }
            #endif
            #if os(macOS)
            .overlay(alignment: .topTrailing) {
                // Toward the top-trailing corner, level with the window
                // buttons (#128): a 36pt bubble whose center matches the 14pt
                // traffic lights (y 19…33 inside the 52pt titlebar). Clear of
                // the leading corner, where the sidebar toggle sits on the
                // page below.
                collapseButton(diameter: 36, glyphSize: 14)
                    .padding(.top, 8)
                    .padding(.trailing, 24)
            }
            #else
            .overlay(alignment: .topLeading) {
                if showsClassicChrome(isCompact: isCompact) {
                    collapseButton(diameter: 36, glyphSize: 14)
                        .padding(.top, 20)
                        .padding(.leading, 20)
                }
            }
            #endif
            .overlay(alignment: .topTrailing) {
                if isCompact, showsClassicChrome(isCompact: isCompact) {
                    HStack(spacing: 8) {
                        #if os(iOS)
                        // The EQ button used to sit here; the Coda copy
                        // moved it into the "..." menu instead.
                        soundEffectsMenu()
                        #endif

                        Button {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile.toggle()
                            }
                        } label: {
                            Image(systemName: showLyricsOnMobile ? "music.note" : "quote.bubble")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(showLyricsOnMobile ? Theme.accent : .white.opacity(0.85))
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.pressable)
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 20)
                }
            }
            #if os(iOS)
            .overlay(alignment: .topTrailing) {
                // The non-compact two-column page (iPad split-screen,
                // iPhone landscape classic style) has no "..." menu
                // anywhere else, so the equalizer gets one here. The
                // landscape immersive page keeps its own utility row.
                if !isCompact, settings.landscapeNowPlayingStyle == .classic {
                    soundEffectsMenu()
                        .padding(.top, 20)
                        .padding(.trailing, 20)
                }
            }
            #endif
            #if os(iOS)
            .overlay {
                if settings.nowPlayingMode == .minimal && showQueueOnMobile {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showQueueOnMobile = false }
                        .accessibilityLabel("关闭播放列表")
                        .accessibilityAddTraits(.isButton)
                }
            }
            #endif
        }
        #if os(macOS)
        // The window toolbar is hidden while this page is up, but SwiftUI keeps
        // reserving its safe area, which pushed the whole immersive layout —
        // close button included — a toolbar's height down from the window top.
        // iOS keeps its safe area: there the inset is the status bar / notch.
        .ignoresSafeArea()
        #endif
        .preferredColorScheme(.dark)
        #if os(iOS)
        .soundEffectsPresentation(
            isPresented: $showSoundEffects,
            settings: settings
        )
        .modifier(OfflinePlaybackAlert(player: player, onDownloads: { onOpenDestination(.downloaded) },
            enabled: player.showNowPlaying && !(settings.nowPlayingMode == .minimal && showQueueOnMobile)))
        .modifier(MeteredDownloadAlert(enabled: player.showNowPlaying && !(settings.nowPlayingMode == .minimal && showQueueOnMobile)))
        #endif
        #if os(iOS)
        .task(id: currentArtworkURL) {
            await loadArtwork()
        }
        #endif
        #if os(iOS)
        .task(id: player.currentTrack?.id) {
            await player.loadCurrentLyricsIfNeeded()
        }
        #endif
        #if os(iOS)
        .onAppear {
            showLyricsOnMobile = settings.nowPlayingMode == .immersive
            showQueueOnMobile = false
        }
        .onChange(of: settings.nowPlayingMode) { _ in
            showLyricsOnMobile = settings.nowPlayingMode == .immersive
            showQueueOnMobile = false
        }
        .onChange(of: player.currentTrack?.id) { _ in
            if settings.nowPlayingMode == .minimal || settings.nowPlayingMode == .vinyl {
                showLyricsOnMobile = false
            }
        }
        .onChange(of: player.currentTrack?.id) { _ in
            // Coda's portrait bookkeeping: keep the add-to-playlist panel on
            // the new track, and re-open comments for it if they were open.
            if playlistTrack != nil { playlistTrack = player.currentTrack }
            iPadComments = iPadPanel == .comments ? player.currentTrack?.id : nil
        }
        #endif
        #if os(macOS)
        .onExitCommand {
            close()
        }
        #endif
    }

    #if os(iOS)
    /// Coda's portrait player, for chen's phone in the default immersive mode.
    /// iPad, landscape and the other modes keep HAo's existing layouts.
    private func usesCodaPortrait(size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            && settings.nowPlayingMode == .immersive
            && usesPortraitLayout(size: size)
    }

    /// Coda's fluid background for the portrait player (Metal audio-reactive
    /// when available, gradient fallback). No wallpaper here, as everywhere
    /// in the player.
    private var codaBackdrop: some View {
        NowPlayingFluidBackground(artwork: artworkImage, artworkKey: player.currentTrack?.album.picUrl,
                                  colors: colors, playing: player.isPlaying)
            .environment(\.colorScheme, .dark)
    }
    #endif

    /// HAo's own layout dispatch (compact / regular / landscape immersive),
    /// factored out so the portrait branch can sit beside it. The compact
    /// cap below is unchanged from the old inline dispatch.
    @ViewBuilder
    private func nowPlayingLayout(isCompact: Bool, size: CGSize) -> some View {
        if isCompact {
            // Cap the compact layout at the screen height. The
            // lyrics middle is a ScrollView (inside the pager's
            // TabView) whose ideal height is its full content, so
            // without a cap the VStack sizes taller than the screen
            // in the lyrics state and shoves the scrubber, transport
            // and secondary row off the bottom edge (#18). A max cap
            // only binds when the content overflows: the artwork
            // state is shorter than the screen and stays exactly as
            // it is; the lyrics state flexes the middle and the
            // lyrics scroll inside it.
            compactLayout(size: size)
                .frame(maxHeight: size.height)
        } else {
            #if os(iOS)
            switch settings.landscapeNowPlayingStyle {
            case .classic:
                regularLayout(size: size)
            case .immersive:
                landscapeImmersiveLayout(size: size)
            }
            #else
            regularLayout(size: size)
            #endif
        }
    }

    private var hasLyricsColumn: Bool {
        if let lyrics = player.lyrics, !lyrics.isEmpty { return true }
        return player.lyrics == nil // still loading — keep layout stable
    }

    private func close() {
        #if os(iOS)
        if let dismissNowPlayingAction {
            dismissNowPlayingAction()
        } else {
            withAnimation(NowPlayingPresentationMetrics.presentationAnimation) {
                player.showNowPlaying = false
            }
        }
        #else
        player.showNowPlaying = false
        #endif
    }

    private func showsClassicChrome(isCompact: Bool) -> Bool {
        #if os(iOS)
        return !isCompact || settings.nowPlayingMode == .classic
        #else
        return true
        #endif
    }

    #if os(iOS)
    /// The "..." menu for the classic and regular layouts: the equalizer
    /// lives here (chen 2026-11-26), opening the same sound-effects sheet
    /// as the immersive/vinyl/minimal menus. Styled like the other chrome
    /// buttons (36pt circle; the landscape utility row passes 40 to match
    /// its circleButton/RoutePicker buttons). macOS has no in-player
    /// sheet — its EQ lives in Settings → 音效 — so this menu is iOS-only.
    private func soundEffectsMenu(diameter: CGFloat = 36) -> some View {
        Menu {
            Button {
                showSoundEffects = true
            } label: {
                Label("音效", systemImage: "waveform")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: diameter, height: diameter)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("playerMoreMenu")
    }
    #endif

    /// Collapse back to the browse UI. Shared by both platforms so the macOS
    /// layout can park it beside the window buttons (#128).
    private func collapseButton(diameter: CGFloat, glyphSize: CGFloat) -> some View {
        Button {
            close()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: diameter, height: diameter)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.pressable)
    }

    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    // MARK: - Backdrop

    private var artworkImage: PlatformImage? {
        #if os(macOS)
        artworkStore.artwork
        #else
        loadedArtwork.image(for: currentArtworkURL)
        #endif
    }

    private var colors: ArtworkColors {
        #if os(macOS)
        artworkStore.colors
        #else
        artworkImage == nil ? .fallback : loadedArtworkColors
        #endif
    }

    private var backdrop: some View {
        // No wallpaper here: chen 2026-11-26 — the player never shows the
        // wallpaper, only the pages do. (The wallpaper photo used to live in
        // this backdrop; its unframed resizable image inflated the layout
        // and pushed the bottom button row off-screen in the lyrics state.)
        ZStack {
            FluidColorField(colors: colors)
                .opacity(artworkGradientOpacity)
            RadialGradient(
                colors: [.white.opacity(0.12), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: colors)
    }

    /// The artwork gradient is always full-strength: the player never shows
    /// a wallpaper (chen 2026-11-26), so there is nothing to make room for.
    private var artworkGradientOpacity: Double {
        1
    }

    /// The cover colors as a slow-drifting field instead of a flat gradient:
    /// the dominant colors wash across the page and flow into each other when
    /// the track changes. Pure SwiftUI — blurred color orbs drifting on long,
    /// unsynchronised loops — the visible behaviour of a fluid backdrop,
    /// without a Metal renderer. Static when Reduce Motion is on.
    private struct FluidColorField: View {
        let colors: ArtworkColors

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var drift = false

        var body: some View {
            GeometryReader { geo in
                let span = min(geo.size.width, geo.size.height)
                ZStack {
                    // The flat wash underneath keeps the page tinted even
                    // while the orbs drift apart.
                    LinearGradient(
                        colors: [colors.primary, colors.secondary],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    orb(colors.primary, diameter: span * 1.05, opacity: 0.72,
                        base: CGPoint(x: geo.size.width * 0.22, y: geo.size.height * 0.20),
                        drift: CGVector(dx: 44, dy: -34), duration: 21)
                    orb(colors.secondary, diameter: span * 0.9, opacity: 0.66,
                        base: CGPoint(x: geo.size.width * 0.82, y: geo.size.height * 0.78),
                        drift: CGVector(dx: -52, dy: 38), duration: 27)
                    orb(.white, diameter: span * 0.6, opacity: 0.12,
                        base: CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.42),
                        drift: CGVector(dx: 30, dy: 26), duration: 17)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                drift = true
            }
        }

        private func orb(_ color: Color, diameter: CGFloat, opacity: Double,
                         base: CGPoint, drift driftVector: CGVector, duration: Double) -> some View {
            Circle()
                .fill(color.opacity(opacity))
                .frame(width: diameter, height: diameter)
                .blur(radius: 55)
                .position(base)
                .offset(x: drift ? driftVector.dx : -driftVector.dx,
                        y: drift ? driftVector.dy : -driftVector.dy)
                .animation(
                    .easeInOut(duration: duration).repeatForever(autoreverses: true),
                    value: drift
                )
        }
    }

    /// The cover's playing pulse: on play it swells ~5% on a quick ease-out,
    /// then settles back on a spring, while its shadow deepens; paused it
    /// rests flat. Honours Reduce Motion, and the spring uses the iOS 16
    /// form below iOS 17.
    private struct PlayingArtworkBounce: ViewModifier {
        let isPlaying: Bool
        let enabled: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var bounceScale: CGFloat = 1

        func body(content: Content) -> some View {
            content
                .scaleEffect(bounceScale)
                .task(id: isPlaying) {
                    guard enabled, isPlaying, !reduceMotion else {
                        bounceScale = 1
                        return
                    }
                    bounceScale = 1
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.17)) { bounceScale = 1.055 }
                    try? await Task.sleep(for: .milliseconds(170))
                    guard !Task.isCancelled else { return }
                    if #available(iOS 17, *) {
                        withAnimation(.spring(duration: 0.42, bounce: 0.24)) { bounceScale = 1 }
                    } else {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) { bounceScale = 1 }
                    }
                }
        }
    }

    #if os(iOS)
    private var currentArtworkURL: URL? {
        player.currentTrack?.album.picUrl?.resizedImageURL(768)
    }

    private func loadArtwork() async {
        loadedArtworkColors = .fallback
        guard let urlString = player.currentTrack?.album.picUrl,
              let url = currentArtworkURL else {
            loadedArtwork = CachedImageState()
            return
        }
        loadedArtwork = CachedImageState(url: url)
        let image = await ImageCache.shared.image(for: url) { preview in
            applyArtwork(preview, for: url, cacheKey: urlString)
        }
        if let image { applyArtwork(image, for: url, cacheKey: urlString) }
    }

    private func applyArtwork(_ image: PlatformImage, for url: URL, cacheKey: String) {
        guard !Task.isCancelled, currentArtworkURL == url else { return }
        loadedArtwork.finish(image, for: url)
        loadedArtworkColors = ArtworkPalette.extract(from: image, cacheKey: cacheKey)
    }
    #endif

    // MARK: - Layouts

    private func regularLayout(size: CGSize) -> some View {
        // Everything below the artwork needs ~300pt; shrink the artwork on
        // short displays (iPhone landscape) instead of clipping it.
        let artworkSize = max(120, min(340, size.width * 0.32, size.height - 300))
        // Cap the two-column band and centre it. Spreading each column to
        // `.infinity` across an ultra-wide display (iPad landscape, ~1368pt)
        // left the left column's content floating in an oversized half and a
        // wide blank gutter on the right (#62).
        let maxBandWidth: CGFloat = hasRegularRightColumn ? 1040 : 560
        return HStack(spacing: 0) {
            leftColumn(artworkSize: artworkSize)
                .frame(maxWidth: .infinity)
            if hasRegularRightColumn {
                regularRightColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: maxBandWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 48)
        .padding(.vertical, size.height < 500 ? 24 : 40)
    }

    #if os(iOS)
    /// Full-screen karaoke page for iPhone landscape / iPad. The scrubber is
    /// deliberately absent: the sung line and its wipe own the middle of the
    /// screen, the track sits at the bottom-left and the transport at the
    /// bottom-right, over a slowly drifting artwork backdrop.
    private func landscapeImmersiveLayout(size: CGSize) -> some View {
        ZStack {
            AnimatedKaraokeBackdrop(
                image: artworkImage, colors: colors,
                // A full-screen blur redrawn 24 times a second is not worth it
                // while nothing moves or the queue covers the lyrics.
                isPaused: !player.isPlaying || showQueueOnMobile
            )

            VStack(spacing: 0) {
                landscapeUtilityRow
                    .padding(.top, 18)
                    .padding(.trailing, 24)

                Group {
                    if showQueueOnMobile {
                        CompactQueueContent()
                            .transition(.opacity)
                    } else {
                        lyricsScroll(
                            topInset: max(12, size.height * 0.06),
                            bottomInset: max(20, size.height * 0.10),
                            horizontalPadding: 60,
                            karaoke: true
                        )
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: showQueueOnMobile)

                HStack(alignment: .center, spacing: 14) {
                    landscapeNowPlayingMetadata
                    Spacer(minLength: 12)
                    landscapeTransportRow
                }
                .padding(.horizontal, 28)
                .padding(.bottom, max(16, size.height * 0.03))
            }
        }
    }

    private var landscapeUtilityRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            circleButton(
                icon: "list.bullet", size: 15,
                tint: showQueueOnMobile ? Theme.accent : nil
            ) {
                withAnimation(AppAnimation.standard) {
                    showQueueOnMobile.toggle()
                }
            }
            .accessibilityLabel(showQueueOnMobile ? "关闭播放队列" : "显示播放队列")

            RoutePickerButton(diameter: 40, glyphSize: 16)

            // The EQ button used to sit in this row; the Coda copy moved
            // it into the "..." menu instead (chen 2026-11-26). 40pt to
            // match the row's other round buttons.
            soundEffectsMenu(diameter: 40)
        }
    }

    private var landscapeNowPlayingMetadata: some View {
        HStack(spacing: 12) {
            artworkView(size: 52, shadowRadius: 10, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                if let track = player.currentTrack {
                    NowPlayingTrackDestinationLinks(
                        track: track,
                        font: .system(size: 12),
                        color: .white.opacity(0.62),
                        onOpenDestination: onOpenDestination
                    )
                    .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var landscapeTransportRow: some View {
        HStack(spacing: 14) {
            circleButton(icon: "backward.fill", size: 18) {
                player.previous()
            }
            .accessibilityLabel("上一首")

            playPauseButton(diameter: 50, glyphSize: 20)

            circleButton(icon: "forward.fill", size: 18) {
                player.next()
            }
            .accessibilityLabel("下一首")

            if let track = player.currentTrack {
                let liked = account.isLiked(track.id)
                Button {
                    Task { await account.toggleLike(trackID: track.id) }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(liked ? Theme.accent : .white.opacity(0.85))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
            } else {
                // Keep the trailing slot so the transport never shifts.
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .accessibilityIdentifier("landscapeTransportRow")
    }

    /// A continuously moving backdrop for the karaoke page: the blurred cover
    /// drifts and breathes while two artwork-tinted glows slide across it.
    ///
    /// `TimelineView` drives the phase rather than a `repeatForever`
    /// animation on `@State`: the artwork image arrives asynchronously, and an
    /// image inserted after the animation started inherited its end value and
    /// stayed still — the reported "动态背景不动".
    private struct AnimatedKaraokeBackdrop: View {
        let image: PlatformImage?
        let colors: ArtworkColors
        var isPaused = false

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let cycle: TimeInterval = 18

        var body: some View {
            // Reduce Motion holds the backdrop at its rest pose instead of
            // redrawing a full-screen blur 24 times a second.
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || isPaused)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let sway = reduceMotion ? 0 : sin(t * 2 * .pi / Self.cycle)
                let breathe = reduceMotion ? 0 : cos(t * 2 * .pi / (Self.cycle * 0.78))

                GeometryReader { geo in
                    ZStack {
                        LinearGradient(
                            colors: [colors.primary, colors.secondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )

                        if let image {
                            Image(platformImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: geo.size.width * 1.5,
                                    height: geo.size.height * 1.5
                                )
                                .blur(radius: 70)
                                .drawingGroup()
                                .rotationEffect(.degrees(2.5 * sway))
                                .scaleEffect(1.02 + 0.08 * breathe)
                                .offset(
                                    x: geo.size.width * 0.06 * sway,
                                    y: geo.size.height * 0.05 * breathe
                                )
                                .opacity(0.62)
                        }

                        RadialGradient(
                            colors: [colors.primary.opacity(0.55), .clear],
                            center: .center, startRadius: 0,
                            endRadius: geo.size.width * 0.75
                        )
                        .frame(width: geo.size.width * 1.2, height: geo.size.width * 1.2)
                        .offset(
                            x: -geo.size.width * 0.28 + 60 * sway,
                            y: -geo.size.height * 0.22 + 40 * breathe
                        )
                        .blendMode(.plusLighter)
                        .drawingGroup()

                        RadialGradient(
                            colors: [colors.secondary.opacity(0.5), .clear],
                            center: .center, startRadius: 0,
                            endRadius: geo.size.width * 0.7
                        )
                        .frame(width: geo.size.width, height: geo.size.width)
                        .offset(
                            x: geo.size.width * 0.3 - 50 * breathe,
                            y: geo.size.height * 0.25 - 30 * sway
                        )
                        .blendMode(.plusLighter)
                        .drawingGroup()

                        LinearGradient(
                            colors: [.black.opacity(0.16), .black.opacity(0.5)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }
    #endif

    @ViewBuilder
    private func compactLayout(size: CGSize) -> some View {
        #if os(iOS)
        switch settings.nowPlayingMode {
        case .vinyl:
            vinylCompactLayout(size: size)
        case .classic:
            classicCompactLayout(size: size)
        case .immersive:
            immersiveCompactLayout(size: size)
        case .minimal:
            minimalCompactLayout(size: size)
        }
        #else
        switch settings.nowPlayingMode {
        case .vinyl:
            vinylCompactLayout(size: size)
        default:
            classicCompactLayout(size: size)
        }
        #endif
    }

    private func vinylCompactLayout(size: CGSize) -> some View {
        let discDimension = min(size.width - 64, size.height * 0.42, 320)
        let showsVinyl = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            #if os(iOS)
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(
                showsExpandedArtwork: showsVinyl,
                onOpenDestination: onOpenDestination,
                onOpenSoundEffects: { showSoundEffects = true }
            )
                .padding(.bottom, 10)
            #else
            Spacer().frame(height: 30)
            trackMetaView
                .padding(.bottom, 10)
            #endif

            ZStack {
                if showsVinyl {
                    VStack(spacing: 12) {
                        Spacer(minLength: 4)

                        VinylTurntableView(
                            artworkImage: artworkImage,
                            isPlaying: player.isPlaying,
                            trackId: player.currentTrack?.id,
                            size: discDimension,
                            onTap: {
                                withAnimation(AppAnimation.standard) {
                                    showLyricsOnMobile = true
                                }
                            },
                            onNextTrack: {
                                player.next()
                            },
                            onPreviousTrack: {
                                player.previous()
                            }
                        )
                        .accessibilityIdentifier("vinylTurntable")

                        MiniLyricsView(onOpen: {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = true
                            }
                        })
                        .frame(maxWidth: .infinity, maxHeight: 70)

                        Spacer(minLength: 0)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if showQueueOnMobile {
                    #if os(iOS)
                    CompactQueueContent()
                        .transition(.opacity)
                    #else
                    lyricsColumn
                        .transition(.opacity)
                    #endif
                } else {
                    #if os(iOS)
                    NowPlayingLyricsPager(isShown: true, horizontalInset: 32) {
                        IOSImmersiveLyricsColumn()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(AppAnimation.standard) {
                                    showLyricsOnMobile = false
                                }
                            }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 1.05)))
                    #else
                    lyricsColumn
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = false
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 1.05)))
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            #if os(iOS)
            immersiveControls
            #else
            VStack(spacing: 12) {
                NowPlayingScrubber()
                    .padding(.horizontal, 24)
                controls()
            }
            .padding(.bottom, 24)
            #endif
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
    }

    /// The lyrics page scales up from 90% as it fades in; a plain fade when
    /// Reduce Motion is on.
    private var lyricsEntranceTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity)
    }

    private func classicCompactLayout(size: CGSize) -> some View {
        let artworkDim = min(size.width - 64, size.height * 0.38, 300)
        return VStack(spacing: 20) {
            Spacer().frame(height: 44)
            if showLyricsOnMobile {
                #if os(iOS)
                NowPlayingLyricsPager(isShown: true, horizontalInset: 16) {
                    lyricsColumn
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(AppAnimation.standard) {
                        showLyricsOnMobile = false
                    }
                }
                .transition(.asymmetric(
                    insertion: lyricsEntranceTransition,
                    removal: .opacity
                ))
                #else
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                #endif
            } else {
                VStack(spacing: 20) {
                    artworkView(size: artworkDim) {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile = true
                        }
                    }
                    trackMetaView
                    MiniLyricsView {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile = true
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
                ))
            }
            VStack(spacing: 12) {
                NowPlayingScrubber()
                    .padding(.horizontal, 24)
                controls()
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
    }

    #if os(iOS)
    private func immersiveCompactLayout(size: CGSize) -> some View {
        // Coda-sized cover: as wide as the column allows, and as tall as
        // the space between the header and the controls allows. The
        // MiniLyrics strip (96) plus its spacing is reserved, so the cover
        // can never push the transport / utility row off-screen.
        let middleHeight = size.height
            - NowPlayingPresentationMetrics.immersiveHeaderTopInset
            - ImmersiveArtworkTransition.compactArtworkDimension
            - 14 // header bottom padding
            - 200 // scrubber + transport + utility row + paddings
        let artworkDimension = min(size.width - 64, middleHeight - 96 - 18 - 16, 340)
        let showsExpandedArtwork = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(
                showsExpandedArtwork: showsExpandedArtwork,
                onOpenDestination: onOpenDestination,
                onTapArtwork: collapseImmersiveArtwork,
                onOpenSoundEffects: { showSoundEffects = true }
            )
            .padding(.bottom, 14)

            ZStack {
                immersiveArtworkContent(artworkDimension: artworkDimension)
                    .opacity(showsExpandedArtwork ? 1 : 0)
                    .allowsHitTesting(showsExpandedArtwork)
                    .accessibilityHidden(!showsExpandedArtwork)

                if showQueueOnMobile {
                    CompactQueueContent()
                        .transition(.opacity)
                } else {
                    NowPlayingLyricsPager(isShown: showLyricsOnMobile, horizontalInset: 32) {
                        IOSImmersiveLyricsColumn()
                    }
                        .opacity(showLyricsOnMobile ? 1 : 0)
                        .scaleEffect(showLyricsOnMobile || reduceMotion ? 1 : 0.9)
                        .allowsHitTesting(showLyricsOnMobile)
                        .accessibilityHidden(!showLyricsOnMobile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            immersiveControls
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
        .overlayPreferenceValue(ImmersiveArtworkFramePreferenceKey.self) { frames in
            GeometryReader { proxy in
                if let compactAnchor = frames[.compact],
                   let expandedAnchor = frames[.expanded] {
                    let compactFrame = proxy[compactAnchor]
                    let expandedFrame = proxy[expandedAnchor]
                    let targetFrame = showsExpandedArtwork ? expandedFrame : compactFrame
                    let targetCenterX = showsExpandedArtwork
                        ? size.width / 2
                        : compactFrame.midX

                    immersiveArtworkSurface(isExpanded: showsExpandedArtwork)
                        .frame(width: targetFrame.width, height: targetFrame.height)
                        .position(x: targetCenterX, y: targetFrame.midY)
                        .accessibilityIdentifier("immersiveArtwork")
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The volume panel, above the button that opened it, over a clear
    /// catcher that covers the page: a tap anywhere else only closes it.
    @ViewBuilder
    private func volumeLayer(buttonAnchor: Anchor<CGRect>?) -> some View {
        if let buttonAnchor {
            GeometryReader { proxy in
                let button = proxy[buttonAnchor]
                ZStack(alignment: .topLeading) {
                    if showsVolumeControl {
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture(perform: closeVolumeControl)
                            .accessibilityHidden(true)
                    }

                    Color.clear
                        .frame(width: button.width, height: button.height)
                        .overlay(alignment: .bottom) {
                            if showsVolumeControl {
                                CompactVolumePopover()
                                    .offset(y: -button.height)
                                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                            }
                        }
                        .position(x: button.midX, y: button.midY)
                }
            }
        }
    }

    private func closeVolumeControl() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            showsVolumeControl = false
        }
    }

    private var immersiveControls: some View {
        VStack(spacing: 17) {
            NowPlayingScrubber()
            CompactTransportControls()
            CompactSecondaryControls(
                showsVolumeControl: $showsVolumeControl,
                showsLyrics: showLyricsOnMobile,
                showsQueue: showQueueOnMobile,
                onToggleLyrics: toggleImmersiveLyrics,
                onToggleQueue: toggleImmersiveQueue
            )
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("immersiveControls")
    }

    private func immersiveArtworkContent(artworkDimension: CGFloat) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Color.clear
                .frame(width: artworkDimension, height: artworkDimension)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapImmersiveArtwork)
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.expanded: $0] }
            MiniLyricsView(onOpen: showImmersiveLyrics)
                .frame(maxWidth: .infinity, maxHeight: 96)
            Spacer(minLength: 0)
        }
    }

    private func immersiveArtworkSurface(isExpanded: Bool) -> some View {
        Group {
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(isExpanded ? 0.06 : 0.1))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: isExpanded ? 48 : 18, weight: .light))
                            .foregroundStyle(.white.opacity(isExpanded ? 0.3 : 0.45))
                    }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isExpanded ? 18 : 12,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(isExpanded ? (player.isPlaying ? 0.5 : 0.45) : 0.22),
            radius: isExpanded ? (player.isPlaying ? 40 : 36) : 10,
            y: isExpanded ? (player.isPlaying ? 20 : 18) : 4
        )
        // Coda's paused artwork: the expanded cover rests at 74% while
        // paused and grows to full size on play, so playing vs paused is
        // unmistakable. The header (collapsed) cover never shrinks.
        .scaleEffect(isExpanded && !player.isPlaying ? 0.74 : 1)
        .animation(reduceMotion ? nil : AppAnimation.standard, value: player.isPlaying)
        .modifier(PlayingArtworkBounce(isPlaying: player.isPlaying, enabled: isExpanded))
    }

    private func toggleImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            if showQueueOnMobile {
                showQueueOnMobile = false
                showLyricsOnMobile = true
            } else {
                showLyricsOnMobile.toggle()
            }
        }
    }

    private func showImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile = false
            showLyricsOnMobile = true
        }
    }

    /// Tapping the top-left cover while lyrics/queue are up returns to the
    /// expanded artwork — the Apple Music gesture requested in #50. Idempotent,
    /// so a tap while already expanded is a harmless no-op.
    private func collapseImmersiveArtwork() {
        guard showLyricsOnMobile || showQueueOnMobile else { return }
        withAnimation(ImmersiveArtworkTransition.animation) {
            showLyricsOnMobile = false
            showQueueOnMobile = false
        }
    }

    /// Tapping the expanded cover: with "点封面打开专辑" on it opens the
    /// album (as Coda's artwork link does); otherwise it flips to the full
    /// lyrics page. Lyrics and MiniLyrics stay reachable from the utility
    /// row either way.
    private func onTapImmersiveArtwork() {
        if settings.openAlbumOnArtworkClick,
           let album = player.currentTrack?.album, album.id > 0, !album.name.isEmpty {
            onOpenDestination(.album(album.id))
        } else {
            showImmersiveLyrics()
        }
    }

    private func toggleImmersiveQueue() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile.toggle()
        }
    }

    private func minimalCompactLayout(size: CGSize) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkDimension = min(contentWidth, size.height * 0.52, 378)

        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.clear
                MinimalTrackInfoRow(
                    onOpenDestination: onOpenDestination,
                    onOpenSoundEffects: { showSoundEffects = true },
                    metadataOnly: true
                )
                    .padding(.top, NowPlayingPresentationMetrics.immersiveHeaderTopInset)
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 90)

            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)

                artworkView(size: artworkDimension)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)
                    .accessibilityIdentifier("immersiveArtwork")
                    .accessibilityLabel("显示歌词")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleMinimalLyrics() }
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)

                NowPlayingLyricsPager(isShown: showLyricsOnMobile, horizontalInset: 32) {
                    IOSMinimalLyricsColumn {
                        showLyricsOnMobile = false
                    }
                }
                .opacity(showLyricsOnMobile ? 1 : 0)
                .allowsHitTesting(showLyricsOnMobile)
                .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(
                minimalDismissGesture,
                including: showLyricsOnMobile ? .none : .all
            )
            .padding(.bottom, 20)

            minimalControls
        }
        .frame(width: contentWidth)
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
        .animation(.easeInOut(duration: 0.22), value: showLyricsOnMobile)
    }

    private var minimalControls: some View {
        VStack(spacing: 22) {
            ZStack {
                MinimalTrackInfoRow(
                    onOpenDestination: onOpenDestination,
                    onOpenSoundEffects: { showSoundEffects = true }
                )
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)
                    .accessibilityHidden(showLyricsOnMobile)
                MinimalTrackInfoRow(
                    onOpenDestination: onOpenDestination,
                    onOpenSoundEffects: { showSoundEffects = true },
                    actionsOnly: true
                )
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .allowsHitTesting(showLyricsOnMobile)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 44)
            NowPlayingScrubber()
                .padding(.horizontal, 2)
                .padding(.top, 16)
            MinimalTransportControls(
                backdrop: colors,
                showQueue: $showQueueOnMobile,
                onOpenDestination: onOpenDestination
            )
                .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("immersiveControls")
    }

    private func toggleMinimalLyrics() {
        guard showLyricsOnMobile || player.lyrics?.isEmpty == false else { return }
        showLyricsOnMobile.toggle()
    }

    private var minimalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onChanged(isDownward ? translation.height : 0)
            }
            .onEnded { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onEnded(
                    isDownward ? translation.height : 0,
                    isDownward ? value.predictedEndTranslation.height : 0
                )
            }
    }
    #endif

    // MARK: - Views

    private func artworkView(
        size: CGFloat,
        shadowRadius: CGFloat = 36,
        cornerRadius: CGFloat = 18,
        onTapArtwork: (() -> Void)? = nil
    ) -> some View {
        Group {
            if settings.openAlbumOnArtworkClick,
               let album = player.currentTrack?.album, album.id > 0, !album.name.isEmpty {
                Button {
                    onOpenDestination(.album(album.id))
                } label: {
                    artworkSurface(size: size, shadowRadius: shadowRadius, cornerRadius: cornerRadius)
                }
                .buttonStyle(.plain)
                .noFocusRing()
                .accessibilityLabel("打开专辑：\(album.name)")
            } else if let onTapArtwork {
                artworkSurface(size: size, shadowRadius: shadowRadius, cornerRadius: cornerRadius)
                    .onTapGesture(perform: onTapArtwork)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("显示歌词")
            } else {
                artworkSurface(size: size, shadowRadius: shadowRadius, cornerRadius: cornerRadius)
            }
        }
    }

    private func artworkSurface(
        size: CGFloat,
        shadowRadius: CGFloat = 36,
        cornerRadius: CGFloat = 18
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.06))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                )
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.3),
                radius: player.isPlaying ? shadowRadius : shadowRadius * 0.6,
                y: (player.isPlaying ? shadowRadius : shadowRadius * 0.6) * 0.5)
        .animation(.easeIn(duration: 0.25), value: artworkImage != nil)
        .scaleEffect(player.isPlaying ? 1 : 0.95)
        .animation(reduceMotion ? nil : AppAnimation.bouncy, value: player.isPlaying)
        .modifier(PlayingArtworkBounce(isPlaying: player.isPlaying, enabled: size >= 120))
    }

    private var trackMetaView: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(player.currentTrack?.name ?? "")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            if let track = player.currentTrack {
                NowPlayingTrackDestinationLinks(
                    track: track,
                    font: .system(size: 13.5),
                    color: .white.opacity(0.65),
                    onOpenDestination: onOpenDestination
                )
            }
        }
        .frame(maxWidth: 400)
    }

    private func leftColumn(artworkSize: CGFloat) -> some View {
        VStack(spacing: 26) {
            Spacer()

            if settings.nowPlayingMode == .vinyl {
                VinylTurntableView(
                    artworkImage: artworkImage,
                    isPlaying: player.isPlaying,
                    trackId: player.currentTrack?.id,
                    size: artworkSize,
                    onTap: {
                        player.togglePlayPause()
                    },
                    onNextTrack: {
                        player.next()
                    },
                    onPreviousTrack: {
                        player.previous()
                    }
                )
            } else {
                artworkView(size: artworkSize)
            }
            trackMetaView

            VStack(spacing: 14) {
                NowPlayingScrubber()
                    .frame(maxWidth: 380)
                controls()
            }

            Spacer()
        }
        .padding(.trailing, hasLyricsColumn ? 30 : 0)
    }

    private func controls() -> some View {
        // Equal-width slots so the row always fits the screen: fixed-size
        // buttons in a plain HStack summed wider than a phone (≈430pt with the
        // like button), overflowing the layout and shoving the overlays and
        // metadata off the right edge. `maxWidth: .infinity` per control makes
        // the row scale to any width instead.
        HStack(spacing: 0) {
            // The like slot stays even when the track is briefly unavailable:
            // adding or removing it re-divides the equal-width row, which made
            // every other control jump sideways during a track change.
            Group {
                if let track = player.currentTrack {
                    let liked = account.isLiked(track.id)
                    circleButton(
                        icon: liked ? "heart.fill" : "heart",
                        size: 15, tint: liked ? Theme.accent : nil
                    ) {
                        Task { await account.toggleLike(trackID: track.id) }
                    }
                    .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }
            .frame(maxWidth: .infinity)

            if player.isFMMode {
                circleButton(icon: "trash", size: 14) {
                    player.fmTrash()
                }
                .accessibilityLabel("不喜欢")
                .frame(maxWidth: .infinity)
            } else {
                // All three queue orders on the one button; the cycle skips
                // AutoMix wherever it could do nothing (AutoMix off, order
                // off), so this row keeps its present width and its two-state
                // behaviour there — as it does on iOS, which has no AutoMix at
                // all. Only the three values below differ per platform.
                circleButton(
                    icon: queueOrderIcon, size: 14,
                    tint: queueOrderIsActive ? Theme.accent : nil,
                    action: cycleQueueOrder
                )
                #if os(macOS)
                .accessibilityLabel(player.queueOrder.controlHelp)
                #else
                .accessibilityLabel("随机播放")
                .accessibilityAddTraits(player.shuffleEnabled ? .isSelected : [])
                #endif
                .frame(maxWidth: .infinity)
                circleButton(icon: "backward.fill", size: 16) {
                    player.previous()
                }
                .accessibilityLabel("上一首")
                .frame(maxWidth: .infinity)
            }

            playPauseButton()
                .frame(maxWidth: .infinity)

            circleButton(icon: "forward.fill", size: 16) {
                player.next()
            }
            .accessibilityLabel("下一首")
            .frame(maxWidth: .infinity)

            RoutePickerButton(diameter: 40, glyphSize: 15)
                .frame(maxWidth: .infinity)

            if player.isFMMode {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 40, height: 40)
                    .frame(maxWidth: .infinity)
            } else {
                circleButton(
                    icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 14,
                    tint: player.repeatMode != .off ? Theme.accent : nil
                ) {
                    player.cycleRepeatMode()
                }
                .accessibilityLabel("循环播放")
                .accessibilityValue(repeatModeAccessibilityValue)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("nowPlayingTransport")
    }

    private func playPauseButton(diameter: CGFloat = 58, glyphSize: CGFloat = 21) -> some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: diameter, height: diameter)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
    }

    // MARK: - Queue-order control

    /// The queue-order button's three platform-dependent values. macOS cycles
    /// `listed → shuffled → autoMix`; iOS has no AutoMix and toggles shuffle.

    private var queueOrderIcon: String {
        #if os(macOS)
        player.queueOrder.symbolName
        #else
        "shuffle"
        #endif
    }

    /// Spoken state of the repeat button, which cycles three modes.
    private var repeatModeAccessibilityValue: Text {
        switch player.repeatMode {
        case .off: return Text("不循环")
        case .all: return Text("列表循环")
        case .one: return Text("单曲循环")
        }
    }

    private var queueOrderIsActive: Bool {
        #if os(macOS)
        player.queueOrder != .listed
        #else
        player.shuffleEnabled
        #endif
    }

    private func cycleQueueOrder() {
        #if os(macOS)
        player.cycleQueueOrder()
        #else
        player.toggleShuffle()
        #endif
    }

    private func circleButton(icon: String, size: CGFloat,
                              tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Lyrics column

    @ViewBuilder
    private var lyricsColumn: some View {
        lyricsScroll(topInset: 200, bottomInset: 240, horizontalPadding: 24)
    }

    // MARK: - Regular right column

    /// The song's comments sit beside its lyrics, one switch away, so a song
    /// without lyrics still has a right column when it has comments.
    private var hasRegularRightColumn: Bool {
        hasLyricsColumn || commentsTrack != nil
    }

    private var commentsTrack: Track? {
        guard let track = player.currentTrack,
              SongCommentsMenuButton.isAvailable(for: track) else { return nil }
        return track
    }

    private var regularRightColumn: some View {
        ZStack(alignment: .top) {
            Group {
                if regularColumnPage == .comments, let track = commentsTrack {
                    RegularCommentsPanel(track: track)
                        .id(track.id)
                        .padding(.top, 52)
                        .transition(.opacity)
                } else if hasLyricsColumn {
                    lyricsColumn
                        .transition(.opacity)
                } else {
                    Text("暂无歌词")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if commentsTrack != nil {
                RegularColumnSwitch(selection: $regularColumnPage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: regularColumnPage)
    }

    /// The scrolling lyric list shared by the regular page and the
    /// landscape immersive page. Insets are the space parked above and below
    /// the lines so the active one can sit mid-viewport; the short landscape
    /// page needs them much smaller than a full-height window does.
    @ViewBuilder
    private func lyricsScroll(
        topInset: CGFloat,
        bottomInset: CGFloat,
        horizontalPadding: CGFloat,
        karaoke: Bool = false
    ) -> some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: karaoke ? .center : .leading,
                               spacing: karaoke ? 20 : 26) {
                        Color.clear.frame(height: topInset)
                        ForEach(lyrics.lines) { line in
                            Group {
                                if karaoke {
                                    landscapeKaraokeLine(line, isActive: line.id == activeIndex)
                                } else {
                                    bigLyricLine(line, isActive: line.id == activeIndex)
                                }
                            }
                            .id(line.id)
                        }
                        Color.clear.frame(height: bottomInset)
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                // Inside the per-track identity so a mid-flick track change
                // tears the tracking down with the list and clears the flag.
                .lyricsScrollTracking(isUserScrolling: $isUserScrolling)
                // A new track gets a fresh list: reusing the old scroll view
                // crossfaded the outgoing and incoming lines on top of each
                // other for one frame while `lyrics` reloaded.
                .id(player.currentTrack?.id)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.12),
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .onChange(of: lyricsCursor.activeIndex) { index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard !isUserScrolling, let index else { return }
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onAppear {
                    // The cursor only fires on a line change, which can be many
                    // seconds away — on re-entering the page, adopt where the
                    // song already is instead of waiting for the next line.
                    adoptCursor(proxy: proxy)
                }
                .onChange(of: player.currentTrack?.id) { _ in
                    activeIndex = nil
                    isUserScrolling = false
                }
            }
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bigLyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
                LyricMainText(
                    line: line, isActive: isActive,
                    size: isActive ? 26 : 20, weight: isActive ? .bold : .semibold,
                    verbatim: settings.verbatimLyrics
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 16 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .blur(radius: isActive || isUserScrolling ? 0 : 0.6)
            .scaleEffect(isActive ? 1.02 : 1, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
        .animation(.easeOut(duration: 0.25), value: isUserScrolling)
    }

    /// Centre-aligned karaoke line for the landscape page. The active line is
    /// large and carries the verbatim wipe like a KTV subtitle; the neighbours
    /// stay smaller and dimmer so the eye follows the sung line.
    private func landscapeKaraokeLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(spacing: 7) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 16 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.3))
                }
                LyricMainText(
                    line: line, isActive: isActive,
                    size: isActive ? 32 : 21,
                    weight: isActive ? .bold : .medium,
                    verbatim: settings.verbatimLyrics,
                    alignment: .center
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 17 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.72 : 0.3))
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .opacity(isActive ? 1 : 0.6)
            .scaleEffect(isActive ? 1 : 0.97)
            .blur(radius: isActive || isUserScrolling ? 0 : 0.4)
            .shadow(color: .black.opacity(isActive ? 0.45 : 0),
                    radius: isActive ? 18 : 0, y: isActive ? 6 : 0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isActive)
        .animation(.easeOut(duration: 0.25), value: isUserScrolling)
    }
}


/// The main lyric line. Renders karaoke-style per-character highlighting from
/// verbatim (`yrc`) timings, driven live by the player, when the line is active
/// and verbatim data exists; otherwise a plain line.
///
/// Whether the line carries furigana is `LyricText`'s decision; the wipe is
/// handed down as per-character opacity so it reads the same either way.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let size: CGFloat
    let weight: Font.Weight
    let verbatim: Bool
    var inactiveOpacity: Double = 0.45
    var alignment: NSTextAlignment = .left

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared

    var body: some View {
        if isActive, verbatim, let words = line.words, !words.isEmpty {
            #if os(macOS)
            // The wipe runs on a display link inside the host: a per-frame
            // SwiftUI value here re-measured the page's whole layout while a
            // verbatim line was up (see KaraokeLyricLine).
            KaraokeLyricLine(
                line: line,
                words: words,
                size: size,
                weight: weight,
                alignment: alignment,
                playing: player.isPlaying && windowVisibility.isVisible
            )
            #else
            TimelineView(.animation(
                minimumInterval: 1 / 30,
                paused: !player.isPlaying || !windowVisibility.isVisible
            )) { _ in
                LyricText(
                    line: line, size: size, weight: weight, color: .white,
                    alignment: alignment,
                    alphas: Self.alphas(for: line, words: words, at: player.livePlaybackTime)
                )
            }
            #endif
        } else {
            LyricText(
                line: line, size: size, weight: weight,
                color: .white.opacity(isActive ? 1 : inactiveOpacity),
                alignment: alignment
            )
        }
    }

    /// One opacity per character of `line.text`: sung characters are bright,
    /// the current one fades in, unsung stay dim. A word's time is shared by
    /// its letters; punctuation and spaces take none and light up with the
    /// character before them (or the first one, when they open the line).
    static func alphas(for line: LyricLine, words: [LyricWord], at time: TimeInterval) -> [Double] {
        let unsung = 0.28
        var out: [Double] = []
        for word in words {
            let chars = Array(word.text)
            guard !chars.isEmpty else { continue }
            let letters = chars.indices.filter { chars[$0].isLetter || chars[$0].isNumber }
            let slots = letters.isEmpty ? Array(chars.indices) : letters
            // A token the service timed at nothing still ramps, over 50 ms.
            let per = max(word.duration, 0.05) / Double(slots.count)
            var lit: [Int: Double] = [:]
            for (slot, index) in slots.enumerated() {
                let frac = min(max((time - (word.start + per * Double(slot))) / per, 0), 1)
                lit[index] = unsung + (1 - unsung) * frac
            }
            let opening = lit[slots[0]] ?? unsung
            for index in chars.indices {
                out.append(lit[index] ?? out.last ?? opening)
            }
        }
        // The words' text joined is the line's text; should they ever differ,
        // keep one opacity per character of the line.
        let joined = words.map(\.text).joined()
        guard joined.count != line.text.count else { return out }
        let leading = joined.count - joined.drop(while: \.isWhitespace).count
        return Array(out.dropFirst(leading).prefix(line.text.count))
    }
}

#if os(iOS)
private struct IOSImmersiveLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    @State private var activeIndex: Int?
    @State private var isUserScrolling = false

    var body: some View {
        Group {
            if let lyrics = player.lyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            Color.clear.frame(height: 72)
                            ForEach(lyrics.lines) { line in
                                lyricLine(
                                    line,
                                    isActive: line.id == activeIndex
                                )
                                .id(line.id)
                            }
                            Color.clear.frame(height: 96)
                        }
                        .padding(.horizontal, 4)
                    }
                    .mask(edgeMask)
                    .accessibilityIdentifier("syncedLyricsScroll")
                    .onChange(of: lyricsCursor.activeIndex) { index in
                        guard index != activeIndex else { return }
                        activeIndex = index
                        guard !isUserScrolling, let index else { return }
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .onAppear {
                        adoptCursor(proxy: proxy)
                    }
                    .onChange(of: player.currentTrack?.id) { _ in
                        activeIndex = nil
                    }
                    .lyricsScrollTracking(isUserScrolling: $isUserScrolling) {
                        guard let activeIndex else { return }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            proxy.scrollTo(activeIndex, anchor: .center)
                        }
                    }
                }
            } else if player.lyrics?.isInstrumental == true {
                VStack(spacing: 10) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("纯音乐，请欣赏")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.75 : 0.4))
                }

                LyricMainText(
                    line: line,
                    isActive: isActive,
                    size: isActive ? 26 : 21,
                    weight: isActive ? .bold : .semibold,
                    verbatim: settings.verbatimLyrics
                )

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 16 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.75 : 0.4))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .blur(radius: isActive || isUserScrolling ? 0 : 0.4)
            .scaleEffect(isActive ? 1.02 : 1.0, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isActive)
        .animation(.easeOut(duration: 0.25), value: isUserScrolling)
    }
}

// MARK: - Compact now-playing sections

private enum ImmersiveArtworkTransition {
    /// A time-based ease-out curve stays fluid at the display's native refresh rate.
    static let animation = Animation.timingCurve(
        0.16,
        1,
        0.3,
        1,
        duration: 0.42
    )
    static let compactArtworkDimension: CGFloat = 72
    static let compactHeaderSpacing: CGFloat = 13
    static let expandedMetadataOffset = -(
        compactArtworkDimension + compactHeaderSpacing
    )
}

private enum ImmersiveArtworkFrame: Hashable {
    case compact
    case expanded
}

private struct ImmersiveArtworkFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ImmersiveArtworkFrame: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ImmersiveArtworkFrame: Anchor<CGRect>],
        nextValue: () -> [ImmersiveArtworkFrame: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct CompactTrackHeader: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @State private var showAddToPlaylist = false
    @State private var commentsTrack: Track?

    let showsExpandedArtwork: Bool
    let onOpenDestination: (Destination) -> Void
    /// Tap handler for the compact cover (used to collapse lyrics back to
    /// artwork). The real image floats above this placeholder with hit-testing
    /// disabled, so taps land here.
    var onTapArtwork: (() -> Void)? = nil
    /// Opens the sound-effects sheet (equalizer). The button used to sit in
    /// the player chrome; Coda keeps it in the "..." menu instead.
    let onOpenSoundEffects: () -> Void

    var body: some View {
        HStack(spacing: ImmersiveArtworkTransition.compactHeaderSpacing) {
            Color.clear
                .frame(
                    width: ImmersiveArtworkTransition.compactArtworkDimension,
                    height: ImmersiveArtworkTransition.compactArtworkDimension
                )
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.compact: $0] }
                .contentShape(Rectangle())
                .onTapGesture { onTapArtwork?() }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                if let track = player.currentTrack {
                    NowPlayingTrackDestinationLinks(
                        track: track,
                        font: .subheadline,
                        color: .white.opacity(0.62),
                        onOpenDestination: onOpenDestination
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(
                x: showsExpandedArtwork
                    ? ImmersiveArtworkTransition.expandedMetadataOffset
                    : 0
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("immersiveTrackMetadata")

            if let track = player.currentTrack {
                let liked = account.isLiked(track.id)
                HStack(spacing: 0) {
                    Button {
                        Task { await account.toggleLike(trackID: track.id) }
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(liked ? "取消收藏" : "收藏")
                    .accessibilityIdentifier("immersiveFavoriteButton")

                    Menu {
                        TrackDownloadActions(track: track, showsIcons: true)
                        TrackBlacklistMenu(track: track, showsIcons: true)
                        SongCommentsMenuButton(track: track, showsIcons: true) {
                            commentsTrack = track
                        }
                        Divider()
                        Button {
                            player.addToPlayNext(track)
                        } label: {
                            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }

                        Button {
                            showAddToPlaylist = true
                        } label: {
                            Label("加入歌单…", systemImage: "music.note.list")
                        }

                        Divider()

                        #if os(iOS)
                        SleepTimerMenu(player: player)

                        Divider()
                        #endif

                        Button {
                            onOpenSoundEffects()
                        } label: {
                            Label("音效", systemImage: "waveform")
                        }

                        Divider()

                        Button {
                            Platform.copyToPasteboard(
                                string: Upstream.songPageURL(id: track.id)?.absoluteString ?? ""
                            )
                            ToastCenter.shared.show(String(localized: "链接已复制"))
                        } label: {
                            Label("复制链接", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("immersiveMoreMenu")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
        .sheet(item: $commentsTrack) { track in
            SongCommentsView(track: track)
        }
    }
}

private struct CompactTransportControls: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        HStack(spacing: 0) {
            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
    }
}

#if os(iOS)
private struct CompactVolumePopover: View {
    @EnvironmentObject private var player: PlayerService
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 16, weight: .medium))

            GeometryReader { geo in
                let height = geo.size.height
                let fraction = min(max(CGFloat(player.volume), 0), 1)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.82))
                        .frame(height: height * fraction)
                }
                .frame(width: isDragging ? 12 : 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            updateVolume(at: value.location.y, height: height)
                        }
                        .onEnded { value in
                            updateVolume(at: value.location.y, height: height)
                            isDragging = false
                        }
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
            }
            .frame(width: 32, height: 132)
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            .accessibilityAdjustableAction(adjustVolume)

            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottom) {
            Triangle()
                .fill(.white.opacity(0.18))
                .frame(width: 16, height: 8)
                .offset(y: 8)
        }
    }

    private func updateVolume(at location: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        player.volume = Float(min(max(1 - location / height, 0), 1))
    }

    private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float = 0.05
        switch direction {
        case .increment:
            player.volume = min(player.volume + step, 1)
        case .decrement:
            player.volume = max(player.volume - step, 0)
        @unknown default:
            break
        }
    }
}

private struct CompactVolumeButtonAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private struct CompactSecondaryControls: View {
    @EnvironmentObject private var player: PlayerService
    @Binding var showsVolumeControl: Bool
    let showsLyrics: Bool
    let showsQueue: Bool
    let onToggleLyrics: () -> Void
    let onToggleQueue: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            secondaryButton(
                icon: showsLyrics && !showsQueue ? "quote.bubble.fill" : "quote.bubble",
                label: showsLyrics ? "显示封面" : "显示歌词",
                isActive: showsLyrics && !showsQueue
            ) { onToggleLyrics() }

            RoutePickerButton(diameter: 44, glyphSize: 17)
                .frame(maxWidth: .infinity)

            secondaryButton(
                icon: volumeIcon,
                label: showsVolumeControl ? "关闭音量控制" : "显示音量控制",
                isActive: showsVolumeControl
            ) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showsVolumeControl.toggle()
                }
            }
            // The panel itself is drawn by the page (`volumeLayer`), above
            // everything else, from this button's frame.
            .anchorPreference(key: CompactVolumeButtonAnchorKey.self, value: .bounds) { $0 }

            secondaryButton(
                icon: "list.bullet",
                label: showsQueue ? "关闭播放队列" : "显示播放队列",
                isActive: showsQueue
            ) { onToggleQueue() }
        }
    }

    private var volumeIcon: String {
        let volume = player.volume
        if volume == 0 { return "speaker.slash" }
        if volume < 0.5 { return "speaker.wave.1" }
        return "speaker.wave.2"
    }

    private func secondaryButton(
        icon: String,
        label: LocalizedStringKey,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : .white.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}
#endif

private struct CompactQueueContent: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                modeButton(
                    icon: "arrow.right",
                    label: "顺序播放",
                    isActive: !player.shuffleEnabled && player.repeatMode == .off,
                    action: enableSequentialPlayback
                )
                modeButton(
                    icon: "shuffle",
                    label: player.shuffleEnabled ? "关闭随机播放" : "随机播放",
                    isActive: player.shuffleEnabled,
                    action: player.toggleShuffle
                )
                modeButton(
                    icon: "repeat",
                    label: "列表循环",
                    isActive: player.repeatMode == .all
                ) {
                    player.repeatMode = player.repeatMode == .all ? .off : .all
                }
                modeButton(
                    icon: "repeat.1",
                    label: "单曲循环",
                    isActive: player.repeatMode == .one
                ) {
                    player.repeatMode = player.repeatMode == .one ? .off : .one
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("继续播放")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(player.upcomingTracks.count) 首")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.46))
            }

            if player.upcomingTracks.isEmpty {
                VStack(spacing: 8) {
                    PlaybackHandoffList()
                    Image(systemName: "list.bullet")
                        .font(.system(size: 28, weight: .light))
                    Text("播放队列是空的")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        PlaybackHandoffList()
                            .padding(.bottom, 4)
                        ForEach(
                            Array(player.upcomingTracks.prefix(100).enumerated()),
                            id: \.offset
                        ) { index, track in
                            CompactQueueRow(track: track, upcomingIndex: index)
                        }
                    }
                }
                .mask(
                    LinearGradient(
                        colors: [.black, .black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .padding(.top, 6)
    }

    private func modeButton(
        icon: String,
        label: LocalizedStringKey,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.black.opacity(0.76) : .white.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    isActive ? AnyShapeStyle(.white.opacity(0.66)) : AnyShapeStyle(.white.opacity(0.1)),
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func enableSequentialPlayback() {
        if player.shuffleEnabled {
            player.toggleShuffle()
        }
        player.repeatMode = .off
    }
}

private struct CompactQueueRow: View {
    let track: Track
    let upcomingIndex: Int

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            player.jumpToUpcoming(at: upcomingIndex, matching: track.id)
        } label: {
            HStack(spacing: 11) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(120), animated: false)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(Formatters.duration(track.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.name)，\(track.artistNames)")
    }
}



private struct IOSMinimalLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @EnvironmentObject private var settings: SettingsManager

    let onClose: () -> Void

    @State private var activeIndex: Int?
    @State private var selectedIndex: Int?
    @State private var nearestIndex: Int?
    @State private var lineCenters: [Int: CGFloat] = [:]
    @State private var isDragging = false
    @State private var suppressesAutoScroll = false
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var selectionTimeoutTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let lyrics = player.lyrics, !lyrics.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                Color.clear.frame(height: geometry.size.height / 2)
                                ForEach(lyrics.lines) { line in
                                    lyricLine(
                                        line,
                                        isActive: line.id == activeIndex,
                                        isSelected: line.id == selectedIndex,
                                        availableWidth: geometry.size.width
                                    ) {
                                        guard let selectedIndex else {
                                            closeLyrics()
                                            return
                                        }
                                        guard selectedIndex == line.id else {
                                            returnToActiveLine(proxy: proxy)
                                            return
                                        }
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        suppressesAutoScroll = true
                                        player.seek(to: line.time) {
                                            suppressesAutoScroll = false
                                        }
                                        activeIndex = line.id
                                        self.selectedIndex = nil
                                        nearestIndex = nil
                                    }
                                    .id(line.id)
                                    .background {
                                        GeometryReader { lineGeometry in
                                            Color.clear.preference(
                                                key: MinimalLyricCentersKey.self,
                                                value: [
                                                    line.id: lineGeometry.frame(
                                                        in: .named("immersiveLyrics")
                                                    ).midY
                                                ]
                                            )
                                        }
                                    }
                                }
                                Color.clear.frame(height: geometry.size.height / 2)
                            }
                            .padding(.horizontal, 2)
                        }
                        .coordinateSpace(name: "immersiveLyrics")
                        .mask(edgeMask)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeLyrics)
                        .accessibilityIdentifier("syncedLyricsScroll")
                        .onPreferenceChange(MinimalLyricCentersKey.self) { centers in
                            lineCenters = centers
                            guard isDragging || scrollSettleTask != nil else { return }
                            nearestIndex = nearestLine(
                                to: geometry.size.height / 2,
                                in: centers
                            )
                            guard !isDragging else { return }
                            scheduleScrollSelection(
                                guideY: geometry.size.height / 2,
                                proxy: proxy
                            )
                        }
                        .onAppear {
                            activeIndex = lyrics.activeIndex(at: clock.progress + 0.2)
                            if let activeIndex {
                                Task { @MainActor in
                                    await Task.yield()
                                    proxy.scrollTo(activeIndex, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: clock.progress) { _ in
                            let index = lyrics.activeIndex(at: clock.progress + 0.2)
                            guard index != activeIndex else { return }
                            activeIndex = index
                            guard !suppressesAutoScroll,
                                  !isDragging, scrollSettleTask == nil,
                                  selectedIndex == nil, let index else { return }
                            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                        .onChange(of: player.currentTrack?.id) { _ in
                            activeIndex = nil
                            selectedIndex = nil
                            nearestIndex = nil
                            suppressesAutoScroll = false
                            scrollSettleTask?.cancel()
                            scrollSettleTask = nil
                            selectionTimeoutTask?.cancel()
                            selectionTimeoutTask = nil
                        }
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { _ in
                                    if !isDragging {
                                        scrollSettleTask?.cancel()
                                        scrollSettleTask = nil
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        selectedIndex = nil
                                        isDragging = true
                                    }
                                    nearestIndex = nearestLine(
                                        to: geometry.size.height / 2,
                                        in: lineCenters
                                    )
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    scheduleScrollSelection(
                                        guideY: geometry.size.height / 2,
                                        proxy: proxy
                                    )
                                }
                        )
                        .overlay {
                            selectionGuide(lyrics: lyrics)
                        }
                    }
                } else if player.lyrics?.isInstrumental == true {
                    VStack(spacing: 10) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("纯音乐，请欣赏")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeLyrics)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            selectionTimeoutTask?.cancel()
        }
    }

    @ViewBuilder
    private func selectionGuide(lyrics: ParsedLyrics) -> some View {
        let isScrolling = isDragging || scrollSettleTask != nil
        if let index = isScrolling ? nearestIndex : selectedIndex,
           lyrics.lines.indices.contains(index) {
            HStack(spacing: 8) {
                if isScrolling {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                    }
                    .frame(height: 1)
                } else {
                    Spacer()
                }

                Text(Formatters.duration(lyrics.lines[index].time))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .offset(x: 25)
            }
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
        }
    }

    private func nearestLine(to guideY: CGFloat, in centers: [Int: CGFloat]) -> Int? {
        centers.min { abs($0.value - guideY) < abs($1.value - guideY) }?.key
    }

    private func scheduleScrollSelection(guideY: CGFloat, proxy: ScrollViewProxy) {
        scrollSettleTask?.cancel()
        // ponytail: iOS 16 has no scroll phase API; replace with onScrollPhaseChange
        // when the deployment target reaches iOS 18.
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let selection = nearestLine(to: guideY, in: lineCenters) ?? nearestIndex
            selectedIndex = selection
            nearestIndex = selection
            scrollSettleTask = nil
            guard let selection else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                proxy.scrollTo(selection, anchor: .center)
            }
            scheduleSelectionTimeout(proxy: proxy)
        }
    }

    private func scheduleSelectionTimeout(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, selectedIndex != nil else { return }
            returnToActiveLine(proxy: proxy)
        }
    }

    private func returnToActiveLine(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        guard let activeIndex else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    private func closeLyrics() {
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        isDragging = false
        onClose()
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: LyricLine,
        isActive: Bool,
        isSelected: Bool,
        availableWidth: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1.02 : 12.0 / 13.0, anchor: .leading)
                }

                LyricMainText(
                    line: line, isActive: isActive,
                    size: 17, weight: .bold,
                    verbatim: settings.verbatimLyrics
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(isActive ? 1.02 : 16.0 / 17.0, anchor: .leading)

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1.02 : 12.0 / 13.0, anchor: .leading)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0))
            )
            .contentShape(Rectangle())
            .padding(.trailing, availableWidth * (1 - 1 / 1.02))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isActive)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

private struct MinimalLyricCentersKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

// MARK: - Minimal track info row

private struct MinimalTrackInfoRow: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @State private var showAddToPlaylist = false
    @State private var commentsTrack: Track?
    @State private var airPlayRequest = 0
    let onOpenDestination: (Destination) -> Void
    let onOpenSoundEffects: () -> Void
    var metadataOnly = false
    var actionsOnly = false

    var body: some View {
        Group {
            if metadataOnly {
                metadata(alignment: .center, textAlignment: .center)
                    .padding(.horizontal, 48)
            } else if actionsOnly {
                if let track = player.currentTrack {
                    HStack {
                        favoriteButton(for: track)
                        Spacer()
                        moreMenu(for: track)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    metadata(alignment: .leading, textAlignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let track = player.currentTrack {
                        favoriteButton(for: track)
                        moreMenu(for: track)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
        .sheet(item: $commentsTrack) { track in
            SongCommentsView(track: track)
        }
    }

    private func metadata(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                Text(player.currentTrack?.name ?? "")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            if let track = player.currentTrack {
                NowPlayingTrackDestinationLinks(
                    track: track,
                    font: .footnote,
                    color: .white.opacity(0.62),
                    onOpenDestination: onOpenDestination
                )
            }
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveTrackMetadata")
    }

    private func favoriteButton(for track: Track) -> some View {
        let liked = account.isLiked(track.id)
        return Button {
            Task { await account.toggleLike(trackID: track.id) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(liked ? "取消收藏" : "收藏")
        .accessibilityIdentifier("immersiveFavoriteButton")
    }

    private func moreMenu(for track: Track) -> some View {
        Menu {
            TrackDownloadActions(track: track, showsIcons: true)
            TrackBlacklistMenu(track: track, showsIcons: true)
            SongCommentsMenuButton(track: track, showsIcons: true) {
                commentsTrack = track
            }
            Divider()
            Button {
                airPlayRequest += 1
            } label: {
                Label("AirPlay", systemImage: "airplayaudio")
            }

            Button {
                player.addToPlayNext(track)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Divider()

            #if os(iOS)
            SleepTimerMenu(player: player)

            Divider()
            #endif

            Button {
                onOpenSoundEffects()
            } label: {
                Label("音效", systemImage: "waveform")
            }

            Divider()

            Button {
                Platform.copyToPasteboard(
                    string: Upstream.songPageURL(id: track.id)?.absoluteString ?? ""
                )
                ToastCenter.shared.show(String(localized: "链接已复制"))
            } label: {
                Label("复制链接", systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("immersiveMoreMenu")
        .background {
            RoutePickerButton(
                diameter: 1, glyphSize: 1, request: airPlayRequest,
                tint: .clear, background: .clear
            )
            .opacity(0.01)
        }
    }
}

private struct MinimalTransportControls: View {
    @EnvironmentObject private var player: PlayerService
    let backdrop: ArtworkColors
    @Binding var showQueue: Bool
    let onOpenDestination: (Destination) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("播放列表")
            .accessibilityIdentifier("immersivePlaylistButton")
                .frame(maxWidth: .infinity)

            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")

            playbackModeButton
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
        .sheet(isPresented: $showQueue) {
            queueSheet
                .modifier(OfflinePlaybackAlert(player: player, onDownloads: {
                    showQueue = false
                    onOpenDestination(.downloaded)
                }, enabled: showQueue && player.showNowPlaying))
                .modifier(MeteredDownloadAlert(enabled: showQueue && player.showNowPlaying))
        }
    }

    @ViewBuilder
    private var queueSheet: some View {
        if #available(iOS 16.4, *) {
            IOSPlaybackQueueView(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
                .presentationBackgroundInteraction(.enabled)
        } else {
            IOSPlaybackQueueView(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
        }
    }

    @ViewBuilder
    private var playbackModeButton: some View {
        if player.isFMMode {
            Color.clear
                .frame(height: 44)
        } else {
            Button(action: player.cyclePlaybackMode) {
                Image(systemName: playbackModeIcon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(playbackModeTint)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackModeLabel)
        }
    }

    private var playbackModeIcon: String {
        if player.shuffleEnabled { return "shuffle" }
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var playbackModeTint: Color {
        (player.shuffleEnabled || player.repeatMode != .off)
            ? Theme.accent
            : .white.opacity(0.88)
    }

    private var playbackModeLabel: LocalizedStringKey {
        if player.shuffleEnabled { return "随机播放" }
        switch player.repeatMode {
        case .off: return "顺序播放"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }
}


#endif


// Coda's NowPlayingScrubber, copied verbatim from Coda's
// Features/Player/NowPlayingView.swift (AGPL-3.0). Replaces HAo's own
// NowPlayingScrubber: same name and call sites, Coda's behaviour and the
// quality pill overlay (HAo-native NowPlayingQualityControl).
// MARK: - Scrubber (white-on-dark variant)

struct NowPlayingScrubber: View {
    var showsRemainingTime = false
    var rowHeight: CGFloat = 44
    var trackHeight: CGFloat = NowPlayingSliderStyle.trackHeight
    var tint: Color = .white
    var showsQualityControl = true
    var alignsWithTrackSummary = false
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var dragDuration: TimeInterval = 0
    @State private var dragTrackID: Int?
    @State private var cancelledDuringGesture = false

    private var updatesContinuously: Bool {
        player.isPlaying && !player.isBuffering && !isDragging
            && windowVisibility.isVisible && scenePhase != .background
    }

    var body: some View {
        // Read the engine clock on the display schedule without publishing
        // per-frame playback updates to the rest of the player.
        TimelineView(.animation(paused: !updatesContinuously)) { _ in
            let duration = isDragging ? dragDuration : player.duration
            let position = isDragging ? dragProgress : player.livePlaybackTime
            let elapsed = position.isFinite ? max(position, 0) : clock.progress
            let fraction = duration.isFinite && duration > 0 ? min(elapsed / duration, 1) : 0
            scrubber(fraction: fraction, elapsed: elapsed)
        }
        .frame(height: rowHeight)
        // Keep quality controls outside the seek gesture's subtree.
        .overlay(alignment: .bottom) {
            if showsQualityControl {
                NowPlayingQualityControl()
                    .frame(width: 148, height: 24)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlayingProgress")
        .onChange(of: player.currentTrack?.id) { _ in
            if isDragging {
                cancelledDuringGesture = true
                cancelScrubbing()
            }
        }
        .onDisappear { cancelScrubbing() }
    }

    private func scrubber(fraction: Double, elapsed: TimeInterval) -> some View {
        GeometryReader { geo in
            VStack(spacing: 5) {
                PlayerSlider(fraction: fraction, fillColor: tint,
                             trackColor: tint.opacity(NowPlayingSliderStyle.trackOpacity),
                             trackHeight: trackHeight, onChanged: { value in
                    guard !cancelledDuringGesture else { return }
                    if !isDragging {
                        guard player.duration.isFinite, player.duration > 0 else { return }
                        dragDuration = player.duration
                        dragTrackID = player.currentTrack?.id
                        isDragging = true
                        player.isScrubbing = true
                    }
                    guard dragTrackID == player.currentTrack?.id else {
                        cancelledDuringGesture = true
                        cancelScrubbing()
                        return
                    }
                    dragProgress = value * dragDuration
                }, onEnded: { value in
                    if isDragging, dragTrackID == player.currentTrack?.id {
                        player.seek(to: value * dragDuration)
                    }
                    cancelScrubbing()
                    cancelledDuringGesture = false
                }, onCancelled: {
                    cancelScrubbing()
                    cancelledDuringGesture = false
                })
                .frame(height: 24)
                // The dock title is centered 9.5pt above the summary's midpoint.
                .offset(y: alignsWithTrackSummary ? -(16 + 3) / 2 : 0)

                if !alignsWithTrackSummary {
                    timeLabels(elapsed: elapsed)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay {
                if alignsWithTrackSummary {
                    // Match the dock's 18pt title + 3pt gap above its 16pt artist line.
                    timeLabels(elapsed: elapsed).offset(y: (18 + 3) / 2)
                }
            }
        }
    }

    private func timeLabels(elapsed: TimeInterval) -> some View {
        HStack {
            Text(Formatters.duration(elapsed))
                .accessibilityIdentifier("nowPlayingElapsedTime")
            Spacer()
            if showsRemainingTime {
                Text("−" + Formatters.duration(max(0, player.duration - elapsed)))
                    .accessibilityIdentifier("nowPlayingRemainingTime")
            } else {
                Text(Formatters.duration(player.duration))
            }
        }
        .font(Theme.Typography.caption.monospacedDigit())
        .foregroundStyle(tint.opacity(0.55))
    }

    private func cancelScrubbing() {
        guard isDragging else { return }
        isDragging = false
        dragTrackID = nil
        dragDuration = 0
        player.isScrubbing = false
    }


}

// MARK: - Mini lyrics (compact now-playing)

/// Three synced lyric lines (previous / current / next) filling the gap
/// between the track meta and the transport controls on compact layouts.
/// Tapping opens the full lyrics page.
struct MiniLyricsView: View {
    let onOpen: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor

    private var lines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (previous, current, next) = lines
        Group {
            if current != nil || next != nil {
                VStack(spacing: 12) {
                    line(previous, emphasized: false)
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Text(line?.text.isEmpty == false ? line!.text : " ")
            .font(.system(size: emphasized ? 17 : 14, weight: emphasized ? .bold : .medium))
            .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .id(line?.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}


// Coda portrait player members, copied verbatim from Coda's
// Features/Player/NowPlayingView.swift (AGPL-3.0; license headers kept
// on the files they came from). Seams adapted afterwards are marked SEAM.
//
// NOTE: Coda calls the reduce-motion environment value reducePlayerMotion;
// HAo's NowPlayingView already names it reduceMotion, so the extract renames
// that one token mechanically. Everything else is byte-identical.
extension NowPlayingView {
    /// Slider dimensions shared across devices; the iPhone also uses this spacing rhythm.
    private struct ControlMetrics {
        let scale: CGFloat
        init(width: CGFloat) { scale = min(1.15, max(0.95, width / 356)) }
        init(scale: CGFloat) { self.scale = scale }
        var progressHeight: CGFloat { 52 * scale }
        var progressGap: CGFloat { 24 * scale }
        var transportHeight: CGFloat { 82 * scale }
        var transportGap: CGFloat { 36 * scale }
        var volumeHeight: CGFloat { 32 * scale }
        var utilityGap: CGFloat { 4 * scale }
        var utilityHeight: CGFloat { 50 * scale }
        var trackHeight: CGFloat { 7 * scale }
        var totalHeight: CGFloat { 280 * scale }
    }

    private func playbackControls<Utility: View>(width: CGFloat, animated: Bool = false,
                                                 metrics: ControlMetrics? = nil,
                                                 @ViewBuilder utility: () -> Utility) -> some View {
        let metrics = metrics ?? ControlMetrics(width: width)
        return VStack(spacing: 0) {
            controlLayer(animated: animated, offset: 180, showDelay: 0.025, hideDelay: 0.075) {
                NowPlayingScrubber(showsRemainingTime: true, rowHeight: metrics.progressHeight,
                                   trackHeight: metrics.trackHeight)
            }
            Color.clear.frame(height: metrics.progressGap)
            controlLayer(animated: animated, offset: 165, showDelay: 0.05, hideDelay: 0.05) {
                PlayerTransportControls(width: width, height: metrics.transportHeight)
            }
            Color.clear.frame(height: metrics.transportGap)
            controlLayer(animated: animated, offset: 148, showDelay: 0.075, hideDelay: 0.025) {
                volumeControl(rowHeight: metrics.volumeHeight, trackHeight: metrics.trackHeight)
            }
            Color.clear.frame(height: metrics.utilityGap)
            controlLayer(animated: animated, offset: 128, showDelay: 0.10, hideDelay: 0) {
                utility().frame(height: metrics.utilityHeight)
            }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func controlLayer<Content: View>(animated: Bool, offset: CGFloat,
                                             showDelay: Double, hideDelay: Double,
                                             @ViewBuilder content: () -> Content) -> some View {
        #if os(iOS)
        if animated {
            portraitControlLayer(offset: offset, showDelay: showDelay, hideDelay: hideDelay, content: content)
        } else {
            content()
        }
        #else
        content()
        #endif
    }

    private func usesPortraitLayout(size: CGSize) -> Bool {
        #if os(iOS)
        return size.width < 600 || size.height > size.width
        #else
        return false
        #endif
    }

    private func singleColumnTrackHeader(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            #if os(iOS)
            portraitArtworkLink(size: 72, expanded: false)
            #else
            artworkView(size: 72, cornerRadius: 12)
            #endif
            NowPlayingTrackInfoRow(
                onOpenDestination: openTrackDestination,
                largeMetadata: true,
                usesPortraitHeaderSizing: true,
                movesMoreToDeviceRow: true,
                showsMoreBesideFavorite: true,
                metadataWidth: max(0, width - 72 - 12 - (player.currentTrack == nil ? 0 : 132 + 3 * Theme.Spacing.small)),
                onAddToPlaylist: togglePlaylistPanel,
                // SEAM: HAo-only — opens the sound-effects sheet.
                onOpenSoundEffects: { showSoundEffects = true }
            )
            .frame(maxWidth: .infinity)
        }
        .frame(width: width)
        .frame(minHeight: max(72, iPadMetadataHeight))
        .fixedSize(horizontal: false, vertical: true)
    }

    #if os(iOS)
    /// Shared vertical composition for iPad portrait and iPhone. The viewport
    /// reuses the landscape panels while the controls keep their own space.
    private func portraitLayout(size: CGSize) -> some View {
        portraitControlsAutoHide(portraitLayoutContent(size: size), showsArtwork: portraitShowsArtwork)
    }

    private var portraitShowsArtwork: Bool {
        !showsSingleColumnLyrics && iPadPanel == .lyrics && playlistTrack == nil
    }

    /// The playback controls float over the lyrics and fade out after 3s of
    /// inactivity while playing. Shared by iPhone portrait and landscape.
    private func portraitControlsAutoHide<Content: View>(_ content: Content, showsArtwork: Bool) -> some View {
        content
            .onPreferenceChange(PortraitControlsHeightKey.self) { height in
                if height > 0 { portraitControlsHeight = height }
            }
            // Rotation swaps the layout subtree; keep the remembered collapse
            // state and only restart the idle timer. Artwork mode always shows them.
            .onAppear {
                if showsArtwork { registerPortraitControlsActivity() } else { restartPortraitControlsIdleTimer() }
            }
            .onChange(of: player.showNowPlaying) { shown in
                if shown { registerPortraitControlsActivity() }
            }
            .onChange(of: iPadPanel) { _ in registerPortraitControlsActivity() }
            .onChange(of: playlistTrack?.id) { _ in registerPortraitControlsActivity() }
            .onChange(of: usesPortraitLyricsInterface) { usesLyrics in
                // A track change clears lyrics while the next ones load; keep
                // collapsed controls hidden then. Reveal only for a song without lyrics.
                if usesLyrics || player.lyrics == nil {
                    restartPortraitControlsIdleTimer()
                } else {
                    registerPortraitControlsActivity()
                }
            }
            .onChange(of: player.currentTrack?.id) { _ in restartPortraitControlsIdleTimer() }
            .onChange(of: player.isPlaying) { _ in registerPortraitControlsActivity() }
            .onChange(of: playerVoiceOverEnabled) { _ in registerPortraitControlsActivity() }
            .task(id: portraitControlsActivityGeneration) {
                // SEAM (chen 2026-11-26): no auto-hide — the controls stay
                // visible in lyrics mode. Coda hides them after 3s of
                // inactivity while playing; that behaviour is deliberately
                // not copied. Tap-to-toggle still works via
                // togglePortraitControlsFromTap.
                return
            }
    }

    private func portraitLayoutContent(size: CGSize) -> some View {
        let isNarrow = size.width < 600
        let inset: CGFloat = isNarrow ? 24 : min(72, size.width * 0.06)
        let width = max(0, min(size.width - inset * 2, 960))
        // The header and panels share the progress bar's width, as on Mac.
        let contentWidth = portraitControlsWidth(availableWidth: width)
        let showsFullControls = iPadPanel == .lyrics && playlistTrack == nil
        let showsArtwork = !showsSingleColumnLyrics && showsFullControls
        let lyricsVisible = !showsArtwork && portraitLyricsEntrancePresented
        let trackID = player.currentTrack?.id
        let lyricsPrepared = player.lyrics?.isEmpty != false || portraitPreparedLyricsTrackID == trackID
        return ZStack(alignment: .bottom) {
            // Keep the lyric viewport alive across artwork toggles. Recreating
            // its native text hosts during the transition stalls the first frames.
            VStack(spacing: isNarrow ? Theme.Spacing.small : Theme.Spacing.component) {
                singleColumnTrackHeader(width: contentWidth)
                .offset(y: showsArtwork && !reduceMotion ? 40 : 0)
                .opacity(showsArtwork ? 0 : 1)
                .animation(PortraitPageMotion.header(presented: !showsArtwork, reduced: reduceMotion),
                           value: showsArtwork)

                playbackContentPanel
                    .environment(\.nowPlayingLyricsPresented, !showsArtwork)
                    .environment(\.nowPlayingLyricsInitialFocusPrepared, {
                        guard player.currentTrack?.id == trackID else { return }
                        portraitPreparedLyricsTrackID = trackID
                    })
                    .environment(\.nowPlayingLyricsInterface, usesPortraitLyricsInterface ? NowPlayingLyricsInterface(
                        isVisible: !portraitControlsCollapsed,
                        bottomOverlayHeight: portraitControlsHeight,
                        onVisibilityChange: { setPortraitControlsVisible($0) },
                        onInteraction: togglePortraitControlsFromTap
                    ) : nil)
                    .padding(.bottom, usesPortraitLyricsInterface ? 0 : portraitControlsHeight)
                    // As on Mac, lyrics, comments, queue and playlist panels
                    // start at the header's leading edge with no own gutter.
                    .environment(\.nowPlayingFlushPanelEdges, true)
                    .overlay(alignment: .bottomTrailing) {
                        if iPadPanel == .lyrics && playlistTrack == nil {
                            iPadLyricsAnnotationButtons
                                .offset(y: portraitControlsCollapsed ? 64 : -portraitControlsHeight)
                                .scaleEffect(portraitControlsCollapsed ? 0.82 : 1)
                                .opacity(portraitControlsCollapsed ? 0 : 1)
                                .allowsHitTesting(!portraitControlsCollapsed)
                                .accessibilityHidden(portraitControlsCollapsed)
                                .animation(portraitInterfaceAnimation(duration: 0.24,
                                    delay: portraitControlsCollapsed ? 0.10 : 0), value: portraitControlsCollapsed)
                        }
                    }
                    .layoutPriority(-1)
                    .scaleEffect(!lyricsVisible && !reduceMotion ? 0.90 : 1)
                    .animation(PortraitPageMotion.lyricsSpatial(reduced: reduceMotion), value: lyricsVisible)
                    .opacity(lyricsVisible ? 1 : 0)
                    .animation(PortraitPageMotion.opacity(reduced: reduceMotion), value: lyricsVisible)
            }
            .frame(width: contentWidth)
            .allowsHitTesting(!showsArtwork)
            .accessibilityHidden(showsArtwork)

            portraitArtworkContent(width: width)
                .offset(y: showsArtwork || reduceMotion ? 0 : -300)
                .opacity(showsArtwork ? 1 : 0)
                .allowsHitTesting(showsArtwork)
                .accessibilityHidden(!showsArtwork)
                .animation(reduceMotion ? nil : PortraitPageMotion.smooth(
                    duration: showsArtwork ? 0.22 : 0.24).delay(showsArtwork ? 0.07 : 0), value: showsArtwork)

            // One controls tree remains in place for both content presentations.
            Group {
                if showsFullControls {
                    portraitPlaybackControls(width: width, allowsArtwork: true)
                } else {
                    portraitUtilityBar(allowsArtwork: true)
                        .frame(width: portraitControlsWidth(availableWidth: width),
                               height: ControlMetrics(width: portraitControlsWidth(availableWidth: width)).utilityHeight)
                }
            }
            .background {
                GeometryReader { controls in
                    Color.clear.preference(key: PortraitControlsHeightKey.self, value: controls.size.height)
                }
            }
            .allowsHitTesting(!showsFullControls || !portraitControlsCollapsed)
            .accessibilityHidden(showsFullControls && portraitControlsCollapsed)
        }
        .frame(width: width)
        .background {
            portraitArtworkContent(width: width, measuresArtwork: true)
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            portraitSharedArtwork(expanded: showsArtwork, headerLeading: (width - contentWidth) / 2)
        }
        .coordinateSpace(name: "NowPlayingPortraitArtwork")
        .onPreferenceChange(PortraitArtworkFrameKey.self) { frame in
            guard frame.width > 0, frame.height > 0,
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { return }
            if abs(frame.minX - portraitArtworkPageFrame.minX) > 0.5
                || abs(frame.minY - portraitArtworkPageFrame.minY) > 0.5
                || abs(frame.width - portraitArtworkPageFrame.width) > 0.5
                || abs(frame.height - portraitArtworkPageFrame.height) > 0.5 {
                portraitArtworkPageFrame = frame
            }
        }
        .padding(.top, UIDevice.current.userInterfaceIdiom == .pad ? 64 : 34)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: showsArtwork) { expanded in
            registerPortraitControlsActivity()
            if expanded {
                portraitLyricsExitStartedAt = .now
                portraitLyricsEntrancePresented = false
                portraitLyricsEntranceStartedAt = nil
            } else {
                // Reversing an unfinished exit continues immediately.
                let reversesExit = portraitLyricsExitStartedAt.map {
                    $0.duration(to: .now) < .seconds(0.18)
                } ?? false
                portraitLyricsEntrancePresented = reversesExit || reduceMotion
                portraitLyricsEntranceStartedAt = .now
            }
        }
        .task(id: PortraitLyricsEntranceID(expanded: showsArtwork, trackID: trackID, prepared: lyricsPrepared)) {
            guard !showsArtwork, !portraitLyricsEntrancePresented else { return }
            await Task.yield()
            let start = portraitLyricsEntranceStartedAt ?? .now
            let deadline = start.advanced(by: .seconds(reduceMotion ? 0 : lyricsPrepared ? 0.07 : 0.35))
            do {
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining > .zero { try await Task.sleep(for: remaining) }
                try Task.checkCancellation()
            } catch { return }
            portraitLyricsEntrancePresented = true
        }
        .accessibilityIdentifier("portraitNowPlaying")
    }

    /// Artwork occupies the space above metadata and the same playback controls.
    /// Its size follows the available height so small phones keep every control reachable.
    private func portraitArtworkContent(width: CGFloat, measuresArtwork: Bool = false) -> some View {
        GeometryReader { available in
            let controlsWidth = portraitControlsWidth(availableWidth: width)
            let metrics = ControlMetrics(width: controlsWidth)
            let controlsHeight = metrics.progressHeight + metrics.progressGap
                + metrics.transportHeight + metrics.transportGap
                + metrics.volumeHeight + metrics.utilityGap + metrics.utilityHeight
            let coverSize = max(0, min(width,
                available.size.height - controlsHeight - iPadMetadataHeight - 32))
            VStack(spacing: 0) {
                portraitArtworkLink(size: coverSize, expanded: true)
                    .background {
                        if measuresArtwork {
                            GeometryReader { geometry in
                                Color.clear.preference(key: PortraitArtworkFrameKey.self,
                                    value: geometry.frame(in: .named("NowPlayingPortraitArtwork")))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                NowPlayingTrackInfoRow(
                    onOpenDestination: openTrackDestination,
                    largeMetadata: true,
                    usesPortraitHeaderSizing: true,
                    movesMoreToDeviceRow: true,
                    showsMoreBesideFavorite: true,
                    metadataWidth: max(0, controlsWidth - portraitMetadataActionsWidth),
                    onAddToPlaylist: togglePlaylistPanel,
                    // SEAM: HAo-only — opens the sound-effects sheet.
                    onOpenSoundEffects: { showSoundEffects = true }
                )
                .frame(width: controlsWidth, alignment: .leading)
                .frame(minHeight: iPadMetadataHeight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
                .padding(.bottom, 12)
                Color.clear.frame(height: controlsHeight)
                    .accessibilityHidden(true)
            }
            .frame(width: width, height: available.size.height)
        }
    }

    /// One overlay travels between the stationary artwork-page measurement and
    /// the 72pt song header; page details animate independently underneath it.
    @ViewBuilder
    private func portraitSharedArtwork(expanded: Bool, headerLeading: CGFloat) -> some View {
        if portraitArtworkPageFrame.width > 0 {
            let frame = expanded ? portraitArtworkPageFrame : CGRect(x: headerLeading, y: 0, width: 72, height: 72)
            let pausedInset = expanded && !player.isPlaying ? frame.width * (1 - 0.74) / 2 : 0
            let displayedFrame = frame.insetBy(dx: pausedInset, dy: pausedInset)
            NowPlayingPortraitArtwork(image: artworkImage, isArtworkPage: expanded, isPlaying: player.isPlaying)
                .frame(width: displayedFrame.width, height: displayedFrame.height)
                .position(x: displayedFrame.midX, y: displayedFrame.midY)
                .animation(PortraitPageMotion.artwork(reduced: reduceMotion), value: expanded)
                .animation(reduceMotion ? nil : PortraitPageMotion.smooth(duration: 0.48),
                           value: player.isPlaying)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func portraitArtworkLink(size: CGFloat, expanded: Bool) -> some View {
        if let album = player.currentTrack?.album, album.id != 0 {
            Button {
                openTrackDestination(.album(album.id))
            } label: {
                Color.clear
                    .frame(width: size, height: size)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .noFocusRing()
            .accessibilityLabel("打开专辑：\(album.name)")
            .accessibilityIdentifier(expanded ? "portraitLargeArtwork" : "portraitSmallArtwork")
        } else {
            Color.clear.frame(width: size, height: size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var portraitMetadataActionsWidth: CGFloat {
        player.currentTrack == nil ? 0 : 132 + 3 * Theme.Spacing.small
    }

    private var usesPortraitLyricsInterface: Bool {
        iPadPanel == .lyrics && playlistTrack == nil && player.lyrics?.isEmpty == false
    }

    private func portraitControlsWidth(availableWidth: CGFloat) -> CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad
            ? max(0, availableWidth) : max(0, min(availableWidth - 16, 420))
    }

    private func portraitPlaybackControls(width: CGFloat, allowsArtwork: Bool,
                                          metrics: ControlMetrics? = nil) -> some View {
        let controlsWidth = portraitControlsWidth(availableWidth: width)
        return playbackControls(width: controlsWidth, animated: true, metrics: metrics) {
            portraitUtilityBar(allowsArtwork: allowsArtwork)
        }
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture {}
        }
        .background {
            NowPlayingControlsTouchObserver(isEnabled: !portraitControlsCollapsed) { active in
                portraitControlsInteractionActive = active
            }
        }
        .onChange(of: portraitControlsInteractionActive) { _ in
            // Cancel the pending hide on touch-down; start a fresh idle interval
            // on release (including gesture cancellation), even after a long hold.
            registerPortraitControlsActivity()
        }
    }

    private func portraitControlLayer<Content: View>(
        offset: CGFloat, showDelay: Double, hideDelay: Double,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .offset(y: portraitControlsCollapsed && !reduceMotion ? offset : 0)
            .opacity(portraitControlsCollapsed ? 0 : 1)
            .animation(portraitInterfaceAnimation(duration: 0.24,
                delay: portraitControlsCollapsed ? hideDelay : showDelay), value: portraitControlsCollapsed)
    }

    private func portraitInterfaceAnimation(duration: Double, delay: Double = 0) -> Animation? {
        guard !reduceMotion else { return nil }
        if #available(iOS 17, *) {
            return .smooth(duration: duration).delay(delay)
        }
        // SwiftUI's smooth spring is unavailable on the deployment target.
        return .timingCurve(0.4, 0, 0.2, 1, duration: duration).delay(delay)
    }

    private func registerPortraitControlsActivity() {
        portraitControlsActivityGeneration &+= 1
        withAnimation(portraitInterfaceAnimation(duration: 0.34)) {
            portraitControlsCollapsed = false
        }
    }

    /// Restarts the 3s idle interval without revealing collapsed controls.
    private func restartPortraitControlsIdleTimer() {
        portraitControlsActivityGeneration &+= 1
    }

    /// A tap on blank lyric space toggles the controls. Hiding by hand also
    /// works while paused; VoiceOver keeps them visible.
    private func togglePortraitControlsFromTap() {
        guard !portraitControlsCollapsed, usesPortraitLyricsInterface, !playerVoiceOverEnabled,
              !portraitControlsInteractionActive else {
            registerPortraitControlsActivity()
            return
        }
        portraitControlsActivityGeneration &+= 1
        withAnimation(portraitInterfaceAnimation(duration: 0.34)) {
            portraitControlsCollapsed = true
        }
    }

    private func setPortraitControlsVisible(_ visible: Bool) {
        if visible {
            registerPortraitControlsActivity()
        } else {
            guard player.isPlaying, usesPortraitLyricsInterface, !playerVoiceOverEnabled,
                  !portraitControlsCollapsed, !portraitControlsInteractionActive else { return }
            portraitControlsActivityGeneration &+= 1
            withAnimation(portraitInterfaceAnimation(duration: 0.34)) {
                portraitControlsCollapsed = true
            }
        }
    }

    private func portraitUtilityBar(allowsArtwork: Bool) -> some View {
        HStack(spacing: 0) {
            CurrentPlaybackDeviceButton()
                .layoutPriority(-1)
            Spacer(minLength: 12)
            HStack(spacing: Theme.Spacing.small) {
                iPadPanelButton("text.bubble", label: "歌曲评论", selected: iPadPanel == .comments && playlistTrack == nil) {
                    // SEAM: HAo has no SongCommentsStore; iPadComments is a
                    // track-id token (Int?) marking which track's comments
                    // are open. The panel renders HAo's SongCommentsView.
                    if let track = player.currentTrack, iPadComments != track.id {
                        iPadComments = track.id
                    }
                    iPadPanel = iPadPanel == .comments && playlistTrack == nil ? .lyrics : .comments
                    playlistTrack = nil
                }
                .disabled(player.currentTrack == nil)
                iPadPanelButton("list.bullet", label: "待播清单", selected: iPadPanel == .queue && playlistTrack == nil) {
                    iPadPanel = iPadPanel == .queue && playlistTrack == nil ? .lyrics : .queue
                    playlistTrack = nil
                }
                iPadPanelButton("quote.bubble", label: "歌词",
                                selected: iPadPanel == .lyrics && playlistTrack == nil
                                    && (!allowsArtwork || showsSingleColumnLyrics)) {
                    // Only the resident page layers animate. Do not propagate
                    // a layout animation into the lyric glyphs or volume slider.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        portraitControlsCollapsed = false
                    }
                    if allowsArtwork {
                        showsSingleColumnLyrics = iPadPanel == .lyrics && playlistTrack == nil
                            ? !showsSingleColumnLyrics : true
                    }
                    playlistTrack = nil
                    iPadPanel = .lyrics
                }
                .accessibilityValue(iPadPanel == .lyrics && playlistTrack == nil
                    && (!allowsArtwork || showsSingleColumnLyrics) ? "已显示" : "已收起")
                .accessibilityHint(allowsArtwork ? "切换歌词与大封面" : "显示歌词")
                .accessibilityIdentifier("portraitLyricsToggle")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    #endif

    private var playbackContentPanel: some View {
        ZStack {
            if let track = playlistTrack {
                NowPlayingAddToPlaylistColumn(track: track) { playlistTrack = nil }
                    .id(track.id)
                    .transition(.opacity)
            } else if iPadPanel == .comments, let track = player.currentTrack,
               iPadComments == track.id {
                // SEAM: HAo's own comments view (load + like), not Coda's
                // SongCommentsColumn/SongCommentsStore — those need a
                // differently-shaped comment model and send/delete endpoints
                // HAo's API wrapper does not have. onClose returns to lyrics
                // (the view's own xmark has no sheet to dismiss here).
                SongCommentsView(track: track, onClose: { iPadPanel = .lyrics })
                    .id(track.id)
                    .transition(.opacity)
            } else if iPadPanel == .queue {
                IOSInlinePlaybackQueueView()
                    .transition(.opacity)
            } else if hasLyricsColumn || player.lyrics?.isInstrumental == true {
                portraitLyricsColumn
                    .transition(.opacity)
            } else {
                VStack(spacing: Theme.Spacing.control) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 32, weight: .light))
                    Text("暂无歌词")
                        .font(.subheadline)
                }
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.24), value: iPadPanel)
        .animation(.easeInOut(duration: 0.24), value: playlistTrack?.id)
    }

    private func togglePlaylistPanel() {
        playlistTrack = playlistTrack == nil ? player.currentTrack : nil
    }

    private var iPadLyricsAnnotationButtons: some View {
        VStack(spacing: Theme.Spacing.small) {
            lyricsAnnotationButtonContents
        }
    }

    @ViewBuilder
    private var lyricsAnnotationButtonContents: some View {
        if hasLyricsRomaji {
            iPadPanelButton("", label: "罗马音",
                            selected: settings.lyricsAnnotation == .romaji,
                            customIcon: Image("LyricsRomaji").renderingMode(.template)) {
                settings.lyricsAnnotation = settings.lyricsAnnotation == .romaji ? .off : .romaji
            }
            .accessibilityValue(settings.lyricsAnnotation == .romaji ? "已显示" : "已隐藏")
            .accessibilityHint("切换罗马音的显示")
            .accessibilityIdentifier("iPadLyricsRomajiButton")
        }
        if hasLyricsTranslation {
            iPadPanelButton("translate", label: "歌词翻译",
                            selected: settings.showLyricsTranslation,
                            customIcon: Image("LyricsLanguages").renderingMode(.template)) {
                settings.showLyricsTranslation.toggle()
            }
            .accessibilityValue(settings.showLyricsTranslation ? "已显示" : "已隐藏")
            .accessibilityHint("切换歌词翻译的显示")
            .accessibilityIdentifier("iPadLyricsTranslationButton")
        }
    }

    private var hasLyricsRomaji: Bool {
        player.lyrics?.lines.contains { line in
            guard let romaji = line.romaji else { return false }
            return !romaji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
    }

    private var hasLyricsTranslation: Bool {
        player.lyrics?.lines.contains { line in
            guard let translation = line.translation else { return false }
            return !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
    }

    private func iPadPanelButton(_ icon: String, label: String, selected: Bool,
                                 customIcon: Image? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let customIcon {
                    customIcon.resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 20)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                }
            }
                .foregroundStyle(.white.opacity(selected ? 1 : 0.65))
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(selected ? 0.16 : 0))
                        .padding(3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func volumeControl(rowHeight: CGFloat,
                               trackHeight: CGFloat = NowPlayingSliderStyle.trackHeight) -> some View {
        HStack(spacing: Theme.Spacing.control) {
            Image(systemName: "speaker.fill").font(.system(size: 13))
            #if os(iOS) && !targetEnvironment(simulator)
            IOSSystemVolumeSlider(trackHeight: trackHeight, showsLevelIcon: true).frame(height: rowHeight)
            #else
            // The simulator has no system volume route (MPVolumeView shows
            // "No Volume Available"), so drive the in-app gain there instead.
            PlayerSlider(fraction: Double(player.volume), trackHeight: trackHeight,
                         onChanged: { player.volume = Float($0) },
                         onEnded: { player.volume = Float($0) })
                .frame(height: rowHeight)
            PlayerVolumeIcon(volume: Double(player.volume))
            #endif
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(height: rowHeight)
    }

    // MARK: - Lyrics column (renamed: HAo's NowPlayingView already has a
    // lyricsColumn; this is Coda's, verbatim apart from the name)

    @ViewBuilder
    private var portraitLyricsColumn: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            AppleMusicLyricsColumn(lyrics: lyrics)
                .id(player.currentTrack?.id)
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if player.lyrics != nil {
            Text("暂无歌词")
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: Theme.Spacing.control) {
                #if os(iOS)
                if player.lyricsLoadFailed {
                    Text("歌词加载失败")
                        .foregroundStyle(.white.opacity(0.6))
                    Button("重新加载") {
                        Task { await player.loadCurrentLyricsIfNeeded() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
                #else
                ProgressView().controlSize(.small).tint(.white)
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openTrackDestination(_ destination: Destination) {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad,
           player.showNowPlaying,
           let dismissThen = dismissNowPlayingThenAction {
            // SEAM: HAo's key is the same shape as Coda's (a closure that runs
            // the action after dismissing); no provider is wired yet, so this
            // branch never runs and navigation falls through below.
            dismissThen { onOpenDestination(destination) }
            return
        }
        #endif
        onOpenDestination(destination)
    }

}


// Coda portrait player top-level types, copied verbatim from Coda's
// Features/Player/NowPlayingView.swift (AGPL-3.0).
#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-only
// Motion adapted from youshen2/MeloX at 09713edb847a0f0a3515a34f779cc630d4fe5985:
// NowPlayingMotionSpec.swift and the shared overlay in NowPlayingView.swift.
// See ThirdPartyNotices/MeloX.md for iOS 16 and renderer adaptations.
private enum PortraitPageMotion {
    static func artwork(reduced: Bool) -> Animation? {
        guard !reduced else { return nil }
        return smooth(duration: 0.30)
    }

    static func lyricsSpatial(reduced: Bool) -> Animation? {
        guard !reduced else { return nil }
        return .interpolatingSpring(mass: 1, stiffness: 350, damping: 40, initialVelocity: 0)
    }

    static func opacity(reduced: Bool) -> Animation? {
        reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.18)
    }

    static func header(presented: Bool, reduced: Bool) -> Animation? {
        guard !reduced else { return nil }
        return smooth(duration: presented ? 0.40 : 0.24).delay(presented ? 0.08 : 0)
    }

    static func smooth(duration: Double) -> Animation {
        if #available(iOS 17, *) { return .smooth(duration: duration) }
        // No-bounce spring fallback for the physical iPad on iPadOS 16.
        return .spring(response: duration, dampingFraction: 1)
    }
}
#endif

// MARK: - Track info row

private struct NowPlayingTrackInfoRow: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.playlistPanelSelected) private var playlistPanelSelected
    @State private var showAddToPlaylist = false
    let onOpenDestination: (Destination) -> Void
    var metadataOnly = false
    var actionsOnly = false
    var largeMetadata = false
    var usesPortraitHeaderSizing = false
    var movesMoreToDeviceRow = false
    var showsMoreBesideFavorite = false
    var metadataWidth: CGFloat? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    // SEAM: HAo-only. Opens the sound-effects sheet (chen 2026-11-26: the EQ
    // lives in this row's "..." menu). Threaded through to the more menu.
    var onOpenSoundEffects: (() -> Void)? = nil

    var body: some View {
        Group {
            if metadataOnly {
                metadata(alignment: .center, textAlignment: .center)
                    .padding(.horizontal, 48)
            } else if actionsOnly {
                if let track = player.currentTrack {
                    HStack {
                        favoriteButton(for: track)
                        Spacer()
                        NowPlayingTrackMoreMenu(track: track, onOpenDestination: onOpenDestination,
                                               onOpenSoundEffects: onOpenSoundEffects)
                    }
                }
            } else {
                HStack(spacing: Theme.Spacing.small) {
                    metadata(alignment: .leading, textAlignment: .leading)
                        .frame(width: metadataWidth, alignment: .leading)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let track = player.currentTrack {
                        if movesMoreToDeviceRow {
                            addToPlaylistButton
                        }
                        favoriteButton(for: track)
                        if !movesMoreToDeviceRow || showsMoreBesideFavorite {
                            NowPlayingTrackMoreMenu(track: track, onOpenDestination: onOpenDestination,
                                                  onOpenSoundEffects: onOpenSoundEffects)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }

    private func metadata(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: usesPortraitHeaderSizing ? 2 : Theme.Spacing.tight) {
            HStack(spacing: 6) {
                Text(player.currentTrack?.name ?? "")
                    .font(usesPortraitHeaderSizing ? .title3.weight(.semibold) : (largeMetadata ? Theme.Typography.cardTitle : Theme.Typography.trackTitle))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            if let track = player.currentTrack {
                NowPlayingTrackDestinationLinks(
                    track: track,
                    font: usesPortraitHeaderSizing ? .title3 : Theme.Typography.secondary,
                    color: .white.opacity(0.62),
                    onOpenDestination: onOpenDestination
                )
            }
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveTrackMetadata")
    }

    private var addToPlaylistButton: some View {
        Button {
            if let onAddToPlaylist { onAddToPlaylist() }
            else { showAddToPlaylist = true }
        } label: {
            Image("PlaylistAdd")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity((playlistPanelSelected || showAddToPlaylist) ? 0.16 : 0))
                        .padding(3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits((playlistPanelSelected || showAddToPlaylist) ? .isSelected : [])
        .accessibilityLabel("添加到歌单")
        .accessibilityIdentifier("iPadAddToPlaylistButton")
    }

    private func favoriteButton(for track: Track) -> some View {
        PlayerFavoriteButton(trackID: track.id, size: 22, side: 44, tint: .white)
            .accessibilityIdentifier("immersiveFavoriteButton")
    }
}

struct NowPlayingTrackMoreMenu: View {
    @EnvironmentObject private var player: PlayerService
    let track: Track
    var tint: Color = .white.opacity(0.88)
    var accessibilityID = "immersiveMoreMenu"
    var showsLyricsAdjustment = true
    var showsPlaybackControls = false
    var showsPlaybackPanels = false
    var usesPortraitStyle = true
    var onAddToPlaylist: (() -> Void)? = nil
    var onOpenDestination: ((Destination) -> Void)? = nil
    // SEAM: HAo-only (see NowPlayingTrackInfoRow above).
    var onOpenSoundEffects: (() -> Void)? = nil
    @EnvironmentObject private var account: AccountStore

    #if os(macOS)
    @EnvironmentObject private var settings: SettingsManager
    @State private var showsMorePopover = false
    #endif

    var body: some View {
        #if os(macOS)
        Button { showsMorePopover.toggle() } label: {
            moreButtonLabel
        }
        .buttonStyle(.pressable)
        .popover(isPresented: $showsMorePopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if showsPlaybackPanels {
                    Button {
                        player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
                        showsMorePopover = false
                    } label: { Label("歌词", systemImage: "quote.bubble") }
                    Button {
                        settings.showDesktopLyrics.toggle()
                        showsMorePopover = false
                    } label: { Label("桌面歌词", systemImage: "inset.filled.bottomthird.square") }
                    Button {
                        player.activePanel = player.activePanel == .queue ? nil : .queue
                        showsMorePopover = false
                    } label: { Label("播放列表", systemImage: "list.bullet") }
                    .disabled(player.isFMMode)
                    Divider()
                }
                menuContents
            }
            .padding(12)
            .frame(width: 286)
            .buttonStyle(LyricsMoreMenuRowStyle())
            // Submenus reuse the row button style so they match the other rows.
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier(accessibilityID)
        #else
        Menu {
            menuContents
        } label: {
            moreButtonLabel
        }
        .menuOrder(.fixed)
        .tint(.white)
        .preferredColorScheme(.dark)
        .buttonStyle(.pressable)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier(accessibilityID)
        #endif
    }

    private var moreButtonLabel: some View {
        Image(systemName: "ellipsis")
            .font(usesPortraitStyle ? .title3.weight(.semibold) : .system(size: 22, weight: .medium))
            .foregroundStyle(usesPortraitStyle ? .white : tint)
            .frame(width: usesPortraitStyle ? 40 : 44, height: usesPortraitStyle ? 40 : 44)
            .contentShape(Circle())
    }

    @ViewBuilder
    private var menuContents: some View {
        if usesPortraitStyle {
            portraitMenuContents
        } else {
            standardMenuContents
        }
    }

    @ViewBuilder
    private var portraitMenuContents: some View {
        if showsPlaybackControls {
            playbackControls
            Divider()
        }
        // SEAM: no LyricsSourceMenu — HAo has a single lyrics source, so
        // there is nothing to switch between (Coda's row is dropped, not stubbed).
        if showsLyricsAdjustment {
            lyricsTimingControls
        }
        if let onOpenSoundEffects {
            // SEAM: Coda has no EQ row here; chen 2026-11-26 wants the
            // equalizer in this "..." menu (same sheet as Settings → 音效).
            Button { onOpenSoundEffects() } label: {
                Label("音效", systemImage: "waveform")
            }
        }
        #if os(iOS)
        Divider()
        SleepTimerMenu(player: player)
        #endif
        Divider()
        if track.album.id != 0 {
            let album = track.album
            Button { onOpenDestination?(.album(album.id)) } label: {
                Label("前往专辑：" + album.name, systemImage: "music.note.list")
            }
        }
        Menu {
            ForEach(track.artists.filter { $0.id != 0 }) { artist in
                Button(artist.name) { onOpenDestination?(.artist(artist.id)) }
            }
        } label: { Label("前往歌手", systemImage: "music.mic") }
        Divider()
        if let url = track.musicShareURL {
            ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
        }
        TrackDownloadActions(track: track, showsIcons: true)
    }

    @ViewBuilder
    private var standardMenuContents: some View {
        if showsPlaybackControls {
            playbackControls
            Divider()
        }
        Button {
            Platform.copyToPasteboard(string: track.musicShareURL?.absoluteString ?? "")
            ToastCenter.shared.show(String(localized: "链接已复制"))
            #if os(macOS)
            showsMorePopover = false
            #endif
        } label: {
            Label("复制链接", systemImage: "link")
        }

        #if os(iOS)
        Divider()
        SleepTimerMenu(player: player)
        #endif

        Divider()
        // SEAM: no LyricsSourceMenu — HAo has a single lyrics source (see above).
        if showsLyricsAdjustment {
            lyricsTimingControls
        }

        Divider()
        TrackDownloadActions(track: track, showsIcons: true)
    }

    @ViewBuilder
    private var playbackControls: some View {
        if player.isFMMode {
            Button { player.fmTrash() } label: {
                Label("不喜欢，换一首", systemImage: "trash")
            }
        } else {
            #if os(macOS)
            Button { player.cycleQueueOrder() } label: {
                Label(player.queueOrder.controlHelp, systemImage: player.queueOrder.symbolName)
            }
            #else
            Toggle(isOn: Binding(get: { player.shuffleEnabled }, set: { _ in player.toggleShuffle() })) {
                Label("随机播放", systemImage: "shuffle")
            }
            #endif
            Button { player.cycleRepeatMode() } label: {
                Label(player.repeatMode == .one ? "单曲循环" : (player.repeatMode == .off ? "循环关闭" : "列表循环"),
                      systemImage: player.repeatMode == .one ? "repeat.1" : "repeat")
            }
        }
        #if os(iOS)
        Button {
            player.activePanel = player.activePanel == .queue ? nil : .queue
        } label: {
            Label("播放列表", systemImage: "list.bullet")
        }
        .disabled(player.isFMMode)
        #endif
    }

    @ViewBuilder
    private var lyricsTimingControls: some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            lyricsTimingButtons.menuActionDismissBehavior(.disabled)
        } else {
            lyricsTimingButtons
        }
        #else
        VStack(alignment: .leading, spacing: 10) {
            Text("歌词时间调节")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                timingButton("-0.2s", symbol: "arrow.left") {
                    player.adjustLyricsTiming(by: -2)
                }
                timingButton("还原", symbol: "arrow.counterclockwise") {
                    player.setLyricsTiming(steps: 0)
                }
                timingButton("+0.2s", symbol: "arrow.right") {
                    player.adjustLyricsTiming(by: 2)
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(player.lyrics?.isEmpty != false || player.currentTrack?.id != track.id)
        #endif
    }

    #if os(macOS)
    private func timingButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 25)
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(title)
    }
    #endif

    #if os(iOS)
    private var lyricsTimingButtons: some View {
        ControlGroup {
            Button {
                player.adjustLyricsTiming(by: -2)
            } label: {
                lyricsTimingLabel("-0.2s", image: "LyricsTimingEarlier")
            }
            .accessibilityLabel("歌词快了，延后零点二秒")

            Button {
                player.setLyricsTiming(steps: 0)
            } label: {
                lyricsTimingLabel("还原", image: "LyricsTimingReset")
            }
            .accessibilityLabel("还原歌词时间")

            Button {
                player.adjustLyricsTiming(by: 2)
            } label: {
                lyricsTimingLabel("+0.2s", image: "LyricsTimingLater")
            }
            .accessibilityLabel("歌词慢了，提前零点二秒")
        }
        .disabled(player.lyrics?.isEmpty != false || player.currentTrack?.id != track.id)
    }

    private func lyricsTimingLabel(_ title: String, image: String) -> some View {
        Label {
            Text(title)
                .font(.system(size: 12))
        } icon: {
            Image(image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.white)
        }
    }
    #endif

}


#if os(macOS)
private struct LyricsMoreMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
    }
}
#endif

#if os(iOS)
private struct PortraitControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif

private struct PlaylistPanelSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var playlistPanelSelected: Bool {
        get { self[PlaylistPanelSelectedKey.self] }
        set { self[PlaylistPanelSelectedKey.self] = newValue }
    }
}
