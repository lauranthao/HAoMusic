import SwiftUI

/// 歌词视图：同步高亮当前行，点行跳转。无歌词时诚实显示“暂无歌词”。
struct LyricsView: View {
    let lines: [LyricsLine]
    let currentTime: Double
    var onSeek: (Double) -> Void

    var body: some View {
        if lines.isEmpty {
            Text("暂无歌词")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.body)
                                .fontWeight(isActive(line) ? .bold : .regular)
                                .foregroundStyle(isActive(line) ? .primary : .secondary)
                                .id(line.id)
                                .onTapGesture { onSeek(line.time) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: currentTime) { _ in
                    scrollToActive(proxy: proxy)
                }
            }
        }
    }

    private func isActive(_ line: LyricsLine) -> Bool {
        LyricsParser.activeIndex(in: lines, at: currentTime).map { lines[$0].id == line.id } ?? false
    }

    private func scrollToActive(proxy: ScrollViewProxy) {
        guard let index = LyricsParser.activeIndex(in: lines, at: currentTime) else { return }
        withAnimation {
            proxy.scrollTo(lines[index].id, anchor: .center)
        }
    }
}
