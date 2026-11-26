import SwiftUI

/// 入口：无启动动画，直接进主界面（chen 2026-11-26 决定：三个应用都不要启动动画）。
/// 设置 → 网络曲库门面 → 播放器（带解析器）的依赖链在这里组装。
@main
struct HAoMusicApp: App {
    @StateObject private var settings: MusicSettings
    @StateObject private var musicService: HaoMusicService
    @StateObject private var playerService: PlayerService
    @StateObject private var libraryStore = LibraryStore()

    init() {
        let settings = MusicSettings()
        let service = HaoMusicService(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _musicService = StateObject(wrappedValue: service)
        _playerService = StateObject(wrappedValue: PlayerService(resolver: service.resolver))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(settings)
                .environmentObject(musicService)
                .environmentObject(playerService)
                .environmentObject(libraryStore)
        }
    }
}
