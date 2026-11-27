import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum OfflineAudioError: Error, Equatable {
    case invalidResource, unavailable, incomplete, invalidResponse, changedResource
    case checksumMismatch, invalidAudio, busy, retained, insufficientSpace
    case database(String)
}

enum OfflineAudioFormat: String, Codable, CaseIterable {
    case mp3, m4a, flac

    var contentType: String {
        UTType(filenameExtension: rawValue)?.identifier ?? "public.audio"
    }

    /// Whether a transfer's Content-Type could carry audio at all. It cannot
    /// tell the formats apart: the CDN serves FLAC as `audio/mpeg` (#147). The
    /// MD5 and a full decode in `OfflineAudioValidator` prove the file; this
    /// only turns away an error page before it is hashed.
    func accepts(mimeType: String?) -> Bool {
        guard let type = mimeType?.lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces), !type.isEmpty else { return true }
        return type.hasPrefix("audio/") || type == "application/octet-stream" || type == "video/mp4"
    }

    /// Format from a download URL: the file extension first (CDNs serve
    /// FLAC as `audio/mpeg`, so the MIME type alone cannot be trusted),
    /// then the Content-Type.
    init?(url: URL, mimeType: String?) {
        if let fromExtension = OfflineAudioFormat(rawValue: url.pathExtension.lowercased()) {
            self = fromExtension
            return
        }
        switch mimeType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) {
        case "audio/mpeg", "audio/mp3": self = .mp3
        case "audio/mp4", "audio/x-m4a": self = .m4a
        case "audio/flac", "audio/x-flac": self = .flac
        default: return nil
        }
    }
}

/// Stable identity excludes signed/expiring CDN URLs. An MD5 from the source
/// identifies the expected representation; SHA256 is used for local filenames.
struct OfflineAudioIdentity: Codable, Hashable {
    let accountScope: String
    let trackID: Int
    let source: String
    let quality: String
    let format: OfflineAudioFormat
    let contentMD5: String
    /// The `contentMD5` is only a stable placeholder (MD5 of the download
    /// URL — see `provisionalMD5(for:)`) for files whose source reports no
    /// checksum: QQ vkey and unlock URLs. The real checksum is computed
    /// while verifying and replaces it (`OfflineAudioDescriptor.finalized`).
    /// Deliberately NOT part of `id` below, so a provisional record and
    /// its finalized form share the same identity fields and existing
    /// record ids are unchanged. `var`, not `let`: a defaulted `let` is
    /// not a memberwise-init parameter, and the resolver must set this.
    var md5Provisional: Bool = false

    /// Stable placeholder checksum for a URL whose source reports none:
    /// the MD5 of the URL itself. Unique per URL and 32 hex chars, so it
    /// satisfies the descriptor's shape check until verification replaces
    /// it with the file's real checksum.
    static func provisionalMD5(for url: URL) -> String {
        let digest = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var id: String {
        let fields = [accountScope, String(trackID), source, quality, format.rawValue, contentMD5]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var scopeDirectory: String {
        SHA256.hash(data: Data(accountScope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct OfflineAudioDescriptor: Codable, Equatable {
    let identity: OfflineAudioIdentity
    let byteCount: Int64
    let duration: TimeInterval

    func validate() throws {
        // QQ-only tracks carry a stable *negative* id (a hash of the
        // songmid, see Track.init(qqSong:)); 0 is the only impossible id.
        guard !identity.accountScope.isEmpty, identity.trackID != 0,
              !identity.source.isEmpty, !identity.quality.isEmpty,
              identity.contentMD5.count == 32,
              identity.contentMD5.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              byteCount > 0, byteCount <= 2_000_000_000,
              duration.isFinite, duration > 0 else { throw OfflineAudioError.invalidResource }
    }

    /// Rebuild the descriptor with the checksum computed while verifying.
    /// A FLAC container is lossless by definition, so a provisional FLAC
    /// file is relabelled lossless instead of keeping the conservative
    /// "standard" floor it was downloaded under; other formats keep the
    /// quality they were resolved with.
    func finalized(checksum: String) -> OfflineAudioDescriptor {
        let quality = identity.format == .flac ? AudioQuality.lossless.rawValue : identity.quality
        let identity = OfflineAudioIdentity(accountScope: identity.accountScope, trackID: identity.trackID,
                                            source: identity.source, quality: quality,
                                            format: identity.format, contentMD5: checksum.lowercased())
        return OfflineAudioDescriptor(identity: identity, byteCount: byteCount, duration: duration)
    }
}

struct OfflineAudioResource {
    let descriptor: OfflineAudioDescriptor
    let url: URL
}

struct OfflineAudioRecord: Codable {
    /// `partial` only appears in indexes written by earlier builds, which
    /// streamed audio into the store; it is retired on the next launch.
    enum State: String, Codable { case partial, verifying, complete, missing, deleting }
    let descriptor: OfflineAudioDescriptor
    var state: State = .verifying
    var retainedBy: Set<String> = []
    /// Orders the offline "recently played" list.
    var lastPlayed: Date?
    var verifiedModificationDate: Date?
    var id: String { descriptor.identity.id }
}

struct OfflinePlaybackLease {
    let token: UUID
    let descriptor: OfflineAudioDescriptor
    let url: URL
}
