import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HaoMusicDesign.sectionSpacing) {
                    recentSection
                    likedSection
                }
                .padding(.horizontal, HaoMusicDesign.horizontalPadding)
                .padding(.top, 8)
            }
            .navigationTitle("首页")
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近播放").font(.headline)
            if library.recentTracks.isEmpty {
                emptyHint("还没有播放记录")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(library.recentTracks) { track in
                            Button(action: { play(track) }) {
                                VStack(alignment: .leading, spacing: 6) {
                                    TrackCoverView(track: track, size: 120)
                                    Text(track.title)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 120, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var likedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("我喜欢的").font(.headline)
            if library.likedTracks.isEmpty {
                emptyHint("还没有喜欢的歌曲 — 在播放页点 ♥ 收藏")
            } else {
                ForEach(library.likedTracks) { track in
                    TrackRow(track: track, onPlay: { play(track) })
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func play(_ track: Track) {
        if let index = library.localTracks.firstIndex(of: track) {
            player.play(tracks: library.localTracks, startAt: index, source: .home)
        } else {
            player.play(track: track, source: .home)
            library.cacheNetworkTrack(track)
        }
        library.recordPlayed(track)
    }
}
