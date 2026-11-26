import Foundation

/// User-imported wallpaper files under `Documents/wallpapers/`.
///
/// Only the relative name (`wallpapers/<uuid>.<ext>`) is ever stored — the
/// container path changes on reinstall, so an absolute path would orphan the
/// file. The image data is stored as-is (no re-encode: a HEIC stays a HEIC);
/// `UIImage` decodes by content.
///
/// The store only manages files. Whether a wallpaper is active lives in
/// `SettingsManager` (`wallpaperEnabled` / `wallpaperCurrent`); the cached
/// image lives in `WallpaperImageLoader`.
enum WallpaperStore {
    static let wallpaperSubdir = "wallpapers"

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Import image data as the wallpaper. Returns the relative name
    /// (`wallpapers/<uuid>.<ext>`), or nil when the data is not a
    /// recognisable image or the write fails.
    @discardableResult
    static func importImage(data: Data) -> String? {
        guard let ext = imageExtension(for: data) else { return nil }
        let dir = documentsDirectory.appendingPathComponent(wallpaperSubdir)
        let fileName = "\(UUID().uuidString).\(ext)"
        let url = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            return nil
        }
        return "\(wallpaperSubdir)/\(fileName)"
    }

    /// The file URL for a stored relative name (or a bare file name), or nil
    /// when the file is gone.
    static func fileURL(for name: String) -> URL? {
        let base = URL(fileURLWithPath: name).lastPathComponent
        guard !base.isEmpty else { return nil }
        let url = documentsDirectory
            .appendingPathComponent(wallpaperSubdir)
            .appendingPathComponent(base)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete a wallpaper file. Matches by relative name or bare file name.
    /// No-op when absent.
    static func delete(_ name: String) {
        let base = URL(fileURLWithPath: name).lastPathComponent
        guard !base.isEmpty else { return }
        let url = documentsDirectory
            .appendingPathComponent(wallpaperSubdir)
            .appendingPathComponent(base)
        try? FileManager.default.removeItem(at: url)
    }

    /// File extension for image data, from its magic bytes. Nil when the
    /// data is not a JPEG, PNG, GIF, WebP or HEIC image.
    static func imageExtension(for data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "gif" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        // HEIC/HEIF: `....ftypheic`, `....ftypmif1` or `....ftypmsf1`.
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8...11], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return "heic" }
        }
        return nil
    }
}
