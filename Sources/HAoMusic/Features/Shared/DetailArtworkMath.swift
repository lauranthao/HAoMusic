/// Pure color math for artwork-driven page backgrounds.
///
/// Coda's DetailArtworkBackground approach, as a formula: the page takes its
/// background from the hero artwork's average color, mixed toward neutral so
/// text stays readable, and the page's foreground scheme flips dark/light by
/// the artwork's luminance. Import-free on purpose, so the formula can be
/// harness-tested on Linux.
enum DetailArtworkMath {
    /// Rec. 709 luminance.
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    static func isDark(red: Double, green: Double, blue: Double) -> Bool {
        luminance(red: red, green: green, blue: blue) < 0.52
    }

    /// Mixes an average artwork color toward neutral: dark art keeps 38% of
    /// its color over a near-black neutral, light art 30% over a near-white
    /// neutral. The result is the page background color.
    static func mixed(red: Double, green: Double, blue: Double) -> (red: Double, green: Double, blue: Double) {
        let dark = isDark(red: red, green: green, blue: blue)
        let sourceWeight = dark ? 0.38 : 0.30
        let neutral = dark ? 0.055 * 0.62 : 0.94 * 0.70
        return (
            red: red * sourceWeight + neutral,
            green: green * sourceWeight + neutral,
            blue: blue * sourceWeight + neutral
        )
    }

    /// Flat base shown while the artwork is still loading (or when it fails).
    static func fallbackValue(dark: Bool) -> Double { dark ? 0.16 : 0.88 }
}
