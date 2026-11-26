#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// 扫码登录页：二维码图片 + 状态文案 + 过期刷新。HAo 自己的界面，
/// 不抄 Kumone/Coda 的登录屏。
/// 流程：进页申请二维码 → 每 2 秒轮询一次 → 已确认就存会话关页；
/// 过期点刷新重新申请；取消直接关页（轮询任务随页销毁）。
struct LoginQRView: View {
    let provider: MusicProvider

    @EnvironmentObject private var loginManager: LoginSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: Data?
    @State private var status: QRLoginStatus = .waiting
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let qrImage, let uiImage = UIImage(data: qrImage) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView()
                        .frame(width: 220, height: 220)
                }
                Text(status.label)
                    .font(.headline)
                Text(hintText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if status == .expired {
                    Button("刷新二维码") {
                        Task { await requestQR() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("扫码登录 · \(provider.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await requestQR() }
            .onDisappear { pollTask?.cancel() }
        }
    }

    private var hintText: String {
        switch provider {
        case .netease: return "打开网易云音乐 App，扫一扫上方二维码"
        case .qq: return "打开 QQ 音乐 App，扫一扫上方二维码"
        default: return "打开官方 App 扫码登录"
        }
    }

    private func requestQR() async {
        errorText = nil
        status = .waiting
        qrImage = nil
        pollTask?.cancel()
        do {
            switch provider {
            case .netease:
                let (unikey, image) = try await loginManager.neteaseQR()
                qrImage = image
                pollTask = Task { await pollNetease(unikey: unikey) }
            case .qq:
                let (image, qrsig) = try await loginManager.qqQR()
                qrImage = image
                pollTask = Task { await pollQQ(qrsig: qrsig) }
            default:
                errorText = "该平台暂不支持扫码登录"
            }
        } catch {
            errorText = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    private func pollNetease(unikey: String) async {
        while !Task.isCancelled {
            do {
                let (next, cookie) = try await loginManager.neteasePoll(unikey: unikey)
                status = next
                if next == .confirmed, let cookie {
                    _ = try await loginManager.completeNeteaseLogin(cookie: cookie)
                    dismiss()
                    return
                }
                if next.isTerminal { return }
            } catch {
                // 单次轮询失败不打断：网络抖动就等下一轮。
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func pollQQ(qrsig: String) async {
        while !Task.isCancelled {
            do {
                let result = try await loginManager.qqPoll(qrsig: qrsig)
                status = result.status
                if result.status == .confirmed, let cookies = result.cookies {
                    _ = try await loginManager.completeQQLogin(
                        cookies: cookies, nickname: result.nickname)
                    dismiss()
                    return
                }
                if result.status.isTerminal { return }
            } catch {
                // 单次轮询失败不打断：网络抖动就等下一轮。
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
