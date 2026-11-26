import SwiftUI

/// 入口：无启动动画，直接进主界面（chen 2026-11-26 决定：三个应用都不要启动动画）。
@main
struct HAoMusicApp: App {
    @StateObject private var playerService = PlayerService()
    @StateObject private var libraryStore = LibraryStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(playerService)
                .environmentObject(libraryStore)
        }
    }
}
