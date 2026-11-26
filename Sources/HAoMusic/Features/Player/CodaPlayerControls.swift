// Verbatim extracts from Coda (AGPL-3.0; HAo Music is AGPL-3.0, Coda is
// attributed in ThirdPartyNotices and the in-app licenses page).
// - PlayerSymbolTransition, PlayerSymbolBounce, PlayerTransportButtonStyle:
//   DesignSystem/ButtonStyles.swift
// - PlayerHeartIcon, PlayerFavoriteButton, PlayerVolumeIcon,
//   PlayerTransportControls, PlayerControlAppearance, PlayerTransportButton,
//   PlayerPlayPauseButton: Features/Player/PlayerBar.swift
// Coda's LikeButton and ScrubberLane from the same file were NOT copied:
// HAo already defines LikeButton, and the dock scrubber is not used here.
import SwiftUI

struct PlayerSymbolTransition: ViewModifier {
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace, options: .speed(1.6)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: symbol)
        } else {
            content
                .contentTransition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: symbol)
        }
    }
}

/// Only explicit user feedback advances this trigger; mounting a row never bounces.
struct PlayerSymbolBounce: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fallbackScale: CGFloat = 1
    @State private var fallbackTask: Task<Void, Never>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content
                .symbolEffect(.bounce, options: .speed(1.3), value: trigger)
                .symbolEffectsRemoved(reduceMotion)
        } else {
            content
                .scaleEffect(reduceMotion ? 1 : fallbackScale)
                .onChange(of: trigger) { _ in
                    fallbackTask?.cancel()
                    guard !reduceMotion else { fallbackScale = 1; return }
                    fallbackTask = Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.1)) { fallbackScale = 1.12 }
                        do { try await Task.sleep(for: .milliseconds(100)) }
                        catch { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { fallbackScale = 1 }
                    }
                }
                .onDisappear {
                    fallbackTask?.cancel()
                    fallbackTask = nil
                    fallbackScale = 1
                }
        }
    }
}

/// Feedback lives inside the existing hit area, so controls do not move or resize.
struct PlayerTransportButtonStyle: ButtonStyle {
    var diameter: CGFloat = 44
    var tint: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .background {
                Circle()
                    .fill(tint.opacity(configuration.isPressed ? 0.1 : 0))
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.1 : 0.24),
                       value: configuration.isPressed)
    }
}

struct PlayerHeartIcon: View {
    let liked: Bool
    var size: CGFloat = 22
    var tint: Color = .primary
    var feedbackTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: "heart")
                .opacity(liked ? 0 : 1)
            Image(systemName: "heart.fill")
                .foregroundStyle(Color(red: 1, green: 59 / 255.0, blue: 48 / 255.0))
                .opacity(liked ? 1 : 0)
        }
        .font(.system(size: size, weight: .regular))
        .foregroundStyle(tint)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: liked)
        .modifier(PlayerSymbolBounce(trigger: feedbackTrigger))
        .accessibilityHidden(true)
    }
}

/// Keep animation identity with the song; optimistic state changes only fade.
/// A single bounce confirms a completed favorite request from this button.
struct PlayerFavoriteButton: View {
    let trackID: Int?
    var size: CGFloat = 22
    var side: CGFloat = 44
    var tint: Color = .primary

    var body: some View {
        PlayerFavoriteButtonBody(trackID: trackID, size: size, side: side, tint: tint)
            .id(trackID)
    }
}

private struct PlayerFavoriteButtonBody: View {
    let trackID: Int?
    let size: CGFloat
    let side: CGFloat
    let tint: Color
    @EnvironmentObject private var account: AccountStore
    @State private var feedbackTrigger = 0
    @State private var isUpdating = false

    var body: some View {
        let liked = trackID.map { account.isLiked($0) } ?? false
        Button {
            guard let trackID, !isUpdating else { return }
            let session = account.sessionRevision
            isUpdating = true
            Task { @MainActor in
                defer { isUpdating = false }
                await account.toggleLike(trackID: trackID)
                if !liked, account.sessionRevision == session, account.isLiked(trackID) {
                    feedbackTrigger += 1
                }
            }
        } label: {
            PlayerHeartIcon(liked: liked, size: size, tint: tint, feedbackTrigger: feedbackTrigger)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(trackID == nil || !account.provider.supportsFavoriteChanges)
        .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
        .accessibilityValue(liked ? "已喜欢" : "未喜欢")
        .help(liked ? String(localized: "取消喜欢") : String(localized: "喜欢"))
    }
}


struct PlayerVolumeIcon: View {
    let volume: Double
    var size: CGFloat = 15

    private var symbol: String {
        switch volume {
        case ...0.001: return "speaker.slash.fill"
        case ..<0.35: return "speaker.wave.1.fill"
        case ..<0.7: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .modifier(PlayerSymbolTransition(symbol: symbol))
            .frame(width: 22)
            .accessibilityHidden(true)
    }
}


struct PlayerTransportControls: View {
    @EnvironmentObject private var player: PlayerService
    let width: CGFloat
    var height: CGFloat = 64

    private var glyphScale: CGFloat { min(1, width / 280) }

    private var orderIcon: String {
        #if os(macOS)
        player.queueOrder.symbolName
        #else
        "shuffle"
        #endif
    }

    private var orderActive: Bool {
        #if os(macOS)
        player.queueOrder != .listed
        #else
        player.shuffleEnabled
        #endif
    }

    private func cycleOrder() {
        #if os(macOS)
        player.cycleQueueOrder()
        #else
        player.toggleShuffle()
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            PlayerTransportButton(
                icon: player.isFMMode ? "trash" : orderIcon,
                label: player.isFMMode ? "不喜欢" : "随机播放",
                size: 17 * glyphScale, width: width / 5, height: height,
                active: !player.isFMMode && orderActive
            ) {
                if player.isFMMode { player.fmTrash() } else { cycleOrder() }
            }
            PlayerTransportButton(icon: "backward.fill", label: "上一首", size: 28 * glyphScale,
                                  width: width / 5, height: height, disabled: player.isFMMode, action: player.previous)
            PlayerPlayPauseButton(isPlaying: player.isPlaying, isLoading: player.showsPlaybackLoading,
                                  size: 40 * glyphScale, width: width / 5, height: height,
                                  action: player.togglePlayPause)
                .accessibilityIdentifier("iPadPlayPauseButton")
            PlayerTransportButton(icon: "forward.fill", label: "下一首", size: 28 * glyphScale,
                                  width: width / 5, height: height, action: player.next)
            PlayerTransportButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                                  label: "循环模式", size: 17 * glyphScale, width: width / 5, height: height,
                                  active: player.repeatMode != .off, disabled: player.isFMMode,
                                  action: player.cycleRepeatMode)
        }
    }
}

enum PlayerControlAppearance {
    static let tint: Color = .white
    static let barTint: Color = .primary
}

/// Shared transport appearance for full and docked playback controls.
struct PlayerTransportButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 28
    let width: CGFloat
    var tint: Color = PlayerControlAppearance.tint
    var height: CGFloat = 64
    var active = false
    var disabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .modifier(PlayerSymbolTransition(symbol: icon))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: width, height: height)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(active ? 0.14 : 0))
                        .frame(width: min(width, size + 16), height: min(height, size + 12))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerTransportButtonStyle(diameter: min(width, height, size + 16), tint: tint))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: active)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(Text(label))
        .accessibilityValue(active ? "已开启" : "")
    }
}

struct PlayerPlayPauseButton: View {
    let isPlaying: Bool
    let isLoading: Bool
    var size: CGFloat = 40
    let width: CGFloat
    var tint: Color = PlayerControlAppearance.tint
    var height: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: size, weight: .semibold))
                        .modifier(PlayerSymbolTransition(symbol: isPlaying ? "pause.fill" : "play.fill"))
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .foregroundStyle(tint)
        }
        .buttonStyle(PlayerTransportButtonStyle(diameter: min(width, height, size + 16), tint: tint))
        .accessibilityLabel(isLoading ? "正在加载" : (isPlaying ? "暂停" : "播放"))
    }
}
