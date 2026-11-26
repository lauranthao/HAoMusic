import SwiftUI

/// 全屏播放页：封面、标题/歌手、进度条、上一首/播放/下一首、随机/循环/喜欢/歌词。
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var musicService: HaoMusicService
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var lyricLines: [LyricsLine] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let track = player.currentItem?.track {
                    TrackCoverView(track: track, size: 280)
                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // 解析状态 / 实测档位徽标（只报实测来源与档位，不谎报）。
                    if let item = player.currentItem {
                        if player.resolvingTrackID == item.id {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在解析播放地址…")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if let quality = item.resolvedQuality {
                            Text(sourceBadgeText(item: item, quality: quality))
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(HaoMusicDesign.accent.opacity(0.12)))
                                .foregroundStyle(HaoMusicDesign.accent)
                        }
                        if let error = player.resolveError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { isSeeking ? seekValue : player.currentTime },
                                set: { seekValue = $0 }
                            ),
                            in: 0...(player.duration > 0 ? player.duration : 1),
                            onEditingChanged: { editing in
                                isSeeking = editing
                                if !editing {
                                    player.seek(to: seekValue)
                                }
                            }
                        )
                        HStack {
                            Text(formatTime(isSeeking ? seekValue : player.currentTime))
                            Spacer()
                            Text(formatTime(player.duration))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 40) {
                        Button(action: { player.previous() }) {
                            Image(systemName: "backward.fill").font(.title)
                        }
                        Button(action: { player.togglePlayPause() }) {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle)
                        }
                        Button(action: { player.next() }) {
                            Image(systemName: "forward.fill").font(.title)
                        }
                    }
                    HStack(spacing: 28) {
                        Button(action: { player.toggleShuffle() }) {
                            Image(systemName: "shuffle")
                                .foregroundStyle(player.shuffleEnabled ? HaoMusicDesign.accent : .primary)
                        }
                        Button(action: { player.cycleRepeatMode() }) {
                            Image(systemName: repeatIcon)
                                .foregroundStyle(player.repeatMode == .off ? .primary : HaoMusicDesign.accent)
                        }
                        Button(action: { library.toggleLike(track) }) {
                            Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                                .foregroundStyle(library.isLiked(track) ? .red : .primary)
                        }
                        Button(action: { showLyrics.toggle() }) {
                            Image(systemName: "text.quote")
                                .foregroundStyle(showLyrics ? HaoMusicDesign.accent : .primary)
                        }
                    }
                    .font(.title3)
                    if showLyrics {
                        LyricsView(lines: lyricLines, currentTime: player.currentTime, onSeek: { player.seek(to: $0) })
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("没有正在播放")
                            .font(.headline)
                        Text("先从搜索页搜一首歌，或从资料库导入本地音频。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 80)
                }
                Spacer()
            }
            .padding(.horizontal, HaoMusicDesign.horizontalPadding)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: player.currentItem?.id) {
                lyricLines = []
                guard let track = player.currentItem?.track else { return }
                guard let lrc = await musicService.lyrics(for: track) else { return }
                lyricLines = LyricsParser.parse(lrc: lrc)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down")
                    }
                }
            }
        }
    }

    private func sourceBadgeText(item: PlaybackItem, quality: AudioQuality) -> String {
        switch item.resolvedSource {
        case .provider(let provider):
            return "\(provider.displayName) · \(quality.bitrateLabel)"
        case .unlock(let source):
            return "\(source.displayName)解锁 · \(quality.bitrateLabel)"
        case .local, .none:
            return quality.bitrateLabel
        }
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
