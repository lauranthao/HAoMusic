import SwiftUI

/// 全屏播放页：封面、标题/歌手、进度条、上一首/播放/下一首、随机/循环/喜欢/歌词。
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var isSeeking = false
    @State private var seekValue: Double = 0

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
                        // v1 歌词数据还没接：先放空壳，点歌词行跳转的逻辑已在 LyricsView 里
                        LyricsView(lines: [], currentTime: player.currentTime, onSeek: { player.seek(to: $0) })
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("没有正在播放")
                            .font(.headline)
                        Text("先从资料库导入本地音频，或从首页点一首歌。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 80)
                }
                Spacer()
            }
            .padding(.horizontal, HaoMusicDesign.horizontalPadding)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down")
                    }
                }
            }
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
