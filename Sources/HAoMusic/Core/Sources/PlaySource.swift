import Foundation

/// 播放入口：每次播放都要记录从哪里点进来的（chen 的播放规则）。
enum PlaySource: String, Codable, Sendable {
    case search
    case home
    case recent
    case liked
    case library
    case queue
    case unknown

    var label: String {
        switch self {
        case .search: return "搜索"
        case .home: return "首页"
        case .recent: return "最近播放"
        case .liked: return "我喜欢的"
        case .library: return "资料库"
        case .queue: return "队列"
        case .unknown: return "未知"
        }
    }
}
