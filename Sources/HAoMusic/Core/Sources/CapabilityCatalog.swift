import Foundation

/// 能力目录：哪个平台支持什么功能。不支持的功能 UI 直接隐藏，绝不发请求。
/// （思路借鉴 Coda 的能力目录；HAo 的能力划分按自己的两期计划来。）
struct MusicCapability: OptionSet, Sendable {
    let rawValue: Int

    static let search = MusicCapability(rawValue: 1 << 0)
    static let songURL = MusicCapability(rawValue: 1 << 1)
    static let lyrics = MusicCapability(rawValue: 1 << 2)
    static let playlist = MusicCapability(rawValue: 1 << 3)
    static let dailyRecommend = MusicCapability(rawValue: 1 << 4)
    static let fm = MusicCapability(rawValue: 1 << 5)
    static let download = MusicCapability(rawValue: 1 << 6)
}

enum CapabilityCatalog {
    /// 免登可用的能力。
    static func capabilities(for provider: MusicProvider) -> MusicCapability {
        switch provider {
        case .netease, .qq:
            return [.search, .songURL, .lyrics]
        case .kugou:
            return [] // 酷狗只做解锁源，不做主源
        case .qishui:
            return [] // 占位，未接
        }
    }

    /// 需要登录后才有的能力（本期全部后置，不实现）。
    static func loginRequiredCapabilities(for provider: MusicProvider) -> MusicCapability {
        switch provider {
        case .netease, .qq:
            return [.playlist, .dailyRecommend, .fm, .download]
        case .kugou, .qishui:
            return []
        }
    }

    static func supports(_ capability: MusicCapability, provider: MusicProvider) -> Bool {
        capabilities(for: provider).contains(capability)
    }
}
