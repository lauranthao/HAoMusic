import SwiftUI
import UniformTypeIdentifiers

/// The user's own imported audio files. Same rows and layout as Downloads;
/// playback comes straight from disk, so no account or network is involved.
struct LocalMusicView: View {
    @ObservedObject private var store = LocalMusicStore.shared
    private let player = PlayerService.shared
    @State private var showImporter = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<Int> = []
    @State private var confirmRemoval = false
    @State private var pendingRemoval: Set<Int> = []
    @State private var isRemoving = false
    @State private var isImporting = false

    private var tracks: [Track] { store.tracks }

    var body: some View {
        TrackListScrollView(trackIDs: tracks.map(\.id), spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                if isSelecting { selectionHeader } else { header }

                if tracks.isEmpty {
                    EmptyStateView(icon: "music.note", title: "还没有本地歌曲",
                                   subtitle: "从文件 App 导入 MP3、FLAC 等音频文件，不用登录、不用联网就能听")
                        .frame(minHeight: 300)
                }
            }
        } rows: { layout in
            TrackListView(tracks: tracks, source: .none, selection: isSelecting ? $selectedIDs : nil,
                          layout: layout)
                .disabled(isRemoving)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            PlayerClearanceSpacer()
        }
        // NavigationStack keeps its previous page behind this destination.
        // Give the music page a surface so transparent scroll content cannot
        // show the previous list through it.
        .background(Platform.windowBackgroundColor)
        .navigationTitle(String(localized: "本地音乐"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isSelecting ? String(localized: "完成") : String(localized: "选择")) {
                    selectedIDs = []
                    isSelecting.toggle()
                }
                .disabled(isRemoving || (!isSelecting && tracks.isEmpty))
                .accessibilityIdentifier("select-local-music")
            }
        }
        .onChange(of: tracks.map(\.id)) { ids in
            selectedIDs.formIntersection(ids)
            if ids.isEmpty { isSelecting = false }
        }
        .alert("移除所选的 \(pendingRemoval.count) 首本地歌曲？", isPresented: $confirmRemoval) {
            Button("移除", role: .destructive) { removeSelection() }
            Button("取消", role: .cancel) {}
        } message: { Text("文件会从手机上删除。") }
        // The picker shows every file, not just the ones the system
        // recognises as audio: a song with no extension, or in a format the
        // system does not label audio (.ncm, .qmc, .kgm, ...), would
        // otherwise never even appear to be picked — and the import would
        // fail with nothing to say why (build 6, chen 2026-11-27). The
        // extension gate below still decides what can play; a rejected
        // file is reported by its extension.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importPicked(urls)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    ToastCenter.shared.show(error.localizedDescription)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("本地 \(tracks.count) 首")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            importButton
            playAllButton
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 12)
    }

    private var importButton: some View {
        Button { showImporter = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                Text(isImporting ? "正在导入…" : "导入")
            }
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.pressable)
        .disabled(isImporting)
        .accessibilityIdentifier("import-local-music")
    }

    private var playAllButton: some View {
        Button {
            player.play(tracks: tracks, source: .none)
        } label: {
            Label("播放全部", systemImage: "play.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.accentGradient, in: Capsule())
        }
        .buttonStyle(.pressable)
        .disabled(tracks.isEmpty)
    }

    private var selectionHeader: some View {
        HStack(spacing: 12) {
            Text("已选择 \(selectedIDs.count) 首")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            let ids = Set(tracks.map(\.id))
            let allSelected = !ids.isEmpty && ids.isSubset(of: selectedIDs)
            Button(allSelected ? String(localized: "取消全选") : String(localized: "全选")) {
                selectedIDs = allSelected ? [] : ids
            }
            .keyboardShortcut("a", modifiers: .command)
            .accessibilityIdentifier("select-all-local-music")
            Button("移除", role: .destructive) {
                pendingRemoval = selectedIDs.intersection(ids)
                confirmRemoval = true
            }
            .disabled(selectedIDs.isEmpty)
            .accessibilityIdentifier("remove-selected-local-music")
        }
        .font(.system(size: 12.5, weight: .medium))
        .buttonStyle(.borderless)
        .disabled(isRemoving)
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 12)
    }

    private func removeSelection() {
        let ids = pendingRemoval
        guard !ids.isEmpty else { return }
        isRemoving = true
        store.delete(ids: ids)
        selectedIDs.subtract(ids)
        pendingRemoval = []
        isRemoving = false
    }

    private func importPicked(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            let result = await store.importFiles(urls)
            var parts: [String] = []
            if result.imported > 0 { parts.append("已导入 \(result.imported) 首") }
            if result.duplicates > 0 { parts.append("\(result.duplicates) 首已在本地音乐中") }
            if result.unsupported > 0 {
                let exts = result.unsupportedExtensions.prefix(3).joined(separator: "、")
                parts.append("\(result.unsupported) 个文件不支持（\(exts) 格式不能播）")
            }
            if result.unreadable > 0 { parts.append("\(result.unreadable) 个文件无法读取") }
            if !parts.isEmpty { ToastCenter.shared.show(parts.joined(separator: "，")) }
        }
    }
}
