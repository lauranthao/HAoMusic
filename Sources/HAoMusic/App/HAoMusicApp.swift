import SwiftUI

/// 入口：无启动动画，直接进主界面（chen 2026-11-26 决定：三个应用都不要启动动画）。
/// 设置 → 网络曲库门面 → 播放器（带解析器）的依赖链在这里组装。
@main
struct HAoMusicApp: App {
    @StateObject private var settings: MusicSettings
    @StateObject private var musicService: HaoMusicService
    @StateObject private var loginManager: LoginSessionManager
    @StateObject private var playerService: PlayerService
    @StateObject private var libraryStore = LibraryStore()

    init() {
        let settings = MusicSettings()
        let loginManager = LoginSessionManager()
        let service = HaoMusicService(settings: settings, loginManager: loginManager)
        _settings = StateObject(wrappedValue: settings)
        _loginManager = StateObject(wrappedValue: loginManager)
        _musicService = StateObject(wrappedValue: service)
        _playerService = StateObject(wrappedValue: PlayerService(resolver: service.resolver))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(settings)
                .environmentObject(loginManager)
                .environmentObject(musicService)
                .environmentObject(playerService)
                .environmentObject(libraryStore)
                .task {
                    // 启动恢复登录态（网易走服务端校验，QQ 走结构检查；失败不断登录）。
                    await loginManager.restore()
                }
        }
    }
}
