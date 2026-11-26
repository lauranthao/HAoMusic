import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Product facts shown on the About page. Version and build come from the
/// bundle; the links are HAo Music's own site and repository.
struct HAoAboutInfo {
    let version: String
    let build: String

    var name: String { "HAo Music" }
    var developer: String { "HAo / lauranthao" }
    var repository: String { "lauranthao/HAoMusic" }

    var websiteURL: URL? { URL(string: "https://lauranthao.github.io/HAoMusic/") }
    var repositoryURL: URL? { URL(string: "https://github.com/lauranthao/HAoMusic") }
    var issuesURL: URL? { repositoryURL?.appendingPathComponent("issues") }
    var releasesURL: URL? { repositoryURL?.appendingPathComponent("releases") }
    /// The maintained third-party index in the repository. It names the
    /// upstream projects, so it is linked out to the browser rather than
    /// rendered inside the app.
    static var thirdPartyNoticesURL: URL? {
        URL(string: "https://github.com/lauranthao/HAoMusic/blob/master/ThirdPartyNotices/README.md")
    }

    /// `host/path` without scheme or trailing slash, for compact display.
    static func displayAddress(_ url: URL) -> String {
        var text = (url.host ?? "") + url.path
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// About section: header, version rows, update rows, project links, the
/// licenses page and the disclaimer button. Hosted inline in Settings.
struct AboutSections: View {
    let info: HAoAboutInfo
    @Binding var showsDisclaimer: Bool

    var body: some View {
        Section {
            AboutHeader(info: info)

            Group {
                LabeledContent { Text(info.version) } label: { Label("版本", systemImage: "number") }
                LabeledContent { Text(info.build) } label: { Label("构建号", systemImage: "hammer") }
                LabeledContent { Text(info.developer) } label: { Label("开发者", systemImage: "person") }
            }
            .textSelection(.enabled)

            AboutUpdateRows()

            if let url = info.websiteURL {
                AboutLinkRow(title: "官网", systemImage: "globe",
                             detail: HAoAboutInfo.displayAddress(url), url: url)
            }
            if let url = info.repositoryURL {
                AboutLinkRow(title: "GitHub 仓库", systemImage: "chevron.left.forwardslash.chevron.right",
                             detail: info.repository, url: url)
            }
            if let url = info.issuesURL {
                AboutLinkRow(title: "问题反馈", systemImage: "exclamationmark.bubble", detail: nil, url: url)
            }
            if let url = info.releasesURL {
                AboutLinkRow(title: "版本发布", systemImage: "shippingbox", detail: nil, url: url)
            }

            NavigationLink(value: SettingsPage.licenses) {
                Label("开源许可与致谢", systemImage: "doc.text")
            }

            Button {
                showsDisclaimer = true
            } label: {
                Label("查看完整免责声明", systemImage: "exclamationmark.shield")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("关于")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("HAo Music 以 GNU AGPL v3.0 开源。")
                Text("HAo Music 是非官方的第三方客户端，与各音乐平台无关。音乐内容与数据均来自当前选择的音乐平台，版权归原权利人所有。")
            }
        }
    }
}

private struct AboutUpdateRows: View {
    @EnvironmentObject private var settings: SettingsManager
    #if os(macOS)
    @ObservedObject private var updater = UpdaterManager.shared
    #endif

    /// Sparkle on macOS; on iOS only sideload builds carry an updater.
    private var showsUpdateControls: Bool {
        #if os(iOS)
        return DistributionChannel.current.allowsSelfUpdate
        #else
        return true
        #endif
    }

    var body: some View {
        if showsUpdateControls {
            Toggle(isOn: $settings.autoCheckUpdates) {
                Label("启动时自动检查更新", systemImage: "clock.arrow.circlepath")
            }
            checkUpdatesButton
        }
    }

    @ViewBuilder
    private var checkUpdatesButton: some View {
        #if os(iOS)
        if DistributionChannel.current == .sideload {
            Button {
                IOSUpdater.shared.check(interactive: true)
            } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        #else
        Button {
            updater.checkForUpdates()
        } label: {
            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!updater.canCheckForUpdates)
        #endif
    }
}

private struct AboutHeader: View {
    let info: HAoAboutInfo

    var body: some View {
        VStack(spacing: 10) {
            HAoAppIconImage()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(info.name)
                .font(.title2.bold())
            Text("多平台音乐客户端")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct HAoAppIconImage: View {
    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
        #else
        if let icon = Self.primaryIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.tint)
        }
        #endif
    }

    #if os(iOS)
    private static let primaryIcon: UIImage? = {
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = Bundle.main.object(forInfoDictionaryKey: key) as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let name = (primary["CFBundleIconFiles"] as? [String])?.last,
                  let image = UIImage(named: name) else { continue }
            return image
        }
        return nil
    }()
    #endif
}

private struct AboutLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: String?
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(url.absoluteString))
    }
}

// MARK: - Licenses

/// The license texts bundled with the app, read from the bundle at display
/// time so they never drift from the files in the repository. The
/// ThirdPartyNotices index itself is not bundled: it names the upstream
/// projects, and the app UI never names them — the full index is linked out
/// to the browser instead (see `OpenSourceLicensesView`).
enum HAoLegalDocument: String, CaseIterable, Identifiable {
    case license = "LICENSE"
    case lgpl = "LICENSE-LGPL-3.0.txt"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .license: return "HAo Music"
        case .lgpl: return "GNU LGPL v3.0"
        }
    }

    var subtitle: String {
        switch self {
        case .license: return "GNU AGPL v3.0"
        case .lgpl: return "LGPL 引用的通用条款"
        }
    }

    private var resourceName: String {
        switch self {
        case .license: return "LICENSE"
        case .lgpl: return "LICENSE-LGPL-3.0"
        }
    }

    private var resourceExtension: String? {
        switch self {
        case .license: return nil
        case .lgpl: return "txt"
        }
    }

    var text: String? {
        guard let url = Bundle.main.url(
            forResource: resourceName, withExtension: resourceExtension
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// HAo Music's own license plus the third-party projects it builds on.
struct OpenSourceLicensesView: View {
    @State private var document: HAoLegalDocument?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                ForEach(HAoLegalDocument.allCases) { doc in
                    documentRow(doc)
                }
            } header: {
                Text("许可证")
            }

            Section("致谢") {
                Text("HAo Music 使用了以下开源项目：Beans-Music（MIT）、QQMusicApi（GPL-3.0）、simple-music（GPL-3.0）。各项目的许可证以其仓库中的文本为准。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let url = HAoAboutInfo.thirdPartyNoticesURL {
                    AboutLinkRow(
                        title: "在 GitHub 查看完整第三方声明",
                        systemImage: "doc.text.magnifyingglass",
                        detail: nil,
                        url: url
                    )
                }
            }

            Section {
                Text("感谢以上开源项目及其作者。各项目的许可证以其仓库中的文本为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("开源许可与致谢")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $document) { LegalDocumentSheet(document: $0) }
    }

    private func documentRow(_ doc: HAoLegalDocument) -> some View {
        Button {
            document = doc
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.title)
                    Text(doc.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LegalDocumentSheet: View {
    let document: HAoLegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: document.text ?? "无法读取该文件。")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(Text(verbatim: document.rawValue))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}
