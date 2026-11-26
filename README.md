# HAo Music

HAo Music — 参照 Kumone/Coda 设计的音乐应用（iOS）。功能结构借鉴，代码全部重写；
**合并多源搜索、第一个能播的立刻播、界面布局与交互、红音符 logo、无启动动画是 HAo 自己的设计**，
不是参照的翻版。

## 参照与许可

- 参照：Kumone（https://github.com/missuo/kumone，LGPL-3.0）、Coda（https://github.com/Wow-CaiCai/Coda，AGPL-3.0）。功能与界面参考学习，代码全部重写；不复制源码、密钥与网易协议常量，不模仿 Kumone 的域名混淆手法（域名写明文）。
- Kumone 是单平台（网易云）客户端，Coda 是多平台但搜索按当前平台单搜；HAo Music 的**合并搜索**（网易 + QQ 并行搜、去重、网易优先）是 HAo 自己的层，两家参照都没有。

## v1 骨架（P0）

- 四个页签：首页 / 搜索 / 资料库 / 设置
- AVPlayer 播放引擎：队列、随机、全部/单曲循环、进度、锁屏/控制中心切歌（MPRemoteCommandCenter）
- 迷你播放条 + 全屏播放页（封面、标题/歌手、进度条、上一首/播放/下一首、随机/循环/喜欢/歌词入口）
- 歌词视图：LRC 解析 + 同步高亮 + 点行跳转（无歌词时显示“暂无歌词”）
- 本地曲库：资料库导入本地音频（文件选择器，拷进 Documents/Imported）、我喜欢的、最近播放（上限 50 条），只存本机 UserDefaults
- 无登录

## 网络曲库层（P1，本轮）

- **音源**：网易 + QQ 为主源（搜索 + 取流 + 歌词，匿名可用，无需会员）；酷狗、酷我只做解锁源；汽水占位未接。
- **合并搜索**：网易 + QQ 并行搜，FNV-1a 指纹去重（标题 + 歌手 + 时长桶），一行一首歌，行尾带平台小徽标（网易/QQ），网易来源排前面；先回来的平台先出第一批（约 1 秒内见结果），完整结果随后补齐。搜索页分“网络”/“本地曲库”两节。
- **播放解析**：点播先解析，第一个能播的地址立刻播。主源内部自动降档；主源播不了先试合并搜索带过来的另一平台句柄，再走解锁竞速。
- **解锁竞速**：镜像（用户自填 pyncmd 兼容地址，留空不用；HAo 不内置任何第三方镜像地址）→ 酷狗 → 酷我并行跑，单源 8 秒超时、总上限 15 秒，最早成功者胜出。
- **失败记忆**：只记硬错误，不记超时/瞬断；10 分钟过期；手动点歌先清掉这首歌的失败记忆；自动切歌播不了直接跳下一首，手动点播不了停在原地提示原因。
- **播放页**：解析中显示“正在解析播放地址…”；播起来后显示实测档位徽标（平台 · 档位，如“网易 · 320K”“酷狗解锁 · 320K”），只报实测，不谎报；歌词按曲目来源平台拉取。
- **设置**：目标音质（默认极高 320K）、音源开关（网易/QQ，至少留一个）、解锁开关、镜像地址。
- **本地缓存**：播过的网络曲目只缓存元数据（标题/歌手/封面 URL/平台 ID，不存播放地址），最近 100 首；最近播放/我喜欢的能找到缓存的网络曲目。

## HAo 自己的设计（与参照不同处）

- **合并多源搜索**：两家参照都没有。并行搜 + 去重 + 网易优先 + 先出第一批。
- **第一个能播的立刻播**：目标音质只决定尝试顺序，绝不为等高档位阻塞播放；主源 → 另一平台句柄 → 解锁竞速的串联顺序是 HAo 的管线。
- **跨平台稳定 ID 不用 SHA-256**：用 FNV-1a 64 位指纹（纯 Swift，无需 CryptoKit）。
- **界面**：搜索页“网络在上、本地在下”+ 平台小徽标；播放页实测档位徽标；红音符品牌；无启动动画。
- **解锁源不内置地址**：镜像地址用户自填，HAo 不内置任何第三方镜像地址。

## 播放规则（照 Kumone/Coda 的来，不另起炉灶）

- 音质自动降档：目标档位播不了就往下降，直到有可播地址（Kumone/Coda）。
- 灰歌/VIP 歌走解锁：串行优先顺序镜像 → 酷狗 → 酷我（Kumone）；并行竞速、单源 8 秒、总 15 秒（Coda）。
- 超时与失败记忆：网络瞬断 400ms 后重试一次（Kumone）；失败记忆只记硬错误、不记超时，10 分钟过期（Coda 的匹配缓存窗口）；手动点歌先清失败记忆（Kumone/Coda 的共识）。
- 每次播放都记 PlaySource（搜索/首页/最近播放/我喜欢的/资料库/队列）。
- 只报实测档位：按实测码率估档位（Coda 的文件头校验思路），不轻信服务器标注。

## 设计决定

- **无启动动画（chen 2026-11-26：三个应用都不要启动动画）**：不做 splash，进应用直接到主界面。实现：Info.plist 用空 `UILaunchScreen`（系统默认底色，无 logo、无动画），代码里没有 SplashView，`HAoMusicApp` 直接进 `RootTabView`。
- 品牌色：红色（取自 logo 的红色音符）；封面占位为红底白音符；网络封面图用 AsyncImage 加载，失败回落占位。
- 部署目标 iOS 16.0，Swift 6；Bundle ID `com.haostudio.music`；版本 0.1.0 (1)。
- 图标：chen 选定的红色音符白底（1024x1024），各尺寸槽位暂共用同一张 1024 图，后续再按尺寸导出。

## 结构

`Sources/HAoMusic/` 镜像 Kumone 的分层（App / Core / Features / DesignSystem）：

```
Sources/HAoMusic/
  App/            HAoMusicApp.swift（入口，组装 设置 → 门面 → 播放器）、RootTabView.swift（四页签 + 迷你播放条）
  Core/
    Models/       Track.swift
    Player/       PlayerService.swift（AVPlayer 引擎 + 解析接线）、PlaybackItem.swift、LyricsParser.swift
    Storage/      LibraryStore.swift（喜欢/最近播放/本地音频/网络曲目缓存）
    Sources/      网络曲库层：
      MusicProvider.swift（netease/qq/kugou/qishui）、ProviderSong.swift（统一曲目 + FNV-1a 指纹）
      MusicProviderClient.swift（统一取流接口 + 错误分类）、AudioQuality.swift（档位 + 降档链）
      CapabilityCatalog.swift、PlaySource.swift、AsyncTimeout.swift、MD5.swift
      MusicSettings.swift（目标音质/音源/解锁/镜像地址）
      NeteaseProvider.swift + NeteaseCrypto.swift（eapi）、QQProvider.swift（vkey 降档链）
      KugouUnlockProvider.swift、KuwoUnlockProvider.swift、UnlockMatching.swift（候选打分）
      UnlockService.swift（镜像→酷狗→酷我竞速）、FailureMemory.swift、PlaybackResolver.swift
      HaoMusicService.swift（门面 + 合并搜索 + HaoSongMerger）
      LoginSession.swift（会话/扫码状态机/Cookie 工具/会话盒子）、SessionStore.swift（钥匙串）
      NeteaseLoginService.swift + QQLoginService.swift（扫码登录）、LoginSessionManager.swift（登录态）
  DesignSystem/   DesignTokens.swift
  Features/
    Home/         HomeView.swift（最近播放、我喜欢的）
    Search/       SearchView.swift（合并搜索：网络 + 本地，平台徽标行）
    Library/      LibraryView.swift（导入/删除本地音频）+ AudioImportPicker
    Player/       PlayerView.swift（解析状态/档位徽标/歌词拉取）、MiniPlayerBar.swift、LyricsView.swift
    Settings/     SettingsView.swift（账号/音质/音源/解锁/镜像地址）
                  AccountView.swift（账号页）、LoginQRView.swift（扫码登录页）
    Shared/       TrackCoverView.swift（AsyncImage + 占位）、TrackRow.swift
  Resources/      Info.plist、Assets.xcassets（AppIcon + AccentColor）
```

## 登录（免费账号扫码登录，2026-11-26）

- 设置 → 账号：网易云 / QQ 音乐扫码登录（官方 App 扫码），不存密码，不卖会员。
- 网易：unikey → 二维码 → 轮询（801 等待 / 802 已扫 / 803 成功带 cookie / 800 过期）→
  `/api/nuser/account/get` 取资料；QQ：ptqrshow 取图 + qrsig → ptqrlogin 轮询
  （ptuiCB '66' 等待 / '67' 已扫 / '0' 成功 / '65' 过期，hash33 算 ptqrtoken，
  成功后跟一次跳转链接收齐 cookie）→ 资料页取昵称头像（不通就用扫码回调的昵称 + qlogo 头像兜底）。
- 会话存钥匙串（通用密码项，account = 平台；Linux 测试宿主走 UserDefaults 后备），
  启动恢复：网易走服务端校验（明确拒绝才清，网络瞬断不断登录），QQ 走结构检查（uin + skey）。
  180 天软过期。退出登录清钥匙串 + 内存态。
- 取流接线：登录后网易 eapi 请求带 Cookie 头，QQ vkey 请求带真实 uin + Cookie 头，
  服务端按账号给档位；未登录时请求与匿名时一字不差（降档 + 解锁照旧）。
- 验证：Linux harness（`~/workspace/.tmp/haomusic-login-harness/`）**100 项全过**：
  扫码状态机、ptqrtoken（hash33 手算向量）、Cookie 解析/合并、登录解析（unikey/二维码/check/资料、
  ptuiCB/资料页）、会话编解码与存储往返、登录/匿名请求差别（Cookie 头有无、uin "0" 与真实 uin）、
  管理器恢复删除路径与退出。harness 抓到 2 个真 bug：ptqrtoken 整数溢出 trap（改 wrapping 运算）、
  ptuiCB 非成功状态只有 5 个参数（改 >= 5 + trim）。
- **未验**：真扫码登录（只能在真机上用官方 App 扫）、登录后高档位取流（需国内真机或登录后验证）、
  Xcode 构建（本机无 Xcode，GitHub Actions 第一轮排不到 macOS 机器，Bitrise 备用）。

## 构建

- 需要 Xcode 26+、macOS；iOS 16+ 真机或模拟器。
- 打开 `HAoMusic.xcodeproj`，选 HAoMusic scheme，Run。
- 签名：`CODE_SIGN_STYLE = Automatic`，首次构建需在 Xcode 里选自己的 Team。
- 本 Linux VM 无 Xcode：`swiftc -parse` 36 个文件全过；纯 Foundation + 解析层文件在 Linux 上真编过（见下）；**Xcode 构建未验，需在 Mac/CI 上跑**。

## 验证（2026-11-26，VM 实测）

| 检查 | 结果 |
| --- | --- |
| `swiftc -parse` 36 个 Swift 文件 | 零错误 |
| Linux harness：真实生产文件 + 假客户端（`~/workspace/.tmp/haomusic-source-harness/`，Combine 垫片只替 property-wrapper 机制） | **48 项全过**：MD5 向量、haoID 归一化/时长桶、合并去重与排序、降档链、码率估档位、解锁候选打分、失败记忆（硬错误记/超时不记/10 分钟过期/手动清）、瞬断重试一次、主源失败→另一平台句柄→解锁、本地直播、解锁竞速（最早胜出、启动顺序、超时不记、单源 8 秒超时实测约 8 秒）、合并搜索先出第一批再出完整结果 |
| 类型检查抓到的真问题（parse 扫不出来） | 已修：`FailureMemory.failedSources` 的 `Dictionary.Keys ?? []` 类型错；`HaoMusicService` 指定 init 不能委托（改 convenience）；`QQProvider` CgiGetVkey 的 `sip` 可选链漏 `?`；`PlaybackResolver` guard 里无用的 `client` 绑定 |
| 网易 eapi 加密 | 与参考实现逐字节一致（AES-ECB 测试向量已验）；但本机出口 IP 匿名取流全部 404（eapi/weapi 皆然，应是服务端地域/登录限制）——代码按降档 + 解锁走，**需在国内真机 / 免费账号登录后验证** |
| 网易搜索 | 通（code 200，真实歌曲） |
| QQ 搜索 | 通（真实 songmid/media_mid）；GetVkeyServer 匿名 500005（要登录）；CgiGetVkey 匿名通，返回 C400（128K m4a）——匿名只能到 128K，高档位需登录（后续再接） |
| 酷我搜索 | 通，但返回单引号 JS 字面量（用 JavaScriptCore 解析）；anti.s 转换未实测 |
| 酷狗 | mobilecdn.kugou.com 从本机不通；songsearch 返回空列表——按研究实现，**未在 VM 验证**，失败即跳过 |
| Xcode 构建 | **未验**（本机无 Xcode，需 Mac/CI） |
| 真机播放 | **未验**（需 chen 的手机或国内真机） |

## 后续（不在本轮）

- 登录：网易/QQ 免费账号 QR 登录（每日推荐、私人 FM、歌单同步、心动模式）；登录后 QQ 高档位（F000/M800）与网易无损
- 均衡器、睡眠定时、下载离线
- 酷狗做主源搜索、汽水接入（待定）
- 网易匿名取流 404 的国内真机验证结果（决定是否保留匿名 eapi 路径）
