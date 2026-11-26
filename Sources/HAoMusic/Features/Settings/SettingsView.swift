import SwiftUI

/// 设置：账号、目标音质、音源开关、解锁开关、镜像地址。
/// 登录相关功能（每日推荐、电台、歌单同步）本期没有，不放假开关。
struct SettingsView: View {
    @EnvironmentObject private var settings: MusicSettings
    @EnvironmentObject private var loginManager: LoginSessionManager

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    NavigationLink("账号与登录") {
                        AccountView()
                    }
                    Text(accountSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("播放") {
                    Picker("目标音质", selection: $settings.targetQuality) {
                        ForEach(AudioQuality.allCases, id: \.self) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    Text("播不了目标音质时自动降档；只报实测档位。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("音源") {
                    ForEach(MusicProvider.allCases.filter { $0.isFullProvider }, id: \.self) { provider in
                        Toggle(provider.displayName, isOn: Binding(
                            get: { settings.enabledProviders.contains(provider) },
                            set: { on in
                                if on {
                                    settings.enabledProviders.insert(provider)
                                } else if settings.enabledProviders.count > 1 {
                                    settings.enabledProviders.remove(provider)
                                }
                            }
                        ))
                    }
                    Text("合并搜索只搜开启的音源；至少保留一个。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("解锁") {
                    Toggle("灰歌 / VIP 歌走解锁", isOn: $settings.unlockEnabled)
                    Text("主源播不了时，按镜像 → 酷狗 → 酷我并行竞速找替代音源。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("镜像地址（选填）", text: $settings.mirrorBaseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("pyncmd 兼容镜像地址，留空则不用。HAo 不内置任何第三方镜像地址。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0 (1)")
                            .foregroundStyle(.secondary)
                    }
                    Text("HAo Music — 参照 Kumone/Coda 设计的音乐应用。功能与界面参考学习，代码全部重写；不复制源码与密钥。合并搜索、第一个能播的立刻播是 HAo 自己的设计。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("参照：github.com/missuo/kumone（LGPL-3.0）、github.com/Wow-CaiCai/Coda（AGPL-3.0）")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }

    private var accountSummary: String {
        [MusicProvider.netease, .qq].map { provider in
            if let profile = loginManager.profile(for: provider) {
                return "\(provider.displayName)：已登录（\(profile.nickname)）"
            }
            return "\(provider.displayName)：未登录"
        }.joined(separator: " · ")
    }
}
