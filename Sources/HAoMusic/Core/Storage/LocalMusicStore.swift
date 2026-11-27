import AVFoundation
import Foundation

/// One audio file the user imported from their own device, plus the Track the
/// UI plays. Negative ids never collide with NetEase song ids, which is how
/// the player tells a local track apart from a streamed one.
///
/// Files are stored under their original name (suffixed on collision), and
/// deduped by name + size — the way other music apps do it. There is no
/// content hash: hashing a whole file at import time is what stalled the
/// import (build 6, chen 2026-11-27). `durationMS` is 0 until the
/// background metadata fill-in reads it; the player falls back to the
/// item's own length in that case.
struct LocalMusicEntry: Codable, Hashable, Identifiable {
    var id: Int
    var fileName: String
    var fileSize: Int
    var title: String
    var artist: String
    var album: String
    var durationMS: Int
    var dateAdded: Date
    /// Set for songs that live in a linked folder (LX/歌一刀 model): the
    /// path inside that folder, played in place, never copied. Nil means
    /// the file was copied into Documents/LocalMusic (the old import).
    /// Old index files decode with nil, so they keep working.
    var relativePath: String? = nil

    var track: Track {
        Track(localID: id, name: title, artist: artist, album: album, durationMS: durationMS)
    }
}

/// The user's imported songs. Files are copied into Documents/LocalMusic so
/// they keep playing after the picked file moves or is deleted, and an
/// index.json next to them rebuilds the list on launch. No account, no
/// network, no server: this is the phone's own music.
@MainActor
final class LocalMusicStore: ObservableObject {
    static let shared = LocalMusicStore()

    struct ImportResult {
        var imported = 0
        var duplicates = 0
        /// Rejected by extension. The extensions are reported so a failed
        /// import says what it was, instead of a bare "unsupported".
        var unsupported = 0
        var unsupportedExtensions: [String] = []
        /// The file could not be copied or read (permissions, download,
        /// duration). Kept apart from unsupported: a different problem.
        /// The reasons carry the underlying error text, so a failed import
        /// says WHY instead of a bare "无法读取" (build 10, chen 2026-11-27:
        /// four builds failed and nobody could say what happened).
        var unreadable = 0
        var unreadableReasons: [String] = []
    }

    /// Every audio format the iPhone itself can decode (AVFoundation):
    /// MP3, AAC/M4A/M4B/MP4, FLAC, WAV, AIFF, CAF and AMR. Anything
    /// outside this (APE, OGG Vorbis, Opus in its own .opus container,
    /// WMA, DSD, ...) has no iOS decoder and cannot play even if
    /// imported, so it stays rejected with its extension named in the
    /// toast.
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "m4b", "mp4",
        "flac", "wav", "aiff", "aif", "aifc", "caf", "amr",
    ]

    @Published private(set) var entries: [LocalMusicEntry] = []

    /// Import progress for the button label: (files done, files picked).
    /// Nil when no import is running.
    @Published private(set) var importProgress: (done: Int, total: Int)?

    /// Newest first.
    var tracks: [Track] { entries.map(\.track) }

    private let directory: URL?
    private var indexURL: URL? { directory?.appendingPathComponent("index.json") }

    /// The folder the user linked (LX/歌一刀 model): songs are scanned
    /// from it and played in place, never copied. iOS has no
    /// security-scoped bookmark API (that is macOS-only); instead the
    /// document picker grant is re-activated by calling
    /// startAccessingSecurityScopedResource on the stored URL, and the
    /// scope is held for the whole app run once resolved.
    private static let folderURLKey = "localMusicLinkedFolderURL"
    private static let folderNameKey = "localMusicLinkedFolderName"
    private var linkedFolderURL: URL?
    @Published private(set) var linkedFolderName: String?

    private init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LocalMusic", isDirectory: true)
        loadIndex()
        resolveLinkedFolder()
    }

    /// Links a folder the user picked in the Files app: the folder is
    /// scanned for audio (LX's readDir, one level, no recursion) and its
    /// songs join the list by path — no copy, no per-file wait. The
    /// folder's URL is persisted, so the link survives relaunches.
    /// Returns how many songs joined, for the toast.
    func linkFolder(_ url: URL) async -> ImportResult {
        var result = ImportResult()
        // A new link replaces the old one: its entries leave the list
        // (the files themselves are never touched).
        if linkedFolderURL != nil { unlinkFolder() }
        guard url.startAccessingSecurityScopedResource() else {
            result.unreadable = 1
            result.unreadableReasons = ["文件夹授权失败"]
            return result
        }
        linkedFolderURL = url
        linkedFolderName = url.lastPathComponent
        UserDefaults.standard.set(url.absoluteString, forKey: Self.folderURLKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.folderNameKey)
        result.imported = scanLinkedFolder()
        if !entries.isEmpty { saveIndex() }
        return result
    }

    /// Drops the folder link. The folder's songs leave the list; the
    /// files themselves are never touched, and copied songs stay.
    func unlinkFolder() {
        // Balance the single scope held since launch (linkFolder or
        // resolveLinkedFolder started it once).
        linkedFolderURL?.stopAccessingSecurityScopedResource()
        linkedFolderURL = nil
        linkedFolderName = nil
        UserDefaults.standard.removeObject(forKey: Self.folderURLKey)
        UserDefaults.standard.removeObject(forKey: Self.folderNameKey)
        entries.removeAll { $0.relativePath != nil }
        saveIndex()
    }

    /// Re-activates the stored folder's picker grant and holds its scope
    /// for the app run, then scans the folder once. If the folder is gone
    /// or its grant was revoked, the link and its songs drop out.
    /// Returns how many songs joined the list in this scan.
    @discardableResult
    private func resolveLinkedFolder() -> Int {
        guard let urlString = UserDefaults.standard.string(forKey: Self.folderURLKey),
              let url = URL(string: urlString),
              url.startAccessingSecurityScopedResource() else {
            dropLinkedFolderState()
            return 0
        }
        linkedFolderURL = url
        linkedFolderName = UserDefaults.standard.string(forKey: Self.folderNameKey) ?? url.lastPathComponent
        let joined = scanLinkedFolder()
        if joined > 0 || entries.contains(where: { $0.relativePath != nil }) { saveIndex() }
        return joined
    }

    /// Forgets the link and its songs without touching the files. Used
    /// when the stored folder can no longer be opened.
    private func dropLinkedFolderState() {
        linkedFolderURL = nil
        linkedFolderName = nil
        UserDefaults.standard.removeObject(forKey: Self.folderURLKey)
        UserDefaults.standard.removeObject(forKey: Self.folderNameKey)
        if entries.contains(where: { $0.relativePath != nil }) {
            entries.removeAll { $0.relativePath != nil }
            saveIndex()
        }
    }

    /// One-level scan of the linked folder (LX's readDir): audio files
    /// join the list by relative path with their filename as the title,
    /// reusing ids for files already known; vanished files drop out.
    /// Returns how many songs joined. iCloud files get their download
    /// kicked off in the background so they are local by play time.
    @discardableResult
    private func scanLinkedFolder() -> Int {
        guard let folder = linkedFolderURL else { return 0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var joined = 0
        var nextID = (entries.map(\.id).min() ?? 0) - 1
        var fresh: [LocalMusicEntry] = []
        for name in names where Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) {
            if let existing = entries.first(where: { $0.relativePath == name }) {
                fresh.append(existing)
                continue
            }
            let url = folder.appendingPathComponent(name)
            if FileManager.default.isUbiquitousItem(at: url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? Int ?? 0
            let added = attrs?[.creationDate] as? Date ?? Date()
            fresh.append(LocalMusicEntry(id: nextID, fileName: name, fileSize: size,
                                         title: (name as NSString).deletingPathExtension,
                                         artist: "", album: "", durationMS: 0, dateAdded: added,
                                         relativePath: name))
            nextID -= 1
            joined += 1
        }
        entries = (entries.filter { $0.relativePath == nil } + fresh).sorted { $0.dateAdded > $1.dateAdded }
        if joined > 0 { fillMetadata(for: fresh.filter { $0.durationMS == 0 }) }
        return joined
    }

    func isLocal(_ trackID: Int) -> Bool {
        entries.contains { $0.id == trackID }
    }

    /// The on-disk file for a local track, or nil when the entry or the file
    /// is gone. Folder entries resolve to the original file inside the
    /// linked folder (the scope is held for the app run); copied entries
    /// resolve inside Documents/LocalMusic. The player treats nil as
    /// "not a local track".
    func fileURL(for trackID: Int) -> URL? {
        guard let entry = entries.first(where: { $0.id == trackID }),
              let url = url(for: entry),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func url(for entry: LocalMusicEntry) -> URL? {
        if let relativePath = entry.relativePath {
            return linkedFolderURL?.appendingPathComponent(relativePath)
        }
        return directory?.appendingPathComponent(entry.fileName)
    }

    /// Copies the picked files in — and nothing else. Import is only a
    /// copy, the way other music apps do it: the file lands in the list
    /// immediately with its filename as the title, and duration + tags are
    /// filled in afterwards in the background. The old import hashed the
    /// whole file and probed it with AVAsset before the song appeared, so
    /// one slow file (a download still coming down from iCloud, a tag
    /// AVAsset would not read) stalled the whole batch with the button
    /// stuck on "正在导入…" (build 6, chen 2026-11-27). A copy that stalls
    /// is abandoned after 30 seconds instead of hanging the import.
    func importFiles(_ urls: [URL]) async -> ImportResult {
        guard let directory else { return ImportResult() }
        var result = ImportResult()
        var nextID = (entries.map(\.id).min() ?? 0) - 1
        var newEntries: [LocalMusicEntry] = []
        importProgress = (0, urls.count)
        for (index, url) in urls.enumerated() {
            importProgress = (index, urls.count)
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else {
                result.unsupported += 1
                let shown = ext.isEmpty ? "无后缀" : ".\(ext)"
                if !result.unsupportedExtensions.contains(shown) {
                    result.unsupportedExtensions.append(shown)
                }
                continue
            }
            switch await Self.copyIn(from: url, directory: directory, id: nextID,
                                     existing: entries + newEntries) {
            case .ready(let entry):
                nextID -= 1
                newEntries.append(entry)
                result.imported += 1
            case .duplicate:
                result.duplicates += 1
            case .unreadable(let reason):
                result.unreadable += 1
                if let reason, !reason.isEmpty, !result.unreadableReasons.contains(reason) {
                    result.unreadableReasons.append(reason)
                }
            }
        }
        importProgress = nil
        if !newEntries.isEmpty {
            entries = (newEntries + entries).sorted { $0.dateAdded > $1.dateAdded }
            saveIndex()
            fillMetadata(for: newEntries)
        }
        return result
    }

    /// One audio file sent to the app from elsewhere (WeChat/QQ "用其他
    /// 应用打开", Files "共享"): the system drops it in Documents/Inbox
    /// and the app imports it the same way as a picked file, then clears
    /// the Inbox copy so it does not pile up. The result is toasted here
    /// because this path has no view of its own to report it.
    func importOpened(_ url: URL) async {
        let result = await importFiles([url])
        reportImport(result)
        if result.imported > 0 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// One line per outcome, with the real reason when a file could not
    /// be read — the same wording from the picker path and the Open-In
    /// path, so a failure can be quoted back in one sentence.
    func reportImport(_ result: ImportResult) {
        var parts: [String] = []
        if result.imported > 0 { parts.append("已导入 \(result.imported) 首") }
        if result.duplicates > 0 { parts.append("\(result.duplicates) 首已在本地音乐中") }
        if result.unsupported > 0 {
            let exts = result.unsupportedExtensions.prefix(3).joined(separator: "、")
            parts.append("\(result.unsupported) 个文件不支持（\(exts) 格式不能播）")
        }
        if result.unreadable > 0 {
            var text = "\(result.unreadable) 个文件无法读取"
            if let reason = result.unreadableReasons.first { text += "（\(reason)）" }
            parts.append(text)
        }
        if !parts.isEmpty { ToastCenter.shared.show(parts.joined(separator: "，")) }
    }

    /// Deletes the files and their entries. A song playing right now keeps
    /// playing from its open handle until it ends; the next resolve skips it.
    /// Folder songs only leave the list — the user's original file is
    /// never deleted.
    func delete(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let entry = entries.first(where: { $0.id == id }),
                  entry.relativePath == nil,
                  let url = directory?.appendingPathComponent(entry.fileName) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        entries.removeAll { ids.contains($0.id) }
        saveIndex()
    }

    private func loadIndex() {
        guard let directory else { return }
        var saved: [LocalMusicEntry] = []
        if let indexURL,
           let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([LocalMusicEntry].self, from: data) {
            saved = decoded
        }
        let loadedCount = saved.count
        // A file deleted outside the app (Files, Finder sharing) drops its entry.
        // Folder entries live outside this directory; their existence is
        // checked by scanLinkedFolder, not here.
        saved.removeAll { entry in
            entry.relativePath == nil &&
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.fileName).path)
        }
        // The other direction: audio dropped into the folder (Finder, iTunes
        // file sharing) joins the list on launch, like other music apps'
        // folder scan. Dropped files keep their real names; unknown files
        // get their filename as the title and metadata filled in later.
        let known = Set(saved.map(\.fileName))
        var adopted: [LocalMusicEntry] = []
        var nextID = (saved.map(\.id).min() ?? 0) - 1
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) {
                guard !known.contains(name) else { continue }
                let url = directory.appendingPathComponent(name)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = attrs?[.size] as? Int ?? 0
                let added = attrs?[.creationDate] as? Date ?? Date()
                adopted.append(LocalMusicEntry(id: nextID, fileName: name, fileSize: size,
                                               title: (name as NSString).deletingPathExtension,
                                               artist: "", album: "", durationMS: 0, dateAdded: added))
                nextID -= 1
            }
        }
        entries = (saved + adopted).sorted { $0.dateAdded > $1.dateAdded }
        if !adopted.isEmpty || saved.count != loadedCount { saveIndex() }
        if !adopted.isEmpty { fillMetadata(for: adopted) }
    }

    private func saveIndex() {
        guard let directory, let indexURL,
              let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    private enum PreparedImport {
        case ready(LocalMusicEntry)
        case duplicate
        /// The underlying error text, when there is one.
        case unreadable(String?)
    }

    /// Copies one picked file in under its own name. The security scope is
    /// held only for the copy itself, synchronously, before any await.
    ///
    /// The copy goes through NSFileCoordinator and streams the bytes in,
    /// instead of a bare `FileManager.copyItem`: a picked URL is often a
    /// file-provider placeholder (iCloud, a cloud drive, another app's
    /// folder in the Files picker), and a raw copyItem across that
    /// boundary fails or reads nothing while a coordinated read asks the
    /// provider to materialise the file first (build 10, chen 2026-11-27:
    /// four builds of import failed on his phone). Streaming also keeps a
    /// big FLAC from sitting whole in memory. The copy is abandoned after
    /// 180 seconds (was 30: a big FLAC trickling down over a slow
    /// connection needs longer than that), and the real error is kept so
    /// the toast can say why instead of a bare "无法读取".
    private nonisolated static func copyIn(from url: URL, directory: URL, id: Int,
                                           existing: [LocalMusicEntry]) async -> PreparedImport {
        let sourceName = sanitizedFileName(url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Size inside the scope: outside it the read fails and the size
        // is 0, which breaks the name+size dedup.
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        // A size of 0 means the size could not be read at all (provider
        // item not materialised yet); it must never count as a duplicate.
        if sourceSize > 0,
           existing.contains(where: { $0.fileName == sourceName && $0.fileSize == sourceSize }) {
            return .duplicate
        }
        let fileName = uniqueFileName(sourceName, taken: Set(existing.map(\.fileName)))
        let dest = directory.appendingPathComponent(fileName)
        // A file picked from iCloud Drive (or another cloud folder) may
        // not be downloaded yet; a plain copy then fails at once, and a
        // big FLAC is exactly the file that is usually still in the
        // cloud. Ask the system to fetch it and wait for the download
        // (90s cap) before copying.
        if FileManager.default.isUbiquitousItem(at: url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                    .ubiquitousItemDownloadingStatus
                if status == .current || status == .downloaded || status == nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        final class ErrorBox: @unchecked Sendable { var error: Error? }
        let box = ErrorBox()
        let copied = await withTimeout(180, fallback: false) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try coordinatedCopy(from: url, to: dest)
                return true
            } catch {
                box.error = error
                return false
            }
        }
        guard copied else {
            // A timed-out copy may still be writing in the background;
            // removing the destination keeps a half-copied file out of the
            // library (the write lands in an unlinked inode and frees).
            try? FileManager.default.removeItem(at: dest)
            return .unreadable(box.error?.localizedDescription ?? "拷贝超时")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? sourceSize
        let entry = LocalMusicEntry(id: id, fileName: fileName, fileSize: size,
                                    title: url.deletingPathExtension().lastPathComponent,
                                    artist: "", album: "", durationMS: 0, dateAdded: Date())
        return .ready(entry)
    }

    /// Streams one file in under coordination: the read asks the file
    /// provider (iCloud, cloud drives, another app's folder) to
    /// materialise the item first, which a bare copyItem does not do
    /// reliably. Throws the underlying error so the caller can report it.
    private nonisolated static func coordinatedCopy(from url: URL, to dest: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            do {
                guard let input = InputStream(url: readURL) else {
                    throw CocoaError(.fileReadUnknown)
                }
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                guard let output = OutputStream(url: dest, append: false) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                input.open()
                output.open()
                defer { input.close(); output.close() }
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                while input.hasBytesAvailable {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
                    if count == 0 { break }
                    var written = 0
                    while written < count {
                        let n = buffer.withUnsafeBytes {
                            output.write($0.baseAddress!.assumingMemoryBound(to: UInt8.self) + written,
                                         maxLength: count - written)
                        }
                        if n <= 0 { throw output.streamError ?? CocoaError(.fileWriteUnknown) }
                        written += n
                    }
                }
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
    }

    private nonisolated static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名音频" : cleaned
    }

    private nonisolated static func uniqueFileName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Runs work with a time limit; on timeout the work is cancelled and
    /// the fallback is returned. The cancelled work may still finish in the
    /// background; callers must not depend on its result afterwards.
    private nonisolated static func withTimeout<T>(_ seconds: UInt64, fallback: T,
                                                   work: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return fallback
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Reads duration + tags for freshly imported songs, one at a time, in
    /// the background. Best-effort: a file whose tags cannot be read keeps
    /// its filename as the title, and import never waits for this. Each
    /// file gets 10 seconds; a stalled read is skipped, not retried.
    private func fillMetadata(for fresh: [LocalMusicEntry]) {
        // Resolve the URLs now (folder entries need the linked folder
        // URL); the background reads only need the URLs, not the store.
        let jobs = fresh.compactMap { entry -> (Int, URL)? in
            guard let url = url(for: entry) else { return nil }
            return (entry.id, url)
        }
        guard !jobs.isEmpty else { return }
        Task {
            for (id, url) in jobs {
                if Task.isCancelled { return }
                guard let meta = await Self.readMetadata(of: url) else { continue }
                applyMetadata(id: id, title: meta.title, artist: meta.artist,
                              album: meta.album, durationMS: meta.durationMS)
            }
        }
    }

    private func applyMetadata(id: Int, title: String?, artist: String?, album: String?, durationMS: Int?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { entries[i].title = title }
        if let artist, !artist.isEmpty { entries[i].artist = artist }
        if let album, !album.isEmpty { entries[i].album = album }
        if let durationMS, durationMS > 0 { entries[i].durationMS = durationMS }
        saveIndex()
    }

    private nonisolated static func readMetadata(of url: URL) async -> (title: String?, artist: String?, album: String?, durationMS: Int?)? {
        await withTimeout(10, fallback: nil) {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.seconds.isFinite, duration.seconds > 0 else { return nil }
            let metadata = try? await asset.load(.commonMetadata)
            return (metadataValue(.commonIdentifierTitle, in: metadata),
                    metadataValue(.commonIdentifierArtist, in: metadata),
                    metadataValue(.commonIdentifierAlbumName, in: metadata),
                    Int(duration.seconds * 1000))
        }
    }

    private nonisolated static func metadataValue(_ identifier: AVMetadataIdentifier,
                                                  in metadata: [AVMetadataItem]?) -> String? {
        guard let metadata else { return nil }
        return AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
            .first?.stringValue
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
