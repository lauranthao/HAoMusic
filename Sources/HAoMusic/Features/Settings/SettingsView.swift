import SwiftUI

/// 设置：v1 无登录，音质/均衡器等网络曲库相关项先占位，不放假开关。
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("播放") {
                    HStack {
                        Text("音质")
                        Spacer()
                        Text("网络曲库接入后可用")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("均衡器")
                        Spacer()
                        Text("后续接入")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0 (1)")
                            .foregroundStyle(.secondary)
                    }
                    Text("HAo Music — 参照 Kumone 设计的音乐应用。功能与界面参考学习，代码全部重写；不复制 Kumone 的源码与密钥。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("参照：github.com/missuo/kumone（LGPL-3.0）")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}
