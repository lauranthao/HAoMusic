import SwiftUI

/// v1 只搜本地曲库；网络曲库后续接入。
struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerService
    @State private var query = ""

    private var results: [Track] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return library.localTracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("搜索本地曲库", text: $query)
                    .textFieldStyle(.roundedBorder)
                if query.isEmpty {
                    Text("v1 只搜本地曲库；网络曲库后续接入。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if results.isEmpty {
                    Text("没有找到“\(query)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(results) { track in
                                TrackRow(track: track, onPlay: {
                                    if let index = library.localTracks.firstIndex(of: track) {
                                        player.play(tracks: library.localTracks, startAt: index)
                                    }
                                    library.recordPlayed(track)
                                })
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, HaoMusicDesign.horizontalPadding)
            .padding(.top, 8)
            .navigationTitle("搜索")
        }
    }
}
