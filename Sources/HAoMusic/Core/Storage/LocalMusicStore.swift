import AVFoundation
import CryptoKit
import Foundation

/// One audio file the user imported from their own device, plus the Track the
/// UI plays. Negative ids never collide with NetEase song ids, which is how
/// the player tells a local track apart from a streamed one.
struct LocalMusicEntry: Codable, Hashable, Identifiable {
    var id: Int
    var fileName: String
    var md5: String
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
        var unsupported = 0
    }

    static let supportedExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "wav", "aiff"]

    @Published private(set) var entries: [LocalMusicEntry] = []

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

    /// Copies the picked files in, reading each one's tags first. A file
    /// already in the library (same bytes) is skipped, not duplicated.
    func importFiles(_ urls: [URL]) async -> ImportResult {
        guard let directory else { return ImportResult() }
        var result = ImportResult()
        var nextID = (entries.map(\.id).min() ?? 0) - 1
        var seenMD5s = Set(entries.map(\.md5))
        var newEntries: [LocalMusicEntry] = []
        for url in urls {
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                result.unsupported += 1
                continue
            }
            switch await Self.prepareImport(from: url, directory: directory, id: nextID,
                                           knownMD5s: seenMD5s) {
            case .ready(let entry):
                nextID -= 1
                seenMD5s.insert(entry.md5)
                newEntries.append(entry)
                result.imported += 1
            case .duplicate:
                result.duplicates += 1
            case .unsupported:
                result.unsupported += 1
            }
        }
        if !newEntries.isEmpty {
            entries = (newEntries + entries).sorted { $0.dateAdded > $1.dateAdded }
            saveIndex()
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
        guard let indexURL,
              let data = try? Data(contentsOf: indexURL),
              var saved = try? JSONDecoder().decode([LocalMusicEntry].self, from: data) else { return }
        // A file deleted outside the app (Files, Finder sharing) drops its entry.
        let before = saved.count
        saved.removeAll { entry in
            guard let dir = directory else { return true }
            return !FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry.fileName).path)
        }
        entries = saved.sorted { $0.dateAdded > $1.dateAdded }
        if saved.count != before { saveIndex() }
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

    /// Copies the picked file in first, then reads its tags from our own
    /// copy. The file picker's security scope is held only for the copy
    /// itself, synchronously, before any await: the old order read the
    /// source through AVAsset after an await, and AVAsset's reader threads
    /// run outside the scope the picker granted — so the duration load
    /// failed and every file came back unsupported (build 5, chen 2026-11-27).
    /// A copy that turns out to be a duplicate, unreadable or duration-less
    /// is deleted again, so a failed import leaves nothing behind.
    private nonisolated static func prepareImport(from url: URL, directory: URL, id: Int,
                                                  knownMD5s: Set<String>) async -> PreparedImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileName = "\(UUID().uuidString).\(url.pathExtension.lowercased())"
        let dest = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return .unsupported
        }
        // From here on the file is ours: no scope needed, whatever thread
        // the awaits resume on.
        guard let md5 = md5(of: dest), !md5.isEmpty else {
            try? FileManager.default.removeItem(at: dest)
            return .unsupported
        }
        if knownMD5s.contains(md5) {
            try? FileManager.default.removeItem(at: dest)
            return .duplicate
        }
        let asset = AVURLAsset(url: dest)
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite, duration.seconds > 0 else {
            try? FileManager.default.removeItem(at: dest)
            return .unsupported
        }
        let metadata = try? await asset.load(.commonMetadata)
        let title = metadataValue(.commonIdentifierTitle, in: metadata)
            ?? url.deletingPathExtension().lastPathComponent
        let artist = metadataValue(.commonIdentifierArtist, in: metadata) ?? ""
        let album = metadataValue(.commonIdentifierAlbumName, in: metadata) ?? ""
        let entry = LocalMusicEntry(id: id, fileName: fileName, md5: md5, title: title,
                                    artist: artist, album: album,
                                    durationMS: Int(duration.seconds * 1000), dateAdded: Date())
        return .ready(entry)
    }

    private nonisolated static func md5(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        do {
            while let chunk = try handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                hash.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func metadataValue(_ identifier: AVMetadataIdentifier,
                                                  in metadata: [AVMetadataItem]?) -> String? {
        guard let metadata else { return nil }
        return AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
            .first?.stringValue
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
