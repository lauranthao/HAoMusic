import PhotosUI
import SwiftUI

#if os(iOS)

/// Pick a photo as the app background. The photo is copied into the app
/// sandbox (`Documents/wallpapers/`), so it survives restarts and the
/// photo-library permission is only needed while picking.
struct WallpaperSettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @StateObject private var loader = WallpaperImageLoader.shared
    @State private var photoItem: PhotosPickerItem?
    @State private var showingImportFailedAlert = false

    private var hasWallpaper: Bool { !settings.wallpaperCurrent.isEmpty }

    var body: some View {
        Form {
            Section {
                preview
                Toggle("使用壁纸", isOn: $settings.wallpaperEnabled)
                    .disabled(!hasWallpaper)
                Text("壁纸显示在推荐、精选、搜索、我的等页面的背景中，透过玻璃菜单栏可见。播放页保留封面配色，壁纸在后方透出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("从相册选择", systemImage: "photo")
                }
                .onChange(of: photoItem) { _, item in
                    guard let item else { return }
                    importPhoto(item)
                }
                if hasWallpaper {
                    Button("关闭壁纸", role: .destructive) {
                        settings.wallpaperEnabled = false
                        loader.refresh()
                    }
                    Button("删除壁纸", role: .destructive) {
                        WallpaperStore.delete(settings.wallpaperCurrent)
                        settings.wallpaperCurrent = ""
                        settings.wallpaperEnabled = false
                        loader.refresh()
                    }
                }
            } footer: {
                Text("关闭后恢复默认背景，照片文件保留，可随时重新开启。删除会连同照片文件一起移除。")
            }
        }
        .navigationTitle("壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .alert("导入失败", isPresented: $showingImportFailedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("这张图片无法导入，请换一张试试。")
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = loader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("当前壁纸")
        } else if hasWallpaper {
            placeholderRow(
                systemImage: "photo.badge.exclamationmark",
                title: "壁纸找不到了",
                subtitle: "之前选的壁纸文件已不在，请重新选择一张。"
            )
        } else {
            placeholderRow(
                systemImage: "photo",
                title: "还没有壁纸",
                subtitle: "从相册选一张照片作为应用背景。"
            )
        }
    }

    private func placeholderRow(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        photoItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let name = WallpaperStore.importImage(data: data) else {
                showingImportFailedAlert = true
                return
            }
            let previous = settings.wallpaperCurrent
            settings.wallpaperCurrent = name
            settings.wallpaperEnabled = true
            if !previous.isEmpty, previous != name {
                WallpaperStore.delete(previous)
            }
            loader.refresh()
        }
    }
}

#endif
