import AppKit
import SwiftUI
import CuttiKit

/// Builds a SwiftUI `AttributedString` for a subtitle cue, honoring per-run
/// style overrides. This is the preview-side analog of
/// `SubtitleBurnInRenderer.makeAttributedString` — both should produce
/// visually matching output so the preview is WYSIWYG with the export.
///
/// Not every `SubtitleRunStyle` field is applied at the SwiftUI layer:
/// - stroke (color + width): `Text` does not support per-range stroke;
///   the cue-level shadow already provides visual weight.
/// - `highlightBackground`: rendered as a plain rectangle via
///   `.backgroundColor`. Rounded pill geometry is deferred to the
///   authoring overlay (Phase 3.2) because SwiftUI `Text` has no hook
///   for drawing a rounded fill behind per-run glyphs. The burn-in
///   path does draw the pill correctly, so export ≠ preview for this
///   one detail — callers who need pixel parity should test against
///   export frames.
///
/// - Parameters:
///   - text: Plain cue text. Always used as the AttributedString payload.
///   - runs: Optional per-character-range style overrides. When nil the
///           helper returns a uniform AttributedString built from the
///           baseline attributes (same bytes as the old plain-`Text`
///           path). When non-nil and the concatenated `runs.text` does
///           not match `text` the helper falls back to uniform too —
///           the invariant is enforced by `SubtitleEntry.hasConsistentRuns`
///           but this keeps the preview honest if callers hand it
///           drifted data.
///   - baseFontSize: Scaled font size (the overlay already scales by
///           `videoRect.height / 1080`). Run `sizeMultiplier` values
///           multiply this.
///   - baseColor: Cue-level fill color (`style.textColor`).
///   - baseWeight: Cue-level weight (the overlay currently renders
///           monolingual lines `.bold`, secondary lines `.semibold`).
///           Runs whose `weight` field is non-nil override this.
@MainActor
func makeSubtitleAttributedString(
    text: String,
    runs: [SubtitleRun]?,
    baseFontSize: CGFloat,
    baseColor: NSColor,
    baseWeight: NSFont.Weight
) -> AttributedString {
    let ns = NSMutableAttributedString(
        string: text,
        attributes: baseAttributes(
            fontSize: baseFontSize, color: baseColor, weight: baseWeight)
    )

    guard let runs, !runs.isEmpty else {
        return AttributedString(ns)
    }

    // Back-stop drift check. SubtitleEntry.hasConsistentRuns guards
    // writes; this guards reads in case an upstream path ever forgets.
    let concatenated = runs.map(\.text).joined()
    guard concatenated == text else {
        return AttributedString(ns)
    }

    var cursor = 0
    let total = (text as NSString).length
    for run in runs {
        let len = (run.text as NSString).length
        guard len > 0, cursor + len <= total else {
            cursor += len
            continue
        }
        let range = NSRange(location: cursor, length: len)
        if !run.style.isEmpty {
            applyRunAttributes(
                run.style,
                to: ns,
                range: range,
                baseFontSize: baseFontSize,
                baseColor: baseColor,
                baseWeight: baseWeight
            )
        }
        cursor += len
    }

    return AttributedString(ns)
}

private func baseAttributes(
    fontSize: CGFloat,
    color: NSColor,
    weight: NSFont.Weight
) -> [NSAttributedString.Key: Any] {
    [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: color,
    ]
}

private func applyRunAttributes(
    _ style: SubtitleRunStyle,
    to attr: NSMutableAttributedString,
    range: NSRange,
    baseFontSize: CGFloat,
    baseColor: NSColor,
    baseWeight: NSFont.Weight
) {
    let mult = CGFloat(style.sizeMultiplier ?? 1.0)
    let size = max(1, baseFontSize * mult)
    let weight = style.weight.map(weightToNSFontWeight) ?? baseWeight

    let font: NSFont
    if let family = style.fontName,
       let named = NSFontManager.shared.font(
           withFamily: family,
           traits: style.weight?.isBoldish == true ? .boldFontMask : [],
           weight: style.weight?.nsFontManagerWeight ?? 5,
           size: size)
    {
        font = named
    } else {
        font = NSFont.systemFont(ofSize: size, weight: weight)
    }
    attr.addAttribute(.font, value: font, range: range)

    if let color = style.textColor {
        attr.addAttribute(
            .foregroundColor,
            value: NSColor(srgbRed: color.red, green: color.green,
                           blue: color.blue, alpha: color.alpha),
            range: range
        )
    }

    if style.underline == true {
        attr.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: range
        )
        if let color = style.textColor {
            attr.addAttribute(
                .underlineColor,
                value: NSColor(srgbRed: color.red, green: color.green,
                               blue: color.blue, alpha: color.alpha),
                range: range
            )
        }
    }

    // highlightBackground maps to AttributedString's native
    // .backgroundColor, which SwiftUI's Text renders as a rectangle
    // behind the glyphs. Not a rounded pill like the burn-in path —
    // that would require a custom authoring overlay — but the color
    // still shows up so the preview isn't blank. Pixel-perfect pill
    // geometry is deferred to the Phase 3.2 authoring overlay.
    if let bg = style.highlightBackground, bg.alpha > 0.001 {
        attr.addAttribute(
            .backgroundColor,
            value: NSColor(srgbRed: bg.red, green: bg.green,
                           blue: bg.blue, alpha: bg.alpha),
            range: range
        )
    }
}

private func weightToNSFontWeight(_ w: SubtitleRunStyle.Weight) -> NSFont.Weight {
    switch w {
    case .regular:  return .regular
    case .medium:   return .medium
    case .semibold: return .semibold
    case .bold:     return .bold
    case .heavy:    return .heavy
    case .black:    return .black
    }
}

private extension SubtitleRunStyle.Weight {
    /// NSFontManager uses a 0-15 scale. 5 = regular, 9 = bold. Kept in sync
    /// with the mapping in `SubtitleBurnInRenderer` so both paths pick the
    /// same concrete font.
    var nsFontManagerWeight: Int {
        switch self {
        case .regular:  return 5
        case .medium:   return 6
        case .semibold: return 8
        case .bold:     return 9
        case .heavy:    return 10
        case .black:    return 11
        }
    }

    var isBoldish: Bool {
        switch self {
        case .regular, .medium, .semibold: return false
        case .bold, .heavy, .black:        return true
        }
    }
}
