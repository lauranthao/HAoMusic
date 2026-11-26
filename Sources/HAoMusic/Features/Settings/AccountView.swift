import SwiftUI

extension MusicProvider: Identifiable {
    var id: String { rawValue }
}

/// 账号页：两个平台的登录态 + 扫码登录入口 + 退出登录。
/// 只做免费账号登录：不卖会员，不推 VIP。
struct AccountView: View {
    @EnvironmentObject private var loginManager: LoginSessionManager
    @State private var loginPlatform: MusicProvider?
    @State private var confirmLogout: MusicProvider?

    var body: some View {
        List {
            ForEach([MusicProvider.netease, .qq], id: \.self) { provider in
                Section(provider.displayName) {
                    if let profile = loginManager.profile(for: provider) {
                        HStack(spacing: 12) {
                            avatarView(for: profile)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.nickname)
                                    .font(.headline)
                                Text("ID \(profile.userID)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("已登录")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Button("退出登录", role: .destructive) {
                            confirmLogout = provider
                        }
                    } else {
                        Button("扫码登录") { loginPlatform = provider }
                        Text("用官方 App 扫码登录；只存登录凭证，不存密码。免费账号即可。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("登录后取流按账号的档位来；没登录或播不了时，照旧自动降档、走解锁。退出后回到未登录状态。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("账号")
        .sheet(item: $loginPlatform) { provider in
            LoginQRView(provider: provider)
        }
        .alert(
            "退出登录？",
            isPresented: Binding(
                get: { confirmLogout != nil },
                set: { if !$0 { confirmLogout = nil } }
            )
        ) {
            Button("退出登录", role: .destructive) {
                if let provider = confirmLogout {
                    loginManager.logout(provider: provider)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后将回到未登录状态，播放按匿名规则走。")
        }
    }

    private func avatarView(for profile: AccountProfile) -> some View {
        Group {
            if let urlString = profile.avatarURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }
}
