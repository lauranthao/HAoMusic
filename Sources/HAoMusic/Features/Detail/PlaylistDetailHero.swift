import SwiftUI

/// Shared collection header, Coda-style (layout copied from Coda,
/// Wow-CaiCai/Coda, AGPL-3.0, Features/Detail/PlaylistDetailHero.swift,
/// with chen's approval; code rewritten for HAo Music's types).
/// Phone only: iPad/desktop keep their own wide headers.
/// Pages stay on the plain system background — no artwork tint.
struct PlaylistDetailHero<Actions: View>: View {
    let coverURL: URL?
    let title: String
    let subtitle: String
    let avatarURL: URL?
    let metadataText: String
    var circularArtwork = false
    var showsAvatar = true
    /// When set, the subtitle is a tappable link to this destination.
    var subtitleDestination: Destination? = nil
    @ViewBuilder var actions: () -> Actions

    @State private var availableWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            artwork
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24)
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                if showsAvatar {
                    Group {
                        if let avatarURL {
                            CachedAsyncImage(url: avatarURL.resizedImageURL(80), animated: false)
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                }
                if let subtitleDestination {
                    NavigationLink(value: subtitleDestination) {
                        Text(subtitle)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(subtitle)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.top, 8)
            .padding(.horizontal, 16)

            Text(metadataText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 8)
                .padding(.horizontal, 16)

            actions()
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { availableWidth = $0 }
            }
        }
    }

    private var artwork: some View {
        let size = min(availableWidth * 0.68, 300)
        return CachedAsyncImage(url: coverURL?.resizedImageURL(512), animated: false)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: circularArtwork ? size / 2 : 12,
                                        style: .continuous))
    }
}

/// The capsule glass search bar that sits above a phone hero (44pt).
struct PlaylistSearchBar: View {
    @Binding var text: String
    var placeholder: String = String(localized: "在歌单中搜索")
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .focused($isFocused)
                .font(.subheadline)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("playlistSearchBar")
    }
}

/// Search above the hero, static page chrome (Coda's PlaylistHeader).
struct PlaylistHeader<Hero: View>: View {
    @Binding var filter: String
    var placeholder: String = String(localized: "在歌单中搜索")
    @ViewBuilder var hero: () -> Hero

    var body: some View {
        VStack(spacing: 0) {
            PlaylistSearchBar(text: $filter, placeholder: placeholder)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            hero()
        }
    }
}

/// Three-button action row: glass star, black "播放" capsule, glass more.
/// (Coda's PlaylistPrimaryActions; the star shows a checkmark when saved.)
struct PlaylistPrimaryActions<More: View>: View {
    let isSaved: Bool
    let canSave: Bool
    let canPlay: Bool
    let isSaving: Bool
    let onToggleSaved: () -> Void
    let onPlayAll: () -> Void
    var leadingIcon: String? = nil
    var primaryTitle: LocalizedStringKey = "播放"
    var primaryIcon: String? = "play.fill"
    var showsSaveButton = true
    var saveAccessibilityLabel: String? = nil
    @ViewBuilder var more: () -> More

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if showsSaveButton {
                Button(action: onToggleSaved) {
                    Group {
                        if let leadingIcon {
                            Image(systemName: leadingIcon)
                        } else if isSaved {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "star")
                        }
                    }
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSave || isSaving)
                .accessibilityLabel(saveAccessibilityLabel
                    ?? (isSaved ? String(localized: "取消收藏") : String(localized: "收藏")))
            }

            Button(action: onPlayAll) {
                Group {
                    if let primaryIcon {
                        Label(primaryTitle, systemImage: primaryIcon)
                    } else {
                        Text(primaryTitle)
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 116, maxWidth: .infinity)
                .frame(height: 56)
                .foregroundStyle(colorScheme == .dark ? .black : .white)
                .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)

            more()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(maxWidth: 328)
        .padding(.horizontal, 16)
    }
}

/// The glass "more" button of the action row.
struct PlaylistMoreLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title2.weight(.semibold))
            .frame(width: 56, height: 56)
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
    }
}
