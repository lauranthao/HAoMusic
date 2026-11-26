import SwiftUI

/// The quality pill centred between the scrubber's times, Coda's exact
/// capsule look (21pt high, 10.5pt medium text, 0.75pt capsule border).
///
/// HAo-NATIVE, not a copy of Coda's NowPlayingQualityControl: Coda's control
/// switches the playing track's tier live (switchAudioQuality, badge state,
/// UnblockResolver, songAudioQualityOptions, qishui tiers), and HAo has no
/// per-track quality-switch path — its unlock race resolves the tier before
/// playback. This pill only DISPLAYS the tier actually served
/// (player.servedQuality), using Coda's unified title strings. It is a plain
/// view, not a menu, so it never promises a tap that does nothing.
struct NowPlayingQualityControl: View {
    @EnvironmentObject private var player: PlayerService

    private var title: String {
        guard player.currentTrack != nil else { return "" }
        guard let quality = player.servedQuality.flatMap(AudioQuality.init(rawValue:)) else {
            return String(localized: "音质")
        }
        switch quality {
        case .standard: return String(localized: "标准")
        case .higher, .exhigh: return String(localized: "高品质")
        case .lossless: return String(localized: "无损")
        case .hires: return String(localized: "高解析度无损")
        }
    }

    private var badgeQuality: AudioQuality? {
        player.servedQuality.flatMap(AudioQuality.init(rawValue:))
    }

    var body: some View {
        Group {
            if !title.isEmpty {
                HStack(spacing: 4) {
                    if let badgeQuality,
                       [AudioQuality.lossless, .hires].contains(badgeQuality) {
                        QualityWaveMark()
                            .stroke(style: StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round))
                            .frame(width: 15, height: 11)
                    }
                    Text(title)
                        .lineLimit(1)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .padding(.horizontal, 7)
                .frame(height: 21)
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
                .accessibilityLabel("当前音质")
                .accessibilityValue(title)
                .accessibilityIdentifier("nowPlayingAudioQuality")
            }
        }
    }
}

/// Three flowing strokes identify lossless/high-resolution audio without a
/// disclosure arrow. Verbatim from Coda's NowPlayingQualityControl.swift.
private struct QualityWaveMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width * 0.72
        for wave in 0..<3 {
            let offset = CGFloat(wave) * rect.width * 0.14
            for step in 0...32 {
                let t = CGFloat(step) / 32
                let point = CGPoint(
                    x: rect.minX + offset + width * t,
                    y: rect.midY - sin(t * .pi * 2) * rect.height * 0.38
                )
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        return path
    }
}
