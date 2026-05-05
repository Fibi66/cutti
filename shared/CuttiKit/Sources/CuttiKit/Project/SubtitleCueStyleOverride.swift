import Foundation

/// Per-cue override on top of the project-wide `SubtitleStyle`. Holds
/// only the *visual* fields a user might want to vary between cues —
/// font, colors, background, position, alignment, padding, shadow,
/// stroke. Bilingual locale fields are deliberately excluded: they
/// describe how *every* cue looks (which translation key to read,
/// how to stack the two lines), so they belong on the project-wide
/// `SubtitleStyle.bilingual` and don't make sense per-cue.
///
/// Apply order at render time:
/// 1. Start from the project-wide `SubtitleStyle`.
/// 2. Layer the cue's `styleOverride?.applied(to:)` on top.
/// 3. Render.
///
/// A `nil` override means "render this cue exactly like the rest of
/// the project". An empty (`hasAnyField == false`) override is also
/// treated as nil — `applySubtitleStylePatch` shrinks empty overrides
/// back to nil so unchanged cues don't carry persistence weight.
public struct SubtitleCueStyleOverride: Codable, Equatable, Sendable {
    public var fontName: String?
    public var fontSizePoints: Double?
    public var textColor: SubtitleStyle.RGBAColor?
    public var strokeColor: SubtitleStyle.RGBAColor?
    public var strokeWidthFraction: Double?
    public var backgroundColor: SubtitleStyle.RGBAColor?
    public var backgroundPaddingHorizontal: Double?
    public var backgroundPaddingVertical: Double?
    public var cornerRadius: Double?
    public var verticalPositionFraction: Double?
    public var horizontalPositionFraction: Double?
    public var alignment: SubtitleStyle.Alignment?
    public var maxWidthFraction: Double?
    public var shadowBlurRadius: Double?
    public var shadowColor: SubtitleStyle.RGBAColor?
    public var shadowOffsetY: Double?

    public init(
        fontName: String? = nil,
        fontSizePoints: Double? = nil,
        textColor: SubtitleStyle.RGBAColor? = nil,
        strokeColor: SubtitleStyle.RGBAColor? = nil,
        strokeWidthFraction: Double? = nil,
        backgroundColor: SubtitleStyle.RGBAColor? = nil,
        backgroundPaddingHorizontal: Double? = nil,
        backgroundPaddingVertical: Double? = nil,
        cornerRadius: Double? = nil,
        verticalPositionFraction: Double? = nil,
        horizontalPositionFraction: Double? = nil,
        alignment: SubtitleStyle.Alignment? = nil,
        maxWidthFraction: Double? = nil,
        shadowBlurRadius: Double? = nil,
        shadowColor: SubtitleStyle.RGBAColor? = nil,
        shadowOffsetY: Double? = nil
    ) {
        self.fontName = fontName
        self.fontSizePoints = fontSizePoints
        self.textColor = textColor
        self.strokeColor = strokeColor
        self.strokeWidthFraction = strokeWidthFraction
        self.backgroundColor = backgroundColor
        self.backgroundPaddingHorizontal = backgroundPaddingHorizontal
        self.backgroundPaddingVertical = backgroundPaddingVertical
        self.cornerRadius = cornerRadius
        self.verticalPositionFraction = verticalPositionFraction
        self.horizontalPositionFraction = horizontalPositionFraction
        self.alignment = alignment
        self.maxWidthFraction = maxWidthFraction
        self.shadowBlurRadius = shadowBlurRadius
        self.shadowColor = shadowColor
        self.shadowOffsetY = shadowOffsetY
    }

    // MARK: - Codable (custom for back-compat across field additions)

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSizePoints, textColor
        case strokeColor, strokeWidthFraction
        case backgroundColor, backgroundPaddingHorizontal, backgroundPaddingVertical
        case cornerRadius
        case verticalPositionFraction, horizontalPositionFraction
        case alignment, maxWidthFraction
        case shadowBlurRadius, shadowColor, shadowOffsetY
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        fontSizePoints = try c.decodeIfPresent(Double.self, forKey: .fontSizePoints)
        textColor = try c.decodeIfPresent(SubtitleStyle.RGBAColor.self, forKey: .textColor)
        strokeColor = try c.decodeIfPresent(SubtitleStyle.RGBAColor.self, forKey: .strokeColor)
        strokeWidthFraction = try c.decodeIfPresent(Double.self, forKey: .strokeWidthFraction)
        backgroundColor = try c.decodeIfPresent(SubtitleStyle.RGBAColor.self, forKey: .backgroundColor)
        backgroundPaddingHorizontal = try c.decodeIfPresent(Double.self, forKey: .backgroundPaddingHorizontal)
        backgroundPaddingVertical = try c.decodeIfPresent(Double.self, forKey: .backgroundPaddingVertical)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
        verticalPositionFraction = try c.decodeIfPresent(Double.self, forKey: .verticalPositionFraction)
        horizontalPositionFraction = try c.decodeIfPresent(Double.self, forKey: .horizontalPositionFraction)
        alignment = try c.decodeIfPresent(SubtitleStyle.Alignment.self, forKey: .alignment)
        maxWidthFraction = try c.decodeIfPresent(Double.self, forKey: .maxWidthFraction)
        shadowBlurRadius = try c.decodeIfPresent(Double.self, forKey: .shadowBlurRadius)
        shadowColor = try c.decodeIfPresent(SubtitleStyle.RGBAColor.self, forKey: .shadowColor)
        shadowOffsetY = try c.decodeIfPresent(Double.self, forKey: .shadowOffsetY)
    }

    // MARK: - Apply

    /// Returns a new `SubtitleStyle` with this override's non-nil
    /// fields layered on top of `base`. Numeric fields are clamped
    /// to the same ranges `SubtitleStylePatch.applyReporting` uses,
    /// so the renderer never sees an off-canvas / huge value even
    /// if a future caller produces a degenerate override.
    public func applied(to base: SubtitleStyle) -> SubtitleStyle {
        var out = base
        if let fontName, !fontName.isEmpty { out.fontName = fontName }
        if let fontSizePoints {
            out.fontSizePoints = clamp(fontSizePoints, 12, 200)
        }
        if let textColor { out.textColor = textColor }
        if let strokeColor { out.strokeColor = strokeColor }
        if let strokeWidthFraction {
            out.strokeWidthFraction = clamp(strokeWidthFraction, 0, 1)
        }
        if let backgroundColor { out.backgroundColor = backgroundColor }
        if let backgroundPaddingHorizontal {
            out.backgroundPaddingHorizontal = max(0, backgroundPaddingHorizontal)
        }
        if let backgroundPaddingVertical {
            out.backgroundPaddingVertical = max(0, backgroundPaddingVertical)
        }
        if let cornerRadius {
            out.cornerRadius = max(0, cornerRadius)
        }
        if let verticalPositionFraction {
            out.verticalPositionFraction = clamp(verticalPositionFraction, 0, 1)
        }
        if let horizontalPositionFraction {
            out.horizontalPositionFraction = clamp(horizontalPositionFraction, 0, 1)
        }
        if let alignment { out.alignment = alignment }
        if let maxWidthFraction {
            out.maxWidthFraction = clamp(maxWidthFraction, 0.1, 1.0)
        }
        if let shadowBlurRadius {
            out.shadowBlurRadius = max(0, shadowBlurRadius)
        }
        if let shadowColor { out.shadowColor = shadowColor }
        if let shadowOffsetY { out.shadowOffsetY = shadowOffsetY }
        // The `presetID` of the resulting style is intentionally
        // *kept from base*. An overridden cue isn't a preset — but
        // the un-overridden fields should still report whatever
        // preset the project is on, so the inspector can show
        // "preset: X (modified for this cue)" if it ever wants to.
        return out
    }

    // MARK: - Field-level merge

    /// Returns a new override where `other`'s non-nil fields win.
    /// Used by the inspector to merge a single-field tweak (built
    /// as a fresh override with only one property set) into the
    /// cue's existing override without erasing the other fields
    /// the user had previously set.
    public func merging(_ other: SubtitleCueStyleOverride) -> SubtitleCueStyleOverride {
        SubtitleCueStyleOverride(
            fontName: other.fontName ?? fontName,
            fontSizePoints: other.fontSizePoints ?? fontSizePoints,
            textColor: other.textColor ?? textColor,
            strokeColor: other.strokeColor ?? strokeColor,
            strokeWidthFraction: other.strokeWidthFraction ?? strokeWidthFraction,
            backgroundColor: other.backgroundColor ?? backgroundColor,
            backgroundPaddingHorizontal: other.backgroundPaddingHorizontal ?? backgroundPaddingHorizontal,
            backgroundPaddingVertical: other.backgroundPaddingVertical ?? backgroundPaddingVertical,
            cornerRadius: other.cornerRadius ?? cornerRadius,
            verticalPositionFraction: other.verticalPositionFraction ?? verticalPositionFraction,
            horizontalPositionFraction: other.horizontalPositionFraction ?? horizontalPositionFraction,
            alignment: other.alignment ?? alignment,
            maxWidthFraction: other.maxWidthFraction ?? maxWidthFraction,
            shadowBlurRadius: other.shadowBlurRadius ?? shadowBlurRadius,
            shadowColor: other.shadowColor ?? shadowColor,
            shadowOffsetY: other.shadowOffsetY ?? shadowOffsetY
        )
    }

    /// True when the override carries at least one non-nil field —
    /// i.e. it actually changes something on top of the base style.
    /// `MediaCoreViewModel` uses this to shrink an empty override
    /// back to `nil` after a reset, so the persisted form stays
    /// minimal.
    public var hasAnyField: Bool {
        fontName != nil || fontSizePoints != nil || textColor != nil
            || strokeColor != nil || strokeWidthFraction != nil
            || backgroundColor != nil
            || backgroundPaddingHorizontal != nil
            || backgroundPaddingVertical != nil
            || cornerRadius != nil
            || verticalPositionFraction != nil
            || horizontalPositionFraction != nil
            || alignment != nil
            || maxWidthFraction != nil
            || shadowBlurRadius != nil || shadowColor != nil
            || shadowOffsetY != nil
    }

    // MARK: - Reverse-engineering an override from an effective style

    /// Builds an override capturing every field where `effective`
    /// differs from `base`. Used by "Apply to all cues" to compute
    /// the new global style as `base.applying(diff)` so the
    /// promoted style matches what the user was looking at.
    /// Bilingual / karaoke / preset fields aren't part of the
    /// override surface and are ignored here — the caller is
    /// expected to copy those through separately.
    public static func diff(effective: SubtitleStyle, base: SubtitleStyle) -> SubtitleCueStyleOverride {
        var out = SubtitleCueStyleOverride()
        if effective.fontName != base.fontName { out.fontName = effective.fontName }
        if effective.fontSizePoints != base.fontSizePoints { out.fontSizePoints = effective.fontSizePoints }
        if effective.textColor != base.textColor { out.textColor = effective.textColor }
        if effective.strokeColor != base.strokeColor { out.strokeColor = effective.strokeColor }
        if effective.strokeWidthFraction != base.strokeWidthFraction { out.strokeWidthFraction = effective.strokeWidthFraction }
        if effective.backgroundColor != base.backgroundColor { out.backgroundColor = effective.backgroundColor }
        if effective.backgroundPaddingHorizontal != base.backgroundPaddingHorizontal {
            out.backgroundPaddingHorizontal = effective.backgroundPaddingHorizontal
        }
        if effective.backgroundPaddingVertical != base.backgroundPaddingVertical {
            out.backgroundPaddingVertical = effective.backgroundPaddingVertical
        }
        if effective.cornerRadius != base.cornerRadius { out.cornerRadius = effective.cornerRadius }
        if effective.verticalPositionFraction != base.verticalPositionFraction {
            out.verticalPositionFraction = effective.verticalPositionFraction
        }
        if effective.horizontalPositionFraction != base.horizontalPositionFraction {
            out.horizontalPositionFraction = effective.horizontalPositionFraction
        }
        if effective.alignment != base.alignment { out.alignment = effective.alignment }
        if effective.maxWidthFraction != base.maxWidthFraction {
            out.maxWidthFraction = effective.maxWidthFraction
        }
        if effective.shadowBlurRadius != base.shadowBlurRadius {
            out.shadowBlurRadius = effective.shadowBlurRadius
        }
        if effective.shadowColor != base.shadowColor { out.shadowColor = effective.shadowColor }
        if effective.shadowOffsetY != base.shadowOffsetY {
            out.shadowOffsetY = effective.shadowOffsetY
        }
        return out
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
