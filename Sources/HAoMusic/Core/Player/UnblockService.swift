import Foundation
import os.log

/// Finds a full-length stream for a track the NetEase service will not play,
/// Coda-style: the mirror and parsing services first, then the other
/// platforms (signed-in ones first), racing in parallel with 8s per source
/// and a 15s total deadline. The winner is the earliest source in priority
/// order that succeeded, so the result does not depend on timing.
///
/// (Ported from Coda, Wow-CaiCai/Coda, AGPL-3.0,
/// Sources/Coda/Core/Player/Unblock/UnblockResolver.swift.)
enum UnblockService {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")
    private static let httpClient = AudioSourceClient.shared

    /// Per-source cap, and the total cap for the whole race (Coda's values).
    static let sourceTimeout: TimeInterval = 8
    static let totalTimeout: TimeInterval = 15

    /// Mirrors and parsing services, in priority order.
    private static let mirrorProviders: [any AudioSourceProvider] = [
        PyncmdAudioSourceProvider(),
        ParserAudioSourceProvider(),
    ]
    private static let platformProviders: [any AudioSourceProvider] = [
        QQAudioSourceProvider(),
        KugouAudioSourceProvider(),
        KuwoAudioSourceProvider(),
    ]

    struct Resolution {
        let source: ResolvedAudioSource?
        let attemptedSources: Set<AudioSourceID>
    }

    static func resolve(
        _ track: Track,
        enabledSources: Set<AudioSourceID>,
        excluding attemptedSources: Set<AudioSourceID>
    ) async -> Resolution {
        guard !Task.isCancelled else { return Resolution(source: nil, attemptedSources: []) }
        let ordered = await orderedSources(enabledSources: enabledSources, excluding: attemptedSources)
        guard !ordered.isEmpty else { return Resolution(source: nil, attemptedSources: []) }

        let (winner, failed) = await race(ordered, track: track)
        var attempted = failed
        if let winner {
            attempted.insert(winner.id)
            return Resolution(source: winner, attemptedSources: attempted)
        }
        return Resolution(source: nil, attemptedSources: attempted)
    }

    /// Mirrors first, in listed order; then platforms with a saved account
    /// before anonymous ones.
    private static func orderedSources(
        enabledSources: Set<AudioSourceID>,
        excluding: Set<AudioSourceID>
    ) async -> [any AudioSourceProvider] {
        let usable = { (provider: any AudioSourceProvider) in
            enabledSources.contains(provider.id) && !excluding.contains(provider.id)
        }
        let mirrors = mirrorProviders.filter(usable)
        let qqSignedIn = await MainActor.run { QQMusicAuth.shared.isLoggedIn }
        var signedIn: [any AudioSourceProvider] = []
        var anonymous: [any AudioSourceProvider] = []
        for provider in platformProviders where usable(provider) {
            if provider.id == .qq, qqSignedIn {
                signedIn.append(provider)
            } else {
                anonymous.append(provider)
            }
        }
        return mirrors + signedIn + anonymous
    }

    private enum State { case pending, failed, found(ResolvedAudioSource) }
    private enum Event { case finished(Int, ResolvedAudioSource?), deadline }

    private static func race(
        _ sources: [any AudioSourceProvider],
        track: Track
    ) async -> (ResolvedAudioSource?, Set<AudioSourceID>) {
        await withTaskGroup(of: Event.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    .finished(index, await attempt(source, track: track))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(totalTimeout * 1_000_000_000))
                return .deadline
            }
            defer { group.cancelAll() }

            var states = Array(repeating: State.pending, count: sources.count)
            var failed = Set<AudioSourceID>()
            for await event in group {
                guard case .finished(let index, let resolved) = event else { break }
                if let resolved {
                    states[index] = .found(resolved)
                } else {
                    states[index] = .failed
                    failed.insert(sources[index].id)
                }
                // The first source in order decides once everything before it failed.
                for (_, state) in states.enumerated() {
                    if case .found(let resolved) = state {
                        return (resolved, failed)
                    }
                    if case .pending = state { break }
                }
                if !states.contains(where: { if case .pending = $0 { return true }; return false }) { break }
            }
            return (nil, failed)
        }
    }

    /// One source's answer; failures are logged and read as "no stream".
    /// A cached match skips the search; a miss is remembered for 10 minutes.
    private static func attempt(
        _ provider: any AudioSourceProvider,
        track: Track
    ) async -> ResolvedAudioSource? {
        if await UnblockFailureMemory.shared.remembersMiss(provider.id, trackID: track.id) { return nil }
        do {
            let resolved = try await withTimeout(sourceTimeout) {
                try await resolveWithCache(provider, track: track)
            }
            if resolved == nil, !Task.isCancelled {
                await UnblockFailureMemory.shared.rememberMiss(provider.id, trackID: track.id)
            }
            return resolved
        } catch {
            if !Task.isCancelled {
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
            return nil
        }
    }

    /// A cached match (or direct URL) skips the search; a stale cached match
    /// falls back to a fresh search instead of failing the source.
    private static func resolveWithCache(
        _ provider: any AudioSourceProvider,
        track: Track
    ) async throws -> ResolvedAudioSource? {
        if let match = await UnblockMatchCache.shared.match(for: provider.id, trackID: track.id) {
            if case .direct(let url) = match {
                return ResolvedAudioSource(id: provider.id, displayName: provider.displayName, url: url)
            }
            if let resolved = try await provider.resolve(match: match, track: track) {
                return resolved
            }
        }
        return try await provider.resolve(track: track)
    }

    private struct TimeoutError: LocalizedError {
        var errorDescription: String? { "Audio-source lookup timed out" }
    }

    private static func withTimeout<T>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T?
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { return nil }
            return result
        }
    }

    private static func logFailure(source: AudioSourceID, operation: String, error: Error) {
        log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}

/// The pyncmd mirror as a provider, so it can race with the others instead
/// of running first and alone.
struct PyncmdAudioSourceProvider: AudioSourceProvider {
    var id: AudioSourceID { .pyncmd }
    var displayName: String { AudioSourceID.pyncmd.displayName }

    private let httpClient = AudioSourceClient.shared

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=\(Upstream.tag)&id=\(track.id)&br=320"
        let data = try await httpClient.data(
            from: urlString,
            source: .pyncmd,
            operation: "resolve"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioSourceProviderError.invalidResponse
        }
        guard let bitrate = object["br"] as? Int, bitrate > 0 else {
            throw AudioSourceProviderError.missingBitrate
        }
        guard let urlValue = object["url"] as? String else {
            throw AudioSourceProviderError.missingStreamURL
        }
        guard let url = URL(string: urlValue.replacingOccurrences(of: "http://", with: "https://")) else {
            throw AudioSourceProviderError.invalidURL
        }
        await UnblockMatchCache.shared.store(.direct(url: url), for: .pyncmd, trackID: track.id)
        return ResolvedAudioSource(id: .pyncmd, displayName: displayName, url: url)
    }
}

/// Remembers, for a while, that a source has no copy of a song, so skipping
/// back and forth does not search every platform again.
/// (Coda's UnblockFailureMemory, 10-minute lifetime.)
actor UnblockFailureMemory {
    static let shared = UnblockFailureMemory()
    static let lifetime: TimeInterval = 10 * 60

    private struct Key: Hashable {
        let source: AudioSourceID
        let trackID: Int
    }

    private var misses: [Key: Date] = [:]

    func remembersMiss(_ source: AudioSourceID, trackID: Int) -> Bool {
        let key = Key(source: source, trackID: trackID)
        guard let expiry = misses[key] else { return false }
        if expiry > Date() { return true }
        misses[key] = nil
        return false
    }

    func rememberMiss(_ source: AudioSourceID, trackID: Int) {
        let now = Date()
        if misses.count > 500 { misses = misses.filter { $0.value > now } }
        misses[Key(source: source, trackID: trackID)] = now.addingTimeInterval(Self.lifetime)
    }

    func removeAll() {
        misses.removeAll()
    }
}

/// Caches a provider's search match (or a mirror's direct URL) for 10
/// minutes, so a repeat tap goes straight to the stream URL instead of
/// searching again. (Coda's UnblockMatchCache.)
actor UnblockMatchCache {
    static let shared = UnblockMatchCache()
    static let lifetime: TimeInterval = 10 * 60

    private struct Key: Hashable {
        let source: AudioSourceID
        let trackID: Int
    }

    private var entries: [Key: (match: UnblockMatch, expiry: Date)] = [:]

    func match(for source: AudioSourceID, trackID: Int) -> UnblockMatch? {
        let key = Key(source: source, trackID: trackID)
        guard let entry = entries[key] else { return nil }
        if entry.expiry > Date() { return entry.match }
        entries[key] = nil
        return nil
    }

    func store(_ match: UnblockMatch, for source: AudioSourceID, trackID: Int) {
        let now = Date()
        if entries.count > 500 { entries = entries.filter { $0.value.expiry > now } }
        entries[Key(source: source, trackID: trackID)] = (match, now.addingTimeInterval(Self.lifetime))
    }

    func removeAll() {
        entries.removeAll()
    }
}
