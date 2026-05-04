import AppKit
import SwiftUI

/// Centralized design tokens for the redesigned Settings window. Mirrors
/// the `SET` palette + typography + spacing constants from the
/// Obsidian-Pro mockup (`/Users/jay/Downloads/clip2/settings-obsidian.jsx`).
///
/// All colors are sRGB hex equivalents of the mockup's oklch values —
/// SwiftUI's `Color` doesn't understand oklch directly, so the eye-dropper
/// values from a rendered preview were used.
///
/// All fonts go through `SettingsTheme.font(...)` so a single tweak to
/// the bundled font family or fallback list propagates everywhere.
enum SettingsTheme {

    // MARK: - Palette

    /// Neutral surfaces, going from bottom (deepest) to top (highlighted).
    static let bg          = Color(hex: 0x0B0B0D)
    static let panel       = Color(hex: 0x131316)
    static let panel2      = Color(hex: 0x1A1A1F)
    static let panel3      = Color(hex: 0x222228)
    static let panel4      = Color(hex: 0x2A2A32)

    /// Borders matched to the panels they typically sit on top of.
    static let border      = Color(hex: 0x26262D)
    static let borderSoft  = Color(hex: 0x1D1D22)

    /// Foreground text tiers.
    static let text        = Color(hex: 0xE7E5E0)  // primary
    static let textDim     = Color(hex: 0x9A9893)  // secondary
    static let textFaint   = Color(hex: 0x5E5C57)  // tertiary / footnote

    /// Brand / accent — warm amber matching the mockup's accent token.
    static let accent      = Color(hex: 0xE5B071)  // oklch(0.75 0.14 70)
    static let accentDeep  = Color(hex: 0xA17345)  // oklch(0.55 0.14 70)
    /// 12% accent over the panel for selected states / highlight cards.
    static let accentSoft  = Color(hex: 0xE5B071, opacity: 0.12)

    /// Semantic colors.
    static let red         = Color(hex: 0xE5484D)
    static let green       = Color(hex: 0x30A46C)
    static let amber       = Color(hex: 0xF5A524)
    /// Soft amber used for warning callouts.
    static let amberSoft   = Color(hex: 0xF5A524, opacity: 0.10)
    static let violet      = Color(hex: 0xB392E5)  // oklch(0.7 0.16 290)

    /// Per-feature usage chart colors. Picked to match the mockup palette.
    static let chartFirstCut = accent
    static let chartCreative = violet
    static let chartAgent    = Color(hex: 0x6FCAD9)   // oklch(0.7 0.14 200)
    static let chartTranslate = Color(hex: 0x70CFA0)  // oklch(0.7 0.14 160)
    static let chartImage    = Color(hex: 0xE6A37A)   // oklch(0.72 0.16 30)
    static let chartOverlay  = Color(hex: 0xCFA0CF)   // oklch(0.7 0.13 320)
    static let chartOther    = textFaint

    // MARK: - Typography

    /// Bundled UI sans-serif. Falls back to system if registration failed.
    static let uiFamily   = "Inter"
    /// Bundled monospaced. Falls back to SF Mono if registration failed.
    static let monoFamily = "JetBrainsMono-Regular"

    /// Returns an Inter at the given size + weight. `weight` accepts the
    /// SwiftUI weight enum but only `.regular`, `.medium`, `.semibold`
    /// are bundled — heavier weights silently fall back to `.semibold`.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium:                   name = "Inter-Medium"
        case .semibold, .bold, .heavy, .black: name = "Inter-SemiBold"
        default:                        name = "Inter-Regular"
        }
        return Font.custom(name, size: size)
    }

    /// Returns a JetBrains Mono at the given size + weight.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: name = "JetBrainsMono-Medium"
        default:                                        name = "JetBrainsMono-Regular"
        }
        return Font.custom(name, size: size)
    }

    // Common typographic styles, named after their use-site rather than
    // a strict size grid so call sites stay readable.
    static var sectionTitle: Font     { ui(18, weight: .semibold) }
    static var sectionSub: Font       { ui(12) }
    static var groupTitle: Font       { ui(10.5, weight: .semibold) } // upper-cased at render
    static var rowLabel: Font         { ui(12.5, weight: .medium) }
    static var rowSub: Font           { ui(11) }
    static var bodyMedium: Font       { ui(12.5, weight: .medium) }
    static var bodyRegular: Font      { ui(12) }
    static var caption: Font          { ui(11) }
    static var captionFaint: Font     { ui(10.5) }
    static var monoSmall: Font        { mono(11) }
    static var monoTabular: Font      { mono(12.5).monospacedDigit() }
    static var monoBadge: Font        { mono(10.5) }

    // MARK: - Metrics

    /// Outer width of the sidebar column. Pinned with
    /// `.navigationSplitViewColumnWidth(...)` so users can't drag it.
    static let sidebarWidth: CGFloat = 200
    /// Window content size (system titlebar adds another ~28pt of
    /// chrome on top, giving the rendered window an effective height of
    /// roughly 720pt, matching the mockup).
    static let windowWidth: CGFloat = 820
    static let windowHeight: CGFloat = 692

    /// Outer detail-pane padding.
    static let detailPaddingH: CGFloat = 28
    static let detailPaddingV: CGFloat = 24
    /// Bottom padding is slightly generous so the last card never butts
    /// against the window edge during scroll-to-end.
    static let detailPaddingBottom: CGFloat = 32

    /// Card metrics.
    static let cardCornerRadius: CGFloat = 8
    static let cardPaddingH: CGFloat = 16
    static let cardPaddingV: CGFloat = 14

    /// Row metrics inside a Card (label column + content + divider).
    static let rowLabelWidth: CGFloat = 180
    static let rowMinHeight: CGFloat = 36
    static let rowVerticalPadding: CGFloat = 10

    /// Common control heights so primary / secondary buttons line up
    /// with field rows.
    static let controlHeightSmall: CGFloat = 24
    static let controlHeightMedium: CGFloat = 28
    static let controlHeightLarge: CGFloat = 34

    /// Standard radii for buttons / fields / pills.
    static let controlRadius: CGFloat = 6
    static let smallRadius: CGFloat = 4
    static let pillRadius: CGFloat = 3
}

// MARK: - Color helpers

extension Color {
    /// Convenience initializer for a 0xRRGGBB constant + optional opacity
    /// (defaults to 1.0). Avoids the verbose `Color(red:green:blue:)`
    /// pattern at every theme call site.
    fileprivate init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double((hex >>  0) & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Modifiers

extension View {
    /// Forces this subtree's color scheme + tint to match the Settings
    /// theme. Use on any modal sheet that should inherit the dark
    /// chrome regardless of the system appearance.
    func settingsThemed() -> some View {
        self
            .preferredColorScheme(.dark)
            .tint(SettingsTheme.accent)
            .foregroundStyle(SettingsTheme.text)
    }
}
