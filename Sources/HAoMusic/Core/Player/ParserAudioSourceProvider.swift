import Foundation

/// Third-party parsing services, called directly over HTTP.
/// Each endpoint takes one platform's song ID and answers with a stream that
/// may come from another platform, so the returned song is checked again.
///
/// NOTE: these are third-party parsing services, not official APIs.
/// (Ported from Coda, Wow-CaiCai/Coda, AGPL-3.0,
/// Sources/Coda/Core/Player/Unblock/ParserUnblockSource.swift.)
struct ParserAudioSourceProvider: AudioSourceProvider {
    var id: AudioSourceID { .parser }
    var displayName: String { AudioSourceID.parser.displayName }

    private let httpClient = AudioSourceClient.shared

    /// Endpoints confirmed to return full-length streams; add a row to add one.
    private struct Endpoint {
        enum Platform {
            /// NetEase song ID.
            case wy
            /// KuGou file hash.
            case kg
        }

        let name: String
        let platform: Platform
        /// Mirrors serving the same API, tried in order.
        let hosts: [String]
        let path: String

        func url(host: String, id: String, level: String) -> URL? {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            components.queryItems = [
                URLQueryItem(name: "type", value: "json"),
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "level", value: level),
            ]
            return components.url
        }
    }

    private static let endpoints: [Endpoint] = [
        Endpoint(name: "wy", platform: .wy,
                 hosts: ["musicapi.haitangw.net", "music.haitangw.cc"], path: "/music/wy_song_kw.php"),
        Endpoint(name: "kg", platform: .kg,
                 hosts: ["musicapi.haitangw.net", "music.haitangw.cc"], path: "/music/kg_song_kw.php"),
    ]

    /// Their Hi-Res answer is a low-rate AAC preview, so always ask lossless.
    private static let level = "lossless"

    /// Streams below this are previews or placeholders, not the track.
    private static let minimumBitrate: Double = 96_000

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        var lastError: Error?
        for endpoint in Self.endpoints {
            do {
                guard let songID = try await songID(for: endpoint.platform, track: track) else { continue }
                if let url = try await resolve(endpoint, songID: songID, track: track) {
                    await UnblockMatchCache.shared.store(.direct(url: url), for: .parser, trackID: track.id)
                    return ResolvedAudioSource(id: .parser, displayName: displayName, url: url)
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private func songID(for platform: Endpoint.Platform, track: Track) async throws -> String? {
        switch platform {
        case .wy:
            return String(track.id)
        case .kg:
            // Reuses the Kugou match cache, so a parallel Kugou attempt
            // searching the same song does not cost a second search.
            if let cached = await UnblockMatchCache.shared.match(for: .kugou, trackID: track.id),
               case .kugou(let hash, _) = cached {
                return hash.uppercased()
            }
            let match = try await KugouAudioSourceProvider().searchMatch(track: track)
            return match?.hash.uppercased()
        }
    }

    private func resolve(_ endpoint: Endpoint, songID: String, track: Track) async throws -> URL? {
        var lastError: Error?
        for host in endpoint.hosts {
            guard let url = endpoint.url(host: host, id: songID, level: Self.level) else { continue }
            let data: Data
            do {
                data = try await httpClient.data(from: url, source: id, operation: "resolve-\(endpoint.name)")
            } catch {
                // A dead mirror falls through to the next one.
                lastError = error
                continue
            }
            guard let answer = Answer(data) else { throw AudioSourceProviderError.invalidResponse }
            // The service answered; a miss here is a miss on every mirror.
            return answer.streamURL(for: track)
        }
        if let lastError { throw lastError }
        return nil
    }

    /// One parsed service answer.
    private struct Answer {
        let code: Int
        let name: String
        let artist: String
        let durationMS: Int?
        let byteCount: Double?
        let url: String?

        init?(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = (object["code"] as? NSNumber)?.intValue else { return nil }
            let payload = object["data"] as? [String: Any] ?? [:]
            self.code = code
            name = payload["name"] as? String ?? ""
            artist = payload["artist"] as? String ?? ""
            durationMS = (payload["duration"] as? String).flatMap(Self.durationMS)
            byteCount = (payload["size"] as? String).flatMap(Self.byteCount)
            url = (payload["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The stream when it is the same recording as the query. A missing
        /// duration (the KuGou endpoint omits it) is checked by size instead.
        func streamURL(for track: Track) -> URL? {
            guard code == 200, let urlString = url else { return nil }
            let duration = durationMS ?? track.durationMS
            guard AudioSourceTrackMatcher.matches(
                track: track, title: name, artist: artist, durationMS: duration
            ) else { return nil }
            let address = urlString.replacingOccurrences(of: "http://", with: "https://")
            guard let url = URL(string: address) else { return nil }
            let seconds = Double(duration) / 1000
            if let byteCount, seconds > 0 {
                let bitrate = byteCount * 8 / seconds
                if bitrate < ParserAudioSourceProvider.minimumBitrate { return nil }
            }
            return url
        }

        /// "4分29秒" → 269000.
        private static func durationMS(_ text: String) -> Int? {
            let scanner = Scanner(string: text)
            var seconds = 0
            var found = false
            while !scanner.isAtEnd {
                guard let value = scanner.scanInt() else {
                    _ = scanner.scanCharacter()
                    continue
                }
                let unit = scanner.scanCharacter()
                switch unit {
                case "时": seconds += value * 3600
                case "分": seconds += value * 60
                case "秒", nil: seconds += value
                default: continue
                }
                found = true
            }
            return found && seconds > 0 ? seconds * 1000 : nil
        }

        /// "52.83 MB" → bytes.
        private static func byteCount(_ text: String) -> Double? {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let number = parts.first.flatMap({ Double($0) }), number > 0 else { return nil }
            switch parts.dropFirst().first?.uppercased() ?? "B" {
            case "KB": return number * 1024
            case "MB": return number * 1024 * 1024
            case "GB": return number * 1024 * 1024 * 1024
            default: return number
            }
        }
    }
}
