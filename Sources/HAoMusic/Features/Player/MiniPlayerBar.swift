import SwiftUI

/// 迷你播放条：浮在 tab bar 上方，点按打开全屏播放页。
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerService
    var onTap: () -> Void

    var body: some View {
        if let track = player.currentItem?.track {
            HStack(spacing: 12) {
                TrackCoverView(track: track, size: 40)
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
                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                Button(action: { player.next() }) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: HaoMusicDesign.miniPlayerHeight)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: HaoMusicDesign.cardCornerRadius))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }
}
