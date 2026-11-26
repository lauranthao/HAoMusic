import Foundation

/// 音质档位。目标档位只决定尝试顺序，不阻塞播放：
/// 播不了就自动降档（Kumone/Coda 的规则），直到有可播地址。
enum AudioQuality: String, CaseIterable, Codable, Comparable, Sendable {
    case standard
    case higher
    case exhigh
    case lossless
    case hires

    /// 档位高低（用于比较与排序）。
    private var rank: Int {
        switch self {
        case .standard: return 0
        case .higher: return 1
        case .exhigh: return 2
        case .lossless: return 3
        case .hires: return 4
        }
    }

    static func < (lhs: AudioQuality, rhs: AudioQuality) -> Bool {
        lhs.rank < rhs.rank
    }

    var label: String {
        switch self {
        case .standard: return "标准"
        case .higher: return "较高"
        case .exhigh: return "极高"
        case .lossless: return "无损"
        case .hires: return "Hi-Res"
        }
    }

    /// 播放页实际档位徽标：只报实测档位，不谎报。
    var bitrateLabel: String {
        switch self {
        case .standard: return "128K"
        case .higher: return "192K"
        case .exhigh: return "320K"
        case .lossless: return "无损"
        case .hires: return "Hi-Res"
        }
    }

    /// 网易 eapi 的 level 参数。
    var neteaseLevel: String { rawValue }

    /// 网易 eapi 的 encodeType 参数。
    var neteaseEncodeType: String {
        switch self {
        case .lossless, .hires: return "flac"
        default: return "mp3"
        }
    }

    /// 从目标档位往下的降档链（含目标档位本身）。
    static func downgradeChain(from target: AudioQuality) -> [AudioQuality] {
        allCases.filter { $0 <= target }.sorted(by: >)
    }

    /// QQ 取流的文件名前缀（档位 + songmid + media_mid + 扩展名）。
    func qqFilePrefix() -> (prefix: String, ext: String) {
        switch self {
        case .standard: return ("M500", ".mp3")
        case .higher: return ("M800", ".mp3")
        case .exhigh: return ("M800", ".mp3")
        case .lossless: return ("F000", ".flac")
        case .hires: return ("F000", ".flac")
        }
    }

    /// 按实测码率（bps）估档位：只报实测，不轻信服务器标注。
    static func fromBitrate(_ bitrate: Int) -> AudioQuality {
        switch bitrate {
        case 1_200_000...: return .hires
        case 700_000...: return .lossless
        case 300_000...: return .exhigh
        case 160_000...: return .higher
        default: return .standard
        }
    }
}
