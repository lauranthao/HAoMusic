import SwiftUI

/// 封面占位：红底圆角 + 白色音符。真封面图后续接入。
struct TrackCoverView: View {
    let track: Track
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(HaoMusicDesign.accent.gradient)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
