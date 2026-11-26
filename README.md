# HAo Music

HAo Music — iOS 音乐应用，基于 Kumone 的代码 + Coda 的 QQ 平台（chen 2026-11-26 决定：照抄，只改一点点 UI 和布局）。
网易云音乐 + QQ 音乐双源，AVPlayer 播放，支持扫码登录、均衡器、睡眠定时、离线下载。

## 来源与许可

HAo Music 的代码基于以下两个开源项目，版权归各自原作者所有，复制的文件保留了原项目的版权声明：

- **Kumone**（https://github.com/missuo/kumone，LGPL-3.0）——应用主体：网易云音乐源（eapi/weapi、音质降档、灰歌解锁）、播放器、均衡器、歌词、下载、FM、扫码登录。许可文本见 `LICENSE-LGPL-3.0.txt`。
- **Coda**（https://github.com/Wow-CaiCai/Coda，AGPL-3.0）——QQ 音乐平台（`Core/Sources/QQ/`）：vkey 取流（高→低档位降级、多 CDN 探测）、QQ 扫码登录、收藏同步。许可文本见 `LICENSE-AGPL-3.0.txt`。
- Coda 的 QQ 代码本身改编自 Beans-Music（MIT），见 `ThirdPartyNotices-Beans-Music.md`。
- **第三方音源（运行时调用，未复制代码）**：灰歌解锁用的 pyncmd 镜像服务（`music-api.gdstudio.xyz`）与 haitangw 解析服务（`musicapi.haitangw.net` / `music.haitangw.cc`），均为第三方公开接口；`Core/Player/` 里的调用代码是 HAo 独立编写的。
- **洛雪音源解析接口**（https://github.com/pdone/lx-music-source）：仅参考，未复制脚本、未调用其接口；见 `ThirdPartyNotices/README.md`。

**合并后的 HAo Music 按 AGPL-3.0 分发。**

## 免责声明

- HAo Music 仅供个人学习、研究与交流使用。
- 本应用不托管、不拥有任何音乐版权。歌曲、歌词、封面、评论等内容均来自网易云音乐、QQ 音乐、酷狗音乐、酷我音乐等平台的公开接口，由各平台实时提供；第三方音源（镜像、解析服务）仅为匹配同一首歌的参考途径，不由本应用提供或控制。
- 全部音乐内容与商标的权利归原平台与原权利人所有。请支持正版音乐，通过平台会员获取相应权益。
- 完整条款见应用内「设置 → 关于 → 查看完整免责声明」；首次启动时也会请你阅读并确认。

## HAo 自己的改动（与参照不同处）

- **上游域名写明文**：Kumone 的域名算术题混淆与移位混淆字符串全部去掉，`Core/API/Upstream.swift` 是 HAo 重写的明文版（`music.163.com` / `interface.music.163.com` / `.music.126.net`），API 与原版一致；`UpstreamGate` 改为直通，不再弹设置题。
- **QQ 接入为解锁源**：Coda 的 QQ 平台接在 Kumone 的 `AudioSourceProvider` 体系里（`Core/Sources/QQ/QQAudioSourceProvider.swift`）；灰歌走解锁时按 pyncmd 镜像 → 解析服务 → 已登录 QQ → 酷狗 → 酷我并行竞速（见下「音源与播放规则」）。
- **底栏顺序**：保持 Kumone 原版（推荐 / 精选 / 漫游 / 我的 / 搜索），不改菜单栏；改的是页面布局——首页板块重排（新碟上架置顶），专辑/歌手/歌单/我的四个页面照 Coda 的 hero 结构重做（大封面居中、黑色播放胶囊）。
- **换牌**：界面里的 "Kumone" 字样全部改为 "HAo Music"（存储占用、同步提示、文件保存提示、菜单栏）；主题红 `#EC4949` 本来就是红色，与 HAo 红色音符 logo 一致，未改。
- **更新检查指回本仓库**：`ReleaseChecker` 指 `lauranthao/HAoMusic`，`IOSUpdater` 下载的包名改为 `HAoMusic.ipa`；分发渠道 plist 键改为 `HAoMusicDistribution`（默认 sideload）。
- **无启动动画**（chen 2026-11-26：三个应用都不要启动动画）：`UILaunchScreen` 为空，`HAoMusicApp` 直接进主界面。
- **构建**：保留 HAo 的 `HAoMusic.xcodeproj`（不换构建系统），C 的 DSP（`Core/DSP/`）与 ObjC 抓异常 helper（`Core/ObjC/`）以模块映射接入；目标 `SWIFT_VERSION = 5.0`（Kumone 核心是 v5 模式）。

## 未抄 / 未做（后续再做）

- **合并多源搜索**：Kumone 和 Coda 都没有，照抄版也没有——搜索按当前平台单搜。合并搜索是后续单独一腿。
- **Coda 的其他平台**：酷狗主源、汽水未抄；只抄了 QQ 平台。Kumone 自带的酷狗/酷我解锁源保留。
- **Coda 的微信登录**（`QQMusicAdditionalLogin.swift`，含微信 App ID 与 MQTT 通道）未抄。
- **Kumone 的 macOS 部分**：macOS 专属文件留在仓库里（`#if os(macOS)` 守卫，iOS 构建不编译）；Sparkle/StemKit（MLX 人声分离）是 macOS 专属依赖，iOS 不用。

## 音源与播放规则（照 Kumone/Coda 的来）

- 音质自动降档：目标档位播不了就往下降，直到有可播地址；只报实测档位，不谎报。
- 灰歌/VIP 歌走解锁：并行竞速，优先顺序 pyncmd 镜像 → 解析服务 → 已登录 QQ → 酷狗 → 酷我；8 秒/源、15 秒总限，优先顺序中最先成功者胜；10 分钟匹配缓存与失败记忆。
- 失败记忆只记硬错误，不记超时；手动点歌先清失败记忆。
- 登录：网易云 / QQ 音乐扫码登录（官方 App 扫码），会话存钥匙串；登录后请求带 Cookie，高档位按账号给。

## 构建

- 需要 Xcode 26+、macOS；iOS 16+ 真机或模拟器。
- 打开 `HAoMusic.xcodeproj`，选 HAoMusic scheme，Run。
- 签名：`CODE_SIGN_STYLE = Automatic`，首次构建需在 Xcode 里选自己的 Team。
- 部署目标 iOS 16.0；Bundle ID `com.haostudio.music`；版本 0.1.1 (1)。
- 图标：chen 选定的红色音符白底（1024x1024）。

## 验证（2026-11-26，VM 实测）

| 检查 | 结果 |
| --- | --- |
| `swiftc -parse` 全部 Swift 文件 | 零错误（见下） |
| pbxproj 生成器 | 递归扫描 `Sources/HAoMusic`，无 `,,`，括号平衡，全部文件在 sources build phase |
| Xcode 构建 | **未验**（本机无 Xcode；Bitrise 是真正的验证） |
| 真机扫码登录 / 登录后高档位 | **未验**（需 chen 的手机或国内真机） |
| 网易匿名取流 | 本机出口 IP 匿名取流全部 404（地域/登录限制），需国内真机验证 |
| 合并搜索 | **不在本版**（后续一腿） |
