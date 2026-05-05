import SwiftUI
import CuttiKit

// MARK: - Hex color helper
// Tiny utility so we can use the Radix palette values verbatim
// (e.g. `Color(hex: 0x212225)`) instead of translating every
// value into three 0.0–1.0 components by hand.
private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8)  & 0xff) / 255
        let b = Double((hex >> 0)  & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Central design tokens for the editor shell.
///
/// Themed **Obsidian Pro**: near-black surfaces, amber accent, muted
/// warm-tinted text. Colours are derived from an internal Obsidian Pro
/// reference palette; OKLCH values are converted to the closest sRGB
/// approximation below.
///
/// The token _names_ (app/panel/surface/hover/…) are intentionally
/// identical to the previous Radix Slate palette so every call site in
/// the codebase keeps compiling without edits — only the underlying
/// values change.
enum EditorShellStyle {

    // MARK: - Obsidian raw palette (near-black warm greys)
    // Mirrors the OB.* constants in editor-obsidian.jsx.
    static let obBg         = Color(hex: 0x0b0b0d) // app background
    static let obPanel      = Color(hex: 0x131316) // sidebar / header panel
    static let obPanel2     = Color(hex: 0x1a1a1f) // surface on panel
    static let obPanel3     = Color(hex: 0x222228) // selected / pressed surface
    static let obBorder     = Color(hex: 0x26262d) // default border
    static let obBorderSoft = Color(hex: 0x1d1d22) // hairline / separator
    static let obText       = Color(hex: 0xe7e5e0) // primary text (warm)
    static let obTextDim    = Color(hex: 0x9a9893) // secondary
    static let obTextFaint  = Color(hex: 0x5e5c57) // tertiary / placeholder

    /// Amber solid accent — sRGB approximation of
    /// `oklch(0.75 0.14 70)` used throughout the Obsidian reference.
    static let obAccent       = Color(hex: 0xd69a4d)
    static let obAccentHover  = Color(hex: 0xe6ac5c)
    static let obAccentSoft   = Color(hex: 0xd69a4d).opacity(0.15)

    // Track colours (video / audio / subtitle lanes)
    static let obV1  = Color(hex: 0x5497b5) // video 1 — cyan-blue
    static let obV2  = Color(hex: 0x5ba28d) // video 2 — teal
    static let obA1  = Color(hex: 0x9e85c7) // audio   — lavender
    static let obSub = Color(hex: 0xd8c46c) // subtitle — warm yellow
    static let obRed   = Color(hex: 0xe5484d)
    static let obGreen = Color(hex: 0x30a46c)

    // MARK: - Radix Slate Dark (legacy back-compat aliases)
    //
    // A handful of files reference `slate1` … `slate12` directly. We
    // keep those symbols so they compile, but remap them onto the
    // Obsidian palette so the theme stays consistent everywhere.
    static let slate1  = obBg
    static let slate2  = obPanel
    static let slate3  = obPanel2
    static let slate4  = obPanel3
    static let slate5  = obPanel3
    static let slate6  = obBorderSoft
    static let slate7  = obBorder
    static let slate8  = obBorder
    static let slate9  = obTextFaint
    static let slate10 = obTextDim
    static let slate11 = obTextDim
    static let slate12 = obText

    // MARK: - Legacy Blue accent aliases (remapped to amber)
    static let blue3   = obAccentSoft
    static let blue4   = obAccentSoft
    static let blue5   = obAccent.opacity(0.25)
    static let blue6   = obAccent.opacity(0.35)
    static let blue7   = obAccent.opacity(0.5)
    static let blue8   = obAccent.opacity(0.65)
    static let blue9   = obAccent
    static let blue10  = obAccentHover
    static let blue11  = obAccent
    static let blue12  = obAccentHover

    // MARK: - Semantic aliases (what views should reach for)

    /// Deepest background — the root editor shell canvas.
    static let backgroundApp       = obBg
    /// Secondary panel surface — side panels, sidebars.
    static let backgroundPanel     = obPanel
    /// Default background for interactive surfaces (buttons, cards,
    /// chips) sitting on top of a panel.
    static let backgroundSurface   = obPanel2
    /// Hover state for interactive surfaces.
    static let backgroundHover     = obPanel3
    /// Active / selected / pressed state for interactive surfaces.
    static let backgroundSelected  = obPanel3
    /// Deepest surface — video viewer letterbox, code blocks.
    static let backgroundInset     = Color(hex: 0x060607)

    /// Subtle 1px separator between layout regions that aren't
    /// interactive (chrome seams, header underlines).
    static let borderSubtle        = obBorderSoft
    /// Default 1px border for interactive components (inputs, cards).
    static let borderDefault       = obBorder
    /// Emphasised border for focused / pressed state and focus rings.
    static let borderStrong        = obAccent.opacity(0.6)

    /// High-contrast body text.
    static let textPrimary         = obText
    /// Low-contrast text for captions, labels, secondary info.
    static let textSecondary       = obTextDim
    /// Tertiary hints, placeholders, disabled labels.
    static let textTertiary        = obTextFaint

    /// Brand accent for primary actions and selected state fills.
    static let accentSolid         = obAccent
    /// Accent hover.
    static let accentSolidHover    = obAccentHover
    /// Tinted accent surface — subtle background for "this card is
    /// selected / in focus" without shouting.
    static let accentSurface       = obAccentSoft
    /// Accent text — e.g. a link, or an important small label.
    static let accentText          = obAccent

    /// Destructive action colour — delete, error, overrun.
    static let destructiveSolid    = obRed
    /// Success / ready state colour.
    static let successSolid        = obGreen
    /// Warning / attention colour (warm yellow).
    static let warningSolid        = obSub

    // MARK: - Spacing scale (4-based, Geist convention)
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24
    static let space6: CGFloat = 32

    // MARK: - Radius scale
    /// Tight radius for inputs, chips, one-line controls.
    static let radiusSmall:  CGFloat = 4
    /// Default radius for buttons, cards, tool bubbles.
    static let radiusMedium: CGFloat = 8
    /// Large radius for the main editor panels.
    static let radiusLarge:  CGFloat = 10

    // MARK: - Typography
    // Use SF Pro (system font) at fixed sizes with explicit weights.
    // Pro tools keep the type scale narrow — body + caption do 90%
    // of the work, titles are rare and deliberate.
    static let titleFont   = Font.system(size: 15, weight: .semibold)
    static let subtitleFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont    = Font.system(size: 13, weight: .regular)
    static let labelFont   = Font.system(size: 12, weight: .medium)
    static let captionFont = Font.system(size: 11, weight: .regular)
    static let monoFont    = Font.system(size: 11, weight: .regular, design: .monospaced)

    // MARK: - Elevation / shadows
    //
    // Dark UIs lean on color contrast more than shadow, but a very
    // subtle ambient shadow still helps floating surfaces (sheets,
    // menus) feel distinct from the panels behind them.
    static let shadow1Color  = Color.black.opacity(0.18)
    static let shadow1Radius: CGFloat = 4
    static let shadow1Y:      CGFloat = 1

    static let shadow2Color  = Color.black.opacity(0.28)
    static let shadow2Radius: CGFloat = 12
    static let shadow2Y:      CGFloat = 4

    // MARK: - Transition timing
    static let transitionFast: Double = 0.12
    static let transitionMedium: Double = 0.18

    // MARK: - Layout constants (unchanged — referenced widely)
    static let browserWidth: CGFloat = 320
    static let inspectorWidth: CGFloat = 320
    static let timelineHeight: CGFloat = 236
    static let commandBarHeight: CGFloat = 64
    static let agentStripHeight: CGFloat = 34

    // MARK: - Back-compat aliases
    //
    // The rest of the codebase still refers to these symbols; keep
    // them working and point them at the new semantic tokens. New
    // code should reach for the semantic names directly.
    static let appBackground         = backgroundApp
    static let chromeBackground      = backgroundSurface
    static let panelBackground       = backgroundPanel
    static let stageBackground       = backgroundInset
    static let panelInsetBackground  = backgroundPanel
    /// Warning banner background — desaturated orange so it reads as
    /// "attention, not emergency". Mapped from Radix Orange dark ~4.
    static let warningBackground     = Color(hex: 0x4e2a0d)
    static let divider               = borderSubtle
    static let subtleBorder          = borderDefault
    static let accent                = accentSolid
    static let panelRadius: CGFloat  = radiusLarge
    static let panelPadding: CGFloat = space4
    /// Leading inset reserved for the macOS traffic-light buttons
    /// (close / minimize / zoom) when running with
    /// `.windowStyle(.hiddenTitleBar)`. Three 14×14 buttons + their
    /// inter-button gaps live in the top-left of the window content
    /// area; topbars that sit at y=0 must shift their content right
    /// by this amount so the back / project / brand chips don't slide
    /// underneath the buttons.
    static let trafficLightInset: CGFloat = 80

    // MARK: - Agent tone colours
    // Kept as distinct "status" hues — these are semantic (working /
    // idle / ready) rather than generic palette steps.
    static let agentIdle    = obTextDim
    static let agentWorking = obAccent
    static let agentReady   = obGreen

    // MARK: - Timeline marker colours
    static let timelineScene = obV1

    // MARK: - Track / lane colours (used by chips, pills, labels)
    /// Primary video lane colour (V1, V2…).
    static let timelineVideoTrack    = obV1
    /// Secondary / B-roll video lane colour.
    static let timelineVideoTrackAlt = obV2
    /// Audio lane colour.
    static let timelineAudioTrack    = obA1
    /// Subtitle / caption lane colour.
    static let timelineSubtitleTrack = obSub

    // MARK: - Timeline pill / ruler / playhead tokens
    //
    // Mirrors Final Cut Pro for iPad: video clips are navy-blue tinted
    // filmstrips with rounded corners, the playhead is a white
    // "lollipop" (vertical line + rounded handle), and the ruler uses
    // subtle white ticks on a near-black background. Keeping these
    // centralised so the primary + overlay tracks stay in sync when
    // the palette is tweaked.

    /// Clip corner radius — Obsidian clips are tight 3px pills, not
    /// chunky 6px rounded rectangles.
    static let timelineClipRadius: CGFloat = 3
    /// Lane-color wash laid over each clip. Obsidian uses a 20%
    /// alpha tint in the track's own color so V1 reads blue, V2
    /// teal, audio lavender, etc. We keep the token name generic;
    /// per-lane code paths can reach for specific track colours.
    static let timelineClipTint = obV1.opacity(0.2)
    /// Default clip border — lane colour at 55% alpha, 1px, matches
    /// the Obsidian reference's `${color}88` stroke.
    static let timelineClipBorder = obV1.opacity(0.55)
    /// Selected-clip border — amber accent 1.5px (Obsidian refs
    /// selected clips this way; any thicker and the selection
    /// overpowers the clip's own content).
    static let timelineClipBorderSelected = obAccent
    static let timelineClipBorderSelectedWidth: CGFloat = 1.5
    /// Track area background — slightly darker than the panel so the
    /// track wells read as distinct from the toolbar / chrome above.
    static let timelineTrackBackground = obBg
    /// Ruler tick colors — minor ticks subtle, major ticks + timecode
    /// labels a touch stronger.
    static let timelineRulerTick      = obBorder
    static let timelineRulerTickMajor = obTextDim.opacity(0.7)
    static let timelineRulerText      = obTextFaint
    /// Playhead color — red scrubbing line matching the Obsidian
    /// reference. Red pops against the muted blue/teal/lavender
    /// track tints without fighting the amber accent used for
    /// primary actions and selection.
    static let timelinePlayhead       = obRed

    /// Darker tint at the top of each clip holding the clip name
    /// and any effects badge. Uses the V1 lane colour at 35%.
    static let timelineClipTitleBar   = obV1.opacity(0.35)
    /// Height of that title bar. Sized so the filmstrip still
    /// reads clearly underneath at normal timeline zoom.
    static let timelineClipTitleHeight: CGFloat = 16
    /// Gap reserved between adjacent clips so they render as a
    /// chain of discrete pills instead of one long strip.
    static let timelineClipGap: CGFloat = 2
}

