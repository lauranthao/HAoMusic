import SwiftUI
import UniformTypeIdentifiers

/// 资料库：本地音频（可导入/删除）+ 最近播放。
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerService
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("本地音频") {
                    if library.localTracks.isEmpty {
                        Text("还没有本地音频 — 点右上角 + 导入。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.localTracks) { track in
                            TrackRow(track: track, onPlay: {
                                if let index = library.localTracks.firstIndex(of: track) {
                                    player.play(tracks: library.localTracks, startAt: index)
                                }
                                library.recordPlayed(track)
                            })
                            .swipeActions {
                                Button(role: .destructive, action: { library.removeLocalTrack(track) }) {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                Section("最近播放") {
                    if library.recentTracks.isEmpty {
                        Text("还没有播放记录")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.recentTracks) { track in
                            Text(track.title).font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("资料库")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showImporter = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
                AudioImportPicker { url in
                    importAudio(from: url)
                }
            }
            .alert(
                "导入失败",
                isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    /// 把选中的音频拷进 Documents/Imported，再登记进本地曲库。
    /// 时长不在导入时读：播放时由 PlayerService 从 AVPlayerItem 读到。
    private func importAudio(from sourceURL: URL) {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let importedDir = documents.appendingPathComponent("Imported", isDirectory: true)
        do {
            try fileManager.createDirectory(at: importedDir, withIntermediateDirectories: true)
            let destination = importedDir.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            library.addLocalTrack(Track.localFile(url: destination))
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// 系统文件选择器（只选音频）。delegate 回调在主线程，用 assumeIsolated 调回 SwiftUI 闭包。
struct AudioImportPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            MainActor.assumeIsolated {
                onPick(url)
            }
        }
    }
}
