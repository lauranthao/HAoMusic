# MeloX 播放器与歌词同步

来源：[youshen2/MeloX](https://github.com/youshen2/MeloX)
提交：`a41ea0e1e1fa69fb543d827b853fe3aff5420951`
许可证：GPL-3.0-only，全文见 [LICENSE-GPL-3.0.txt](../LICENSE-GPL-3.0.txt)。
版权：MeloX contributors。

## 怎么来的

这些文件是 Coda（[Wow-CaiCai/Coda](https://github.com/Wow-CaiCai/Coda)，AGPL-3.0）从 MeloX 改编的播放器代码；HAo Music 在 0.1.3 把 Coda 的版本原样引入，只改了接 HAo 自身类型（Track、播放器对象、歌词、设置）的接缝。文件头保留了 MeloX 的 SPDX 标识与改编说明。

## HAo Music 里的位置

| 文件 | 上游来源 |
| --- | --- |
| `Features/Player/NowPlayingPortraitArtwork.swift` | MeloX 竖屏播放器封面（经 Coda 改编，提交 `09713ed`） |
| `Features/Player/AppleMusicLyricsColumn.swift` | MeloX Apple Music 风格歌词列（排版与动效） |
| `Core/Player/LyricModels.swift` | MeloX 歌词模型与解析 |
| `Features/Player/NowPlayingFluidBackground.swift` | MeloX 流体背景（Metal 音频响应 + 渐变回退） |
| `Features/Player/LyricsScrollInterfaceVisibilityTracker.swift` | MeloX 歌词滚动界面可见性跟踪 |

## 许可说明

GPL-3.0-only 的代码可以并入 AGPL-3.0 的整体作品（GPLv3 第 13 条允许此组合），合并后的 HAo Music 仍按 AGPL-3.0 分发（见 [LICENSE](../LICENSE)）。MeloX 文件本身保持 GPL-3.0-only，不得单独改换许可证。
