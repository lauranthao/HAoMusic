// Copied verbatim from Coda except the four HAo seam spots marked SEAM:
// HAo's NetEase client is MusicAPI/MusicClient, not NeteaseAPI/NeteaseClient,
// and HAo has no playlistCover endpoint, so the cover lookup reads the
// playlist detail's coverImgUrl instead. Behaviour is unchanged: the store
// only runs when the summary carries no cover URL.
import SwiftUI

/// Share lookups between visible cards and rows, scoped to the current login.
@MainActor
final class PlaylistArtworkStore {
    static let shared = PlaylistArtworkStore()
    private struct Key: Hashable {
        let id: Int
        let authentication: String?
    }
    private var cached: [Key: (url: String, date: Date)] = [:]
    private var pending: [Key: Task<String?, Never>] = [:]

    func cover(id: Int) async -> String? {
        // SEAM: HAo's auth fingerprint lives on MusicClient, not NeteaseClient.
        let key = Key(id: id, authentication: MusicClient.shared.authenticationFingerprint)
        if let entry = cached[key], Date().timeIntervalSince(entry.date) < 300 { return entry.url }
        if let task = pending[key] { return await task.value }
        // SEAM: HAo has no playlistCover endpoint; the detail carries coverImgUrl.
        let task = Task { try? await MusicAPI.playlistDetail(id: id).playlist.coverImgUrl }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        guard key.authentication == MusicClient.shared.authenticationFingerprint else { return nil }
        if let result {
            if cached.count >= 256 { cached.removeAll() }
            cached[key] = (result, Date())
        }
        return result
    }
}

struct PlaylistArtwork: View {
    let coverURL: URL?
    let playlistID: Int?
    var pixelSize: Int = 384
    var animated = true
    @State private var resolvedURL: URL?
    @State private var resolvedID: Int?

    init(coverURL: URL?, playlistID: Int?, pixelSize: Int = 384, animated: Bool = true) {
        self.coverURL = coverURL
        self.playlistID = playlistID
        self.pixelSize = pixelSize
        self.animated = animated
    }

    init(playlist: PlaylistSummary, pixelSize: Int, animated: Bool = true) {
        self.init(coverURL: playlist.coverURL?.resizedImageURL(pixelSize),
                  playlistID: playlist.id, pixelSize: pixelSize, animated: animated)
    }

    var body: some View {
        CachedAsyncImage(url: coverURL ?? (resolvedID == playlistID ? resolvedURL : nil), animated: animated)
            .task(id: lookupKey) {
                guard coverURL == nil, let playlistID else { return }
                let result = await PlaylistArtworkStore.shared.cover(id: playlistID)
                guard !Task.isCancelled else { return }
                resolvedURL = result?.resizedImageURL(pixelSize)
                resolvedID = playlistID
            }
    }

    private var lookupKey: String {
        // SEAM: see cover(id:) above.
        "\(playlistID ?? 0)|\(coverURL?.absoluteString ?? "")|\(MusicClient.shared.authenticationFingerprint ?? "")"
    }
}
