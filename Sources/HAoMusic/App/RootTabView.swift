import SwiftUI

/// 四个页签：首页 / 搜索 / 资料库 / 设置。迷你播放条浮在 tab bar 上方。
struct RootTabView: View {
    @EnvironmentObject private var player: PlayerService
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                HomeView()
                    .tabItem { Label("首页", systemImage: "house.fill") }
                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                LibraryView()
                    .tabItem { Label("资料库", systemImage: "square.stack.fill") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
            }
            if player.hasCurrentItem {
                MiniPlayerBar(onTap: { showPlayer = true })
                    .padding(.horizontal, 8)
                    .padding(.bottom, 49) // 坐在 tab bar 上方（标准 tab bar 高 49pt）
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView()
        }
    }
}
