import Foundation

/// Looks up the latest GitHub release. iOS has no Sparkle, so Settings
/// offers a manual check that links to the release page for re-sideloading.
enum ReleaseChecker {
    enum UpdateError: LocalizedError {
        case noRelease
        var errorDescription: String? { "HAo Music 暂无已发布版本，请稍后再检查更新。" }
    }

    struct Release {
        let version: String
        /// The release page (fallback download link).
        let url: URL
        /// Direct download URL of the iOS IPA asset, when present.
        let ipaURL: URL?
        /// Build number when known (from version.json); nil for the GitHub
        /// API fallback, which only carries the tag. `var`, not `let`: a
        /// defaulted `let` is not a memberwise-init parameter. The `= nil`
        /// default matters: parseLatest builds a Release without a build,
        /// and without it the memberwise init would demand `build:` there.
        var build: Int? = nil

        /// "0.1.3（build 16）" when the build is known, else just the version.
        var displayVersion: String {
            build.map { "\(version)（build \($0)）" } ?? version
        }
    }

    static let releasesPage = URL(string: "https://github.com/lauranthao/HAoMusic/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// The version file served by GitHub Pages. RULE: every build bump must
    /// bump `build` here in the same commit, or the in-app updater cannot
    /// see a same-version rebuild (build 15 was invisible for exactly this
    /// reason — the check only compared the version string).
    static let versionInfoURL = URL(string: "https://lauranthao.github.io/HAoMusic/version.json")!

    struct VersionInfo {
        let version: String
        let build: Int
        /// Direct download URL of the iOS IPA asset, when present.
        let ipaURL: URL?
        /// The release page (fallback download link).
        let url: URL
    }

    /// Update decision: BOTH version and build are compared.
    /// Remote version greater → update; versions equal and remote build
    /// greater → update; anything else → up to date.
    static func isUpdateAvailable(remoteVersion: String, remoteBuild: Int,
                                  localVersion: String = currentVersion,
                                  localBuild: Int = currentBuild) -> Bool {
        if isNewer(remoteVersion, than: localVersion) { return true }
        if isNewer(localVersion, than: remoteVersion) { return false }
        return remoteBuild > localBuild
    }

    /// Preferred check: version.json first (version + build), falling back
    /// to the GitHub releases API (version only) when version.json cannot
    /// be reached, so a network hiccup never breaks the whole check.
    /// Returns the release to offer, or nil when up to date.
    static func checkForUpdate() async throws -> Release? {
        if let info = try? await latestVersionInfo() {
            guard isUpdateAvailable(remoteVersion: info.version, remoteBuild: info.build) else { return nil }
            return Release(version: info.version, url: info.url, ipaURL: info.ipaURL, build: info.build)
        }
        let latest = try await latest()
        guard isNewer(latest.version, than: currentVersion) else { return nil }
        return latest
    }

    static func latestVersionInfo() async throws -> VersionInfo {
        var request = URLRequest(url: versionInfoURL)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String,
              let build = obj["build"] as? Int
        else { throw MusicAPIError.decoding("version.json") }
        let ipaURL = (obj["ipa"] as? String).flatMap(URL.init)
        return VersionInfo(version: version, build: build, ipaURL: ipaURL, url: releasesPage)
    }

    static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/lauranthao/HAoMusic/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseLatest(data: data, response: response)
    }

    static func parseLatest(data: Data, response: URLResponse) throws -> Release {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { throw UpdateError.noRelease }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String, let url = URL(string: html)
        else { throw MusicAPIError.decoding("release") }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let ipa = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
        let ipaURL = (ipa?["browser_download_url"] as? String).flatMap(URL.init)
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       url: url, ipaURL: ipaURL)
    }

    /// True when `remote` is newer than `local` (numeric dotted compare).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
