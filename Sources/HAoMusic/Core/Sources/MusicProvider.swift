import Foundation

/// 音源平台注册表（HAo 自己的划分）。
///
/// 第一期完整平台只有网易 + QQ；酷狗只做解锁源（不做主源搜索），汽水是占位。
/// 参照 Coda 也有平台枚举，但 HAo 的能力划分不同：酷狗不进主源，汽水后加。
enum MusicProvider: String, CaseIterable, Codable, Hashable, Sendable {
    case netease
    case qq
    case kugou
    case qishui

    var displayName: String {
        switch self {
        case .netease: return "网易云"
        case .qq: return "QQ 音乐"
        case .kugou: return "酷狗"
        case .qishui: return "汽水音乐"
        }
    }

    /// 合并搜索结果行里的小徽标。
    var badge: String {
        switch self {
        case .netease: return "网易"
        case .qq: return "QQ"
        case .kugou: return "酷狗"
        case .qishui: return "汽水"
        }
    }

    /// 能否作为主源（搜索 + 取流 + 歌词）。酷狗只做解锁，汽水未接。
    var isFullProvider: Bool {
        self == .netease || self == .qq
    }

    /// 合并搜索的平台优先顺序：网易 + QQ 优先（chen 2026-11-26 定）。
    static var searchPriority: [MusicProvider] { [.netease, .qq] }
}
