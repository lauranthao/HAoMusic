# HAo Music

HAo Music — 参照 Kumone 设计的音乐应用（iOS）。

## 参照与许可

- 参照：Kumone（https://github.com/missuo/kumone，LGPL-3.0）。功能与界面参考学习，代码全部重写；不复制 Kumone 的源码、密钥与网易协议常量，不模仿域名混淆手法。
- Kumone 是单平台（网易云）客户端；HAo Music 的多平台聚合（网易 + QQ 优先）需另行设计，不在 v1。

## v1 骨架（P0）

- 四个页签：首页 / 搜索 / 资料库 / 设置
- AVPlayer 播放引擎：队列、随机、全部/单曲循环、进度、锁屏/控制中心切歌（MPRemoteCommandCenter）
- 迷你播放条 + 全屏播放页（封面、标题/歌手、进度条、上一首/播放/下一首、随机/循环/喜欢/歌词入口）
- 歌词视图壳：LRC 解析 + 同步高亮 + 点行跳转（歌词数据未接，无歌词时显示“暂无歌词”）
- 本地曲库：资料库导入本地音频（文件选择器，拷进 Documents/Imported）、我喜欢的、最近播放（上限 50 条），只存本机 UserDefaults
- 无登录

## 设计决定

- **无启动动画（chen 2026-11-26：三个应用都不要启动动画）**：不做 splash，进应用直接到主界面。实现：Info.plist 用空 `UILaunchScreen`（系统默认底色，无 logo、无动画），代码里没有 SplashView，`HAoMusicApp` 直接进 `RootTabView`。
- 品牌色：红色（取自 logo 的红色音符）；封面占位为红底白音符。
- 部署目标 iOS 16.0，Swift 6；Bundle ID `com.haostudio.music`；版本 0.1.0 (1)。
- 图标：chen 选定的红色音符白底（1024x1024），各尺寸槽位暂共用同一张 1024 图，后续再按尺寸导出。

## 结构

`Sources/HAoMusic/` 镜像 Kumone 的分层（App / Core / Features / DesignSystem）：

```
Sources/HAoMusic/
  App/            HAoMusicApp.swift（入口）、RootTabView.swift（四页签 + 迷你播放条）
  Core/
    Models/       Track.swift
    Player/       PlayerService.swift（AVPlayer 引擎）、PlaybackItem.swift、LyricsParser.swift
    Storage/      LibraryStore.swift（喜欢/最近播放/本地音频）
  DesignSystem/   DesignTokens.swift
  Features/
    Home/         HomeView.swift（最近播放、我喜欢的）
    Search/       SearchView.swift（本地曲库搜索）
    Library/      LibraryView.swift（导入/删除本地音频）+ AudioImportPicker
    Player/       PlayerView.swift、MiniPlayerBar.swift、LyricsView.swift
    Settings/     SettingsView.swift
    Shared/       TrackCoverView.swift、TrackRow.swift
  Resources/      Info.plist、Assets.xcassets（AppIcon + AccentColor）
```

## 构建

- 需要 Xcode 26+、macOS；iOS 16+ 真机或模拟器。
- 打开 `HAoMusic.xcodeproj`，选 HAoMusic scheme，Run。
- 签名：`CODE_SIGN_STYLE = Automatic`，首次构建需在 Xcode 里选自己的 Team。
- 本 Linux VM 无 Xcode：已用 Swift 6.2 工具链做 `swiftc -parse`（17 个文件全过）+ 纯 Foundation 文件类型检查（Track、LyricsParser）+ LRC 解析实跑验证；**Xcode 构建未验，需在 Mac/CI 上跑**。

## 后续（不在 v1）

- 网络曲库：网易 + QQ 优先的多平台聚合搜索与播放、音质档位与自动降级、灰色歌曲提示与下一源 fallback
- 歌词数据、均衡器、睡眠定时、下载离线
- 每日推荐 / 私人 FM / 心动模式（需登录后）
