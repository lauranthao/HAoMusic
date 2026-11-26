import SwiftUI

#if os(iOS)
import UIKit

/// Loads and caches the current wallpaper image.
///
/// The image is read from disk once — on appear and whenever the switch or
/// the picked file changes — never during body evaluation. Views read the
/// cached image; a missing file (deleted in Files, say) simply yields no
/// wallpaper instead of a broken state.
@MainActor
final class WallpaperImageLoader: ObservableObject {
    static let shared = WallpaperImageLoader()

    @Published private(set) var image: UIImage?

    func refresh() {
        let settings = SettingsManager.shared
        guard settings.wallpaperEnabled,
              let url = WallpaperStore.fileURL(for: settings.wallpaperCurrent) else {
            image = nil
            return
        }
        image = UIImage(contentsOfFile: url.path)
    }
}

/// The wallpaper photo plus a readability veil, drawn as a background layer
/// behind the app's content.
///
/// A background layer only: it is never part of the layout flow, so enabling
/// or disabling it cannot move the mini player, the tab bar, or any safe-area
/// inset. With no image it renders nothing and the system background shows
/// through, exactly as before.
struct WallpaperBackgroundView: View {
    let image: UIImage?

    @Environment(\.colorScheme) private var colorScheme

    /// The veil washes the photo out just enough for text to stay readable
    /// in both schemes; the photo is still visible through it.
    private var veil: Color {
        colorScheme == .dark ? .black : .white
    }

    private var veilOpacity: Double {
        colorScheme == .dark ? 0.5 : 0.55
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                veil
                    .opacity(veilOpacity)
                    .ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
