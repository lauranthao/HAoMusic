import SwiftUI

/// 曲目行：封面 + 标题/歌手 + 喜欢按钮。整行点按播放，♥ 只管收藏。
struct TrackRow: View {
    let track: Track
    var onPlay: () -> Void
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        HStack(spacing: 12) {
            TrackCoverView(track: track, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { library.toggleLike(track) }) {
                Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                    .foregroundStyle(library.isLiked(track) ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }
}
