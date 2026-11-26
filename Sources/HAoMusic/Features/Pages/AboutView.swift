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
    /// The same third-party index on GitHub, used as the fallback link when
    /// the bundled copy cannot be read.
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

// MARK: - Third-party index parser

/// Minimal parser for ThirdPartyNotices/README.md: `## ` headings start a
/// group, `| ... |` rows are its table. The first table row in a group is
/// its header (column 0 is the name; the column headed 许可证 is the
/// license; the rest are notes), separator rows are skipped, every other row
/// is an entry. Written for this file's actual shape; rows that do not fit
/// are skipped rather than crashing.
///
/// Pure Foundation — no SwiftUI — so it can be exercised outside the app.
struct ThirdPartyNoticeEntry: Equatable {
    let name: String
    let url: URL?
    let license: String?
    let note: String?
}

struct ThirdPartyNoticeGroup: Equatable {
    let title: String
    let entries: [ThirdPartyNoticeEntry]
    /// Prose lines under the heading, outside any table, if any.
    let note: String?
}

enum ThirdPartyNotices {
    /// The bundled ThirdPartyNotices/README.md, if it is in the app bundle.
    static var bundledMarkdown: String? {
        let candidates = [
            Bundle.main.url(forResource: "README", withExtension: "md"),
            Bundle.main.url(forResource: "README", withExtension: "md",
                            subdirectory: "ThirdPartyNotices"),
        ]
        for url in candidates {
            if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    static func parse(_ markdown: String) -> [ThirdPartyNoticeGroup] {
        var groups: [ThirdPartyNoticeGroup] = []
        var title: String?
        var entries: [ThirdPartyNoticeEntry] = []
        var prose: [String] = []
        var roles: [Role]?

        func flush() {
            if let title {
                groups.append(ThirdPartyNoticeGroup(
                    title: title,
                    entries: entries,
                    note: prose.isEmpty ? nil : prose.joined(separator: "\n")))
            }
            title = nil
            entries = []
            prose = []
            roles = nil
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                title = stripNumbering(String(line.dropFirst(3)))
                continue
            }
            guard title != nil else { continue }
            if line.hasPrefix("|") {
                let cells = splitRow(line)
                guard !cells.isEmpty else { continue }
                if cells.allSatisfy({ $0.allSatisfy({ "-: ".contains($0) }) }) {
                    continue  // separator row
                }
                if roles == nil {
                    roles = rolesForHeader(cells)
                    continue
                }
                if let entry = entry(from: cells, roles: roles!) {
                    entries.append(entry)
                }
                continue
            }
            if !line.isEmpty {
                prose.append(stripLinks(line))
            }
        }
        flush()
        return groups
    }

    private enum Role { case name, license, note }

    private static func rolesForHeader(_ cells: [String]) -> [Role] {
        cells.enumerated().map { index, cell in
            if index == 0 { return .name }
            if cell.contains("许可证") { return .license }
            return .note
        }
    }

    private static func entry(from cells: [String], roles: [Role]) -> ThirdPartyNoticeEntry? {
        var name = ""
        var url: URL?
        var license: String?
        var notes: [String] = []
        for (index, cell) in cells.enumerated() {
            let role = index < roles.count ? roles[index] : .note
            switch role {
            case .name:
                if let link = firstLink(in: cell) {
                    name = link.text
                    url = link.url
                } else {
                    name = stripLinks(cell).trimmingCharacters(in: .whitespaces)
                }
            case .license:
                license = cleanLicense(cell)
            case .note:
                let text = stripLinks(cell).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { notes.append(text) }
            }
        }
        guard !name.isEmpty else { return nil }
        return ThirdPartyNoticeEntry(
            name: name, url: url, license: license,
            note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    private static func splitRow(_ line: String) -> [String] {
        var body = line[...]
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// First `[text](target)` in the cell, if any. Only http(s) targets
    /// become URLs; relative targets (repo files) yield the text alone.
    private static func firstLink(in text: String) -> (text: String, url: URL?)? {
        guard let open = text.firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]"),
              text.index(after: close) < text.endIndex,
              text[text.index(after: close)] == "(",
              let paren = text[close...].firstIndex(of: ")") else {
            return nil
        }
        let name = String(text[text.index(after: open)..<close])
        let target = String(text[text.index(close, offsetBy: 2)..<paren])
        let url = target.hasPrefix("http") ? URL(string: target) : nil
        return (name, url)
    }

    /// Replaces every `[text](target)` with `text`, drops backticks.
    private static func stripLinks(_ text: String) -> String {
        var result = ""
        var rest = text[...]
        while let open = rest.firstIndex(of: "["),
              let close = rest[open...].firstIndex(of: "]"),
              rest.index(after: close) < rest.endIndex,
              rest[rest.index(after: close)] == "(",
              let paren = rest[close...].firstIndex(of: ")") {
            result += rest[..<open]
            result += rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: paren)...]
        }
        result += rest
        return result.replacingOccurrences(of: "`", with: "")
    }

    private static func cleanLicense(_ text: String) -> String? {
        var value = stripLinks(text)
        if let cut = value.firstIndex(where: { $0 == "（" || $0 == "(" }) {
            value = String(value[..<cut])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == "—" || value == "-" { return nil }
        return value
    }

    private static func stripNumbering(_ title: String) -> String {
        guard let dot = title.firstIndex(of: "."),
              title[..<dot].allSatisfy(\.isNumber) else {
            return title
        }
        return title[title.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Licenses

/// The license texts bundled with the app, read from the bundle at display
/// time so they never drift from the files in the repository. The
/// third-party index (ThirdPartyNotices/README.md) is bundled the same way
/// and parsed by `ThirdPartyNotices` below.
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

/// HAo Music's own license plus the full third-party index from the
/// bundled ThirdPartyNotices/README.md.
struct OpenSourceLicensesView: View {
    @State private var document: HAoLegalDocument?

    var body: some View {
        Form {
            Section {
                ForEach(HAoLegalDocument.allCases) { doc in
                    documentRow(doc)
                }
            } header: {
                Text("许可证")
            }

            if let text = ThirdPartyNotices.bundledMarkdown {
                let groups = ThirdPartyNotices.parse(text)
                if groups.isEmpty {
                    // The file is there but nothing parsed — show it raw.
                    Section("第三方声明") {
                        ScrollView {
                            Text(verbatim: text)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 240)
                        thirdPartyLinkRow()
                    }
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Section(LocalizedStringKey(group.title)) {
                            if let note = group.note {
                                Text(note)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                                noticeRow(entry)
                            }
                        }
                    }
                }
            } else {
                Section("致谢") {
                    thirdPartyLinkRow()
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

    @ViewBuilder
    private func thirdPartyLinkRow() -> some View {
        if let url = HAoAboutInfo.thirdPartyNoticesURL {
            AboutLinkRow(
                title: "在 GitHub 查看完整第三方声明",
                systemImage: "doc.text.magnifyingglass",
                detail: nil,
                url: url
            )
        }
    }

    @ViewBuilder
    private func noticeRow(_ entry: ThirdPartyNoticeEntry) -> some View {
        let content = HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.name)
                if let license = entry.license {
                    Text(verbatim: license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = entry.note {
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.url != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        if let url = entry.url {
            Link(destination: url) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
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
