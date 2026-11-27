import SwiftUI
import CoreGraphics

#if os(macOS)
import AppKit
#endif

/// Artwork-driven page background, the way Coda does it: a detail page takes
/// its background from its hero artwork — artist avatar, album or playlist
/// cover, or the first track's cover. The average color, mixed toward neutral,
/// fills the page; the blurred artwork floats over it at low opacity under a
/// top-to-bottom scrim; and the page's foreground scheme flips dark/light by
/// the artwork's luminance, so titles, rows and the navigation bar stay
/// readable on any cover.
///
/// Cheap by design: one 160px download per artwork URL, one 1x1 average,
/// results cached (80 entries / 12 MB), all loading off the main thread;
/// the view only swaps in the finished colors.
final class DetailArtworkAssets: @unchecked Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let isDark: Bool
    /// Downscaled to 160px: only the blurred layer needs the pixels.
    let blurredImage: PlatformImage?

    init(red: Double, green: Double, blue: Double, isDark: Bool, blurredImage: PlatformImage?) {
        self.red = red
        self.green = green
        self.blue = blue
        self.isDark = isDark
        self.blurredImage = blurredImage
    }

    static func fallback(dark: Bool) -> DetailArtworkAssets {
        let value = DetailArtworkMath.fallbackValue(dark: dark)
        return DetailArtworkAssets(red: value, green: value, blue: value,
                                   isDark: dark, blurredImage: nil)
    }

    var background: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

actor DetailArtworkProvider {
    static let shared = DetailArtworkProvider()

    private final class Box: NSObject {
        let assets: DetailArtworkAssets
        init(_ assets: DetailArtworkAssets) { self.assets = assets }
    }

    private let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 80
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    func cachedAssets(for url: URL) -> DetailArtworkAssets? {
        cache.object(forKey: url as NSURL)?.assets
    }

    func assets(for url: URL) async -> DetailArtworkAssets? {
        if let cached = cache.object(forKey: url as NSURL) { return cached.assets }
        do {
            let (data, _) = try await URLSession.shared.data(from: smallArtworkURL(url))
            try Task.checkCancellation()
            guard let image = PlatformImage(data: data),
                  let cgImage = image.cgImageRef,
                  let average = Self.averageColor(of: cgImage) else { return nil }
            let mixed = DetailArtworkMath.mixed(red: average.red, green: average.green, blue: average.blue)
            let dark = DetailArtworkMath.isDark(red: average.red, green: average.green, blue: average.blue)
            let small = Self.downscaled(cgImage, maxDimension: 160) ?? cgImage
            let assets = DetailArtworkAssets(
                red: mixed.red, green: mixed.green, blue: mixed.blue,
                isDark: dark, blurredImage: Self.platformImage(from: small))
            cache.setObject(Box(assets), forKey: url as NSURL,
                            cost: small.width * small.height * 4)
            return assets
        } catch {
            return nil
        }
    }

    /// NetEase's image CDN serves any size via `param`; 160px is all the
    /// average and the blurred layer need. Other hosts get the URL as-is.
    private func smallArtworkURL(_ url: URL) -> URL {
        guard url.host?.hasSuffix(".music.126.net") == true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name.caseInsensitiveCompare("param") == .orderedSame }
        items.append(URLQueryItem(name: "param", value: "160y160"))
        components.queryItems = items
        return components.url ?? url
    }

    /// The image's average color: draw it into a 1x1 bitmap and read the pixel.
    private static func averageColor(of cgImage: CGImage) -> (red: Double, green: Double, blue: Double)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }

    private static func downscaled(_ cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(width, height))
        let targetWidth = max(1, Int(width * scale)), targetHeight = max(1, Int(height * scale))
        guard let context = CGContext(
            data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private static func platformImage(from cgImage: CGImage) -> PlatformImage? {
        #if os(macOS)
        return PlatformImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return PlatformImage(cgImage: cgImage)
        #endif
    }
}

struct DetailArtworkBackground: ViewModifier {
    let artworkURL: String?
    var enabled = true
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var assets: DetailArtworkAssets?
    @State private var backgroundID = 0
    @State private var foregroundScheme: ColorScheme?

    private var palette: DetailArtworkAssets {
        assets ?? .fallback(dark: systemScheme == .dark)
    }

    /// No artwork, no background: the page keeps its existing surface.
    private var isActive: Bool { enabled && artworkURL != nil }

    func body(content: Content) -> some View {
        content
            .background {
                if isActive {
                    GeometryReader { geometry in
                        ZStack {
                            // Keep the base opaque while the artwork layer dissolves in.
                            DetailArtworkAssets.fallback(dark: systemScheme == .dark).background
                            artworkLayer(palette, size: geometry.size)
                                .id(backgroundID)
                                // Keep the outgoing layer opaque until the incoming
                                // layer covers it, avoiding a gray dip mid-dissolve.
                                .transition(reduceMotion ? .identity : .asymmetric(
                                    insertion: .opacity,
                                    removal: .opacity.animation(.linear(duration: 0.001).delay(0.55))))
                                .zIndex(Double(backgroundID))
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                }
            }
            .environment(\.colorScheme, isActive ? (foregroundScheme ?? systemScheme) : systemScheme)
            #if os(iOS)
            .toolbarColorScheme(isActive ? (foregroundScheme ?? systemScheme) : systemScheme,
                                for: .navigationBar, .tabBar)
            #endif
            .task(id: artworkURL ?? "") {
                guard isActive,
                      let url = artworkURL.flatMap(URL.init(string:)) else { return }
                let provider = DetailArtworkProvider.shared
                let cached = await provider.cachedAssets(for: url)
                let loaded: DetailArtworkAssets?
                let fromCache: Bool
                if let cached {
                    loaded = cached
                    fromCache = true
                } else {
                    loaded = await provider.assets(for: url)
                    fromCache = false
                }
                guard !Task.isCancelled, let loaded else { return }
                // A cache hit on first presentation needs no delayed reveal.
                let duration = assets == nil ? 0.4 : 0.55
                let animation: Animation? = reduceMotion || (assets == nil && fromCache)
                    ? nil : .timingCurve(0.25, 0, 0.2, 1, duration: duration)
                withAnimation(animation) {
                    assets = loaded
                    backgroundID += 1
                }
                // The scheme flip itself never animates: text must not sit
                // mid-fade on the wrong background.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    foregroundScheme = loaded.isDark ? .dark : .light
                }
            }
    }

    private func artworkLayer(_ palette: DetailArtworkAssets, size: CGSize) -> some View {
        ZStack {
            palette.background
            if let image = palette.blurredImage {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 18)
                    .frame(width: size.width, height: size.height)
                    .opacity(0.22)
            }
            LinearGradient(colors: palette.isDark
                ? [.black.opacity(0.08), .black.opacity(0.24), .black.opacity(0.40)]
                : [.white.opacity(0.06), .white.opacity(0.16), .white.opacity(0.30)],
                startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

extension View {
    /// Tints a detail page from its hero artwork. Pass nil and the page is
    /// untouched.
    func detailArtworkBackground(_ artworkURL: String?) -> some View {
        modifier(DetailArtworkBackground(artworkURL: artworkURL))
    }
}
