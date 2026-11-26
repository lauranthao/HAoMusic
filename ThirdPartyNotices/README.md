# 开源仓库与第三方参考索引

本目录汇总 HAo Music 使用或参考的全部开源仓库与第三方服务。各条目的详细说明见对应的说明文件。新增引用时，请同步更新本索引和对应说明。

## 1. 派生来源

| 仓库 | 许可证 | 说明 |
| --- | --- | --- |
| [missuo/kumone](https://github.com/missuo/kumone) | LGPL-3.0（[LICENSE-LGPL-3.0.txt](../LICENSE-LGPL-3.0.txt)） | HAo Music 的上游项目，应用主体。保留原作者版权。 |
| [Wow-CaiCai/Coda](https://github.com/Wow-CaiCai/Coda) | AGPL-3.0（[LICENSE](../LICENSE)） | QQ 音乐平台与灰歌并行解锁的参照。合并后的 HAo Music 按 AGPL-3.0 分发。 |

## 2. 集成或改编的代码

| 仓库 | 许可证 | 在 HAo Music 中的位置 | 说明文件 |
| --- | --- | --- | --- |
| [XIaodou0416/Beans-Music](https://github.com/XIaodou0416/Beans-Music) | MIT | QQ 音乐 / 酷狗 API 与登录（经 Kumone / Coda 改编） | [Beans-Music.md](Beans-Music.md) |
| [youshen2/MeloX](https://github.com/youshen2/MeloX) | GPL-3.0（[LICENSE-GPL-3.0.txt](../LICENSE-GPL-3.0.txt)） | 播放器竖屏封面、流体背景、歌词列与歌词模型（经 Coda 改编后原样引入） | [MeloX.md](MeloX.md) |

## 3. 仅参考接口协议（未复制源码）

以下仓库仅用于核对接口名、请求字段与返回结构，Swift 实现为独立编写。

| 仓库 | 许可证 | 参考内容 | 记录位置 |
| --- | --- | --- | --- |
| [jsososo/QQMusicApi](https://github.com/jsososo/QQMusicApi) | GPL-3.0 | QQ 音乐歌单、歌手关注、专辑接口 | [QQMusicProtocolReferences.md](QQMusicProtocolReferences.md) |
| [Yyyangshenghao/simple-music](https://github.com/Yyyangshenghao/simple-music) | GPL-3.0 | 同上 | [QQMusicProtocolReferences.md](QQMusicProtocolReferences.md) |
| [pdone/lx-music-source](https://github.com/pdone/lx-music-source) | — | 洛雪音源解析接口（仅参考；未复制脚本、未调用其接口） | 本索引（见下） |

## 4. 第三方解析服务（运行时调用，未复制代码）

灰歌解锁时调用的第三方公开接口；调用代码是 HAo 独立编写的。

| 服务 | 用途 |
| --- | --- |
| pyncmd 镜像（`music-api.gdstudio.xyz`） | 镜像音源匹配与取流 |
| haitangw 解析服务（`musicapi.haitangw.net` / `music.haitangw.cc`） | 解析服务音源匹配与取流 |

## 洛雪音源说明

[pdone/lx-music-source](https://github.com/pdone/lx-music-source) 是 LX Music 应用的 JavaScript 音源脚本集合，仅作为“洛雪音源解析接口”列入参考。HAo Music 没有 JavaScript 音源运行时，未复制其中任何脚本，也未调用其接口——镜像与解析服务（上表第 4 节）已覆盖同一用途。另请注意：该仓库自述其中一个脚本（“LX 独家音源”）含有恶意逻辑（执行 `shutdown` 强制关机），切勿导入。
