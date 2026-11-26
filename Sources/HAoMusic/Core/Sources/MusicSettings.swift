import Foundation

/// 音乐相关设置：目标音质、启用的音源、解锁开关、镜像地址。只存本机 UserDefaults。
@MainActor
final class MusicSettings: ObservableObject {
    @Published var targetQuality: AudioQuality {
        didSet { save() }
    }
    @Published var enabledProviders: Set<MusicProvider> {
        didSet { save() }
    }
    @Published var unlockEnabled: Bool {
        didSet { save() }
    }
    /// 用户自填的 pyncmd 兼容镜像地址；留空则不用。HAo 不内置任何第三方镜像地址。
    @Published var mirrorBaseURL: String {
        didSet { save() }
    }

    private let qualityKey = "haoMusic.targetQuality"
    private let providersKey = "haoMusic.enabledProviders"
    private let unlockKey = "haoMusic.unlockEnabled"
    private let mirrorKey = "haoMusic.mirrorBaseURL"

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: qualityKey),
           let quality = AudioQuality(rawValue: raw) {
            targetQuality = quality
        } else {
            // 默认极高（320K）：免费歌能播就播 320K，播不了自动降档。
            targetQuality = .exhigh
        }
        if let raws = defaults.stringArray(forKey: providersKey) {
            let providers = Set(raws.compactMap { MusicProvider(rawValue: $0) }.filter { $0.isFullProvider })
            enabledProviders = providers.isEmpty ? [.netease, .qq] : providers
        } else {
            enabledProviders = [.netease, .qq]
        }
        unlockEnabled = defaults.object(forKey: unlockKey) as? Bool ?? true
        mirrorBaseURL = defaults.string(forKey: mirrorKey) ?? ""
    }

    /// 合并搜索用的音源（按优先顺序）。
    var searchProviders: [MusicProvider] {
        MusicProvider.searchPriority.filter { enabledProviders.contains($0) }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(targetQuality.rawValue, forKey: qualityKey)
        defaults.set(enabledProviders.map { $0.rawValue }, forKey: providersKey)
        defaults.set(unlockEnabled, forKey: unlockKey)
        defaults.set(mirrorBaseURL, forKey: mirrorKey)
    }
}
