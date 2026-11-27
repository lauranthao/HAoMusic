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
        var unreadable = 0
    }

    /// Every audio format the iPhone itself can decode (AVFoundation):
    /// MP3, AAC/M4A/M4B/MP4, FLAC, WAV, AIFF and CAF. Anything outside
    /// this (APE, OGG Vorbis, Opus in its own .opus container, WMA, DSD,
    /// ...) has no iOS decoder and cannot play even if imported, so it
    /// stays rejected with its extension named in the toast.
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "m4b", "mp4",
        "flac", "wav", "aiff", "aif", "aifc", "caf",
    ]

    @Published private(set) var entries: [LocalMusicEntry] = []

    /// Import progress for the button label: (files done, files picked).
    /// Nil when no import is running.
    @Published private(set) var importProgress: (done: Int, total: Int)?

    /// Newest first.
    var tracks: [Track] { entries.map(\.track) }

    private let directory: URL?
    private var indexURL: URL? { directory?.appendingPathComponent("index.json") }

    private init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LocalMusic", isDirectory: true)
        loadIndex()
    }

    func isLocal(_ trackID: Int) -> Bool {
        entries.contains { $0.id == trackID }
    }

    /// The on-disk file for a local track, or nil when the entry or the file
    /// is gone. The player treats nil as "not a local track".
    func fileURL(for trackID: Int) -> URL? {
        guard let entry = entries.first(where: { $0.id == trackID }),
              let url = directory?.appendingPathComponent(entry.fileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
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
            case .unsupported:
                result.unreadable += 1
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

    /// Deletes the files and their entries. A song playing right now keeps
    /// playing from its open handle until it ends; the next resolve skips it.
    func delete(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let entry = entries.first(where: { $0.id == id }),
               let url = directory?.appendingPathComponent(entry.fileName) {
                try? FileManager.default.removeItem(at: url)
            }
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
        saved.removeAll { entry in
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
        case unsupported
    }

    /// Copies one picked file in under its own name. The security scope is
    /// held only for the copy itself, synchronously, before any await. The
    /// copy is abandoned after 30 seconds: a file still downloading from
    /// iCloud must not stall the batch. A same-name, same-size file already
    /// in the library is a duplicate and is not copied at all.
    private nonisolated static func copyIn(from url: URL, directory: URL, id: Int,
                                           existing: [LocalMusicEntry]) async -> PreparedImport {
        let sourceName = sanitizedFileName(url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Size inside the scope: outside it the read fails and the size
        // is 0, which breaks the name+size dedup.
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if existing.contains(where: { $0.fileName == sourceName && $0.fileSize == sourceSize }) {
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
        let copied = await withTimeout(30, fallback: false) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: dest)
                return true
            } catch { return false }
        }
        guard copied else {
            // A timed-out copy may still be writing in the background;
            // removing the destination keeps a half-copied file out of the
            // library (the write lands in an unlinked inode and frees).
            try? FileManager.default.removeItem(at: dest)
            return .unsupported
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? sourceSize
        let entry = LocalMusicEntry(id: id, fileName: fileName, fileSize: size,
                                    title: url.deletingPathExtension().lastPathComponent,
                                    artist: "", album: "", durationMS: 0, dateAdded: Date())
        return .ready(entry)
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
        guard let directory else { return }
        Task { [entries = fresh, directory] in
            for entry in entries {
                if Task.isCancelled { return }
                let url = directory.appendingPathComponent(entry.fileName)
                guard let meta = await Self.readMetadata(of: url) else { continue }
                applyMetadata(id: entry.id, title: meta.title, artist: meta.artist,
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
