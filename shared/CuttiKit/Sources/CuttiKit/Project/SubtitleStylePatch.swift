import Foundation

/// A partial update to `SubtitleStyle`. Any field left as `nil` is preserved
/// from the current style — the patch is applied on top of a base value.
///
/// Used by the AI agent (`AIAction.setSubtitleStyle`) so LLMs can tweak only
/// the properties they care about (e.g. "make the subtitles bigger and
/// yellow") without having to restate the rest of the style.
public struct SubtitleStylePatch: Codable, Equatable, Sendable {
    public var fontName: String?
    public var fontSizePoints: Double?
    public var textColor: SubtitleStyle.RGBAColor?
    public var backgroundColor: SubtitleStyle.RGBAColor?
    /// If provided, overrides `backgroundColor.alpha` (expressed 0…1).
    /// Useful when the LLM only wants to toggle transparency without
    /// touching the color channels.
    public var backgroundOpacity: Double?
    public var maxWidthFraction: Double?
    public var verticalPositionFraction: Double?
    public var horizontalPositionFraction: Double?
    public var alignment: SubtitleStyle.Alignment?

    /// Tri-state bilingual toggle.
    /// - `true`  → build / keep a `BilingualDisplayOptions` on the
    ///   resulting style. Requires a non-empty secondary locale either
    ///   in this patch or on the base style; otherwise the toggle is
    ///   silently ignored to avoid rendering blank second lines.
    /// - `false` → clear the existing `BilingualDisplayOptions`
    ///   (switches subtitles back to single-line).
    /// - `nil`   → leave the existing bilingual config untouched,
    ///   except for any per-field tweaks below.
    public var bilingualEnabled: Bool?
    public var bilingualPrimaryLocale: String?
    public var bilingualSecondaryLocale: String?
    public var bilingualSecondarySizeRatio: Double?
    public var bilingualLineSpacingFraction: Double?
    public var bilingualPlacement: BilingualDisplayOptions.SecondaryPlacement?

    public init(
        fontName: String? = nil,
        fontSizePoints: Double? = nil,
        textColor: SubtitleStyle.RGBAColor? = nil,
        backgroundColor: SubtitleStyle.RGBAColor? = nil,
        backgroundOpacity: Double? = nil,
        maxWidthFraction: Double? = nil,
        verticalPositionFraction: Double? = nil,
        horizontalPositionFraction: Double? = nil,
        alignment: SubtitleStyle.Alignment? = nil,
        bilingualEnabled: Bool? = nil,
        bilingualPrimaryLocale: String? = nil,
        bilingualSecondaryLocale: String? = nil,
        bilingualSecondarySizeRatio: Double? = nil,
        bilingualLineSpacingFraction: Double? = nil,
        bilingualPlacement: BilingualDisplayOptions.SecondaryPlacement? = nil
    ) {
        self.fontName = fontName
        self.fontSizePoints = fontSizePoints
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.maxWidthFraction = maxWidthFraction
        self.verticalPositionFraction = verticalPositionFraction
        self.horizontalPositionFraction = horizontalPositionFraction
        self.alignment = alignment
        self.bilingualEnabled = bilingualEnabled
        self.bilingualPrimaryLocale = bilingualPrimaryLocale
        self.bilingualSecondaryLocale = bilingualSecondaryLocale
        self.bilingualSecondarySizeRatio = bilingualSecondarySizeRatio
        self.bilingualLineSpacingFraction = bilingualLineSpacingFraction
        self.bilingualPlacement = bilingualPlacement
    }

    /// Returns a new style with non-nil fields applied on top of `base`.
    /// The result is clamped to sane ranges so an LLM typo can't render the
    /// overlay off-screen or with absurd sizes.
    public func applied(to base: SubtitleStyle) -> SubtitleStyle {
        applyReporting(to: base).style
    }

    /// A semantic issue the patch caller should surface to the user. The
    /// patch itself still produces the best-effort style (silent-skip
    /// stays the default render behavior), but the warning gives the
    /// agent a handle to tell the user why nothing visible changed.
    public enum Warning: Equatable, Sendable {
        /// The patch (or merged state) asked for bilingual but the
        /// resulting `BilingualDisplayOptions.secondaryLocale` would be
        /// empty. Renderer would always miss its translation lookup, so
        /// we leave the existing bilingual config untouched.
        case bilingualEnabledWithoutSecondaryLocale

        public var message: String {
            switch self {
            case .bilingualEnabledWithoutSecondaryLocale:
                return "Bilingual was requested but no secondary locale was supplied (neither in this patch nor on the current style). Call translate_subtitles first, or set bilingual_secondary_locale in the same patch."
            }
        }
    }

    /// Returns the resulting style plus any warnings the caller should
    /// propagate. `applied(to:)` is the convenience form that discards
    /// warnings; callers that can surface diagnostics (e.g. the AI agent
    /// executor) should use this form instead.
    public func applyReporting(to base: SubtitleStyle) -> (style: SubtitleStyle, warnings: [Warning]) {
        var out = base
        var warnings: [Warning] = []
        if let fontName, !fontName.isEmpty { out.fontName = fontName }
        if let fontSizePoints {
            out.fontSizePoints = clamp(fontSizePoints, 12, 200)
        }
        if let textColor { out.textColor = textColor }
        if let backgroundColor { out.backgroundColor = backgroundColor }
        if let backgroundOpacity {
            var bg = out.backgroundColor
            bg.alpha = clamp(backgroundOpacity, 0, 1)
            out.backgroundColor = bg
        }
        if let maxWidthFraction {
            out.maxWidthFraction = clamp(maxWidthFraction, 0.1, 1.0)
        }
        if let verticalPositionFraction {
            out.verticalPositionFraction = clamp(verticalPositionFraction, 0, 1)
        }
        if let horizontalPositionFraction {
            out.horizontalPositionFraction = clamp(horizontalPositionFraction, 0, 1)
        }
        if let alignment { out.alignment = alignment }

        applyBilingual(to: &out, warnings: &warnings)
        return (out, warnings)
    }

    /// Merge bilingual-scoped fields into `style.bilingual`. Kept
    /// separate from `applied(to:)` so the multi-case logic (explicit
    /// disable, explicit enable, per-field tweak of existing config)
    /// stays readable.
    private func applyBilingual(to out: inout SubtitleStyle, warnings: inout [Warning]) {
        let anyBilingualField = bilingualEnabled != nil
            || bilingualPrimaryLocale != nil
            || bilingualSecondaryLocale != nil
            || bilingualSecondarySizeRatio != nil
            || bilingualLineSpacingFraction != nil
            || bilingualPlacement != nil
        guard anyBilingualField else { return }

        if bilingualEnabled == false {
            out.bilingual = nil
            return
        }

        // Merge onto existing config, or synthesize a fresh one seeded
        // with the patch values. `primaryLocale` is informational
        // metadata only — the renderer keys translations off
        // `secondaryLocale` — so an empty primary is safe.
        let base = out.bilingual ?? BilingualDisplayOptions(
            primaryLocale: "",
            secondaryLocale: ""
        )

        // Locale fields go through the canonical normalizer so a patch
        // carrying `zh-hans` / `zh_Hans` / `zh-Hans-CN` all land on the
        // same key the translate tool writes under. Asymmetric keys
        // silently blank the second line.
        let mergedPrimary: String
        if let raw = bilingualPrimaryLocale {
            mergedPrimary = BilingualDisplayOptions.normalizeLocale(raw)
        } else {
            mergedPrimary = base.primaryLocale
        }
        let mergedSecondary: String
        if let raw = bilingualSecondaryLocale {
            mergedSecondary = BilingualDisplayOptions.normalizeLocale(raw)
        } else {
            mergedSecondary = base.secondaryLocale
        }
        let mergedRatio = bilingualSecondarySizeRatio.map { clamp($0, 0.4, 1.0) }
            ?? base.secondarySizeRatio
        let mergedSpacing = bilingualLineSpacingFraction.map { clamp($0, 0, 1) }
            ?? base.lineSpacingFraction
        let mergedPlacement = bilingualPlacement ?? base.placement

        // Enabling bilingual without a secondary locale would cause the
        // renderer to look up translations under an empty key and
        // always miss → blank second line. Prefer leaving the existing
        // (possibly nil) config untouched over producing a broken one.
        // When the caller *explicitly* asked to enable bilingual, emit
        // a warning so the agent layer can surface it — a silent skip
        // here would leave the user wondering why nothing changed.
        guard !mergedSecondary.isEmpty else {
            if bilingualEnabled == true {
                warnings.append(.bilingualEnabledWithoutSecondaryLocale)
            }
            return
        }

        out.bilingual = BilingualDisplayOptions(
            primaryLocale: mergedPrimary,
            secondaryLocale: mergedSecondary,
            secondarySizeRatio: mergedRatio,
            lineSpacingFraction: mergedSpacing,
            placement: mergedPlacement
        )
    }

    public var isEmpty: Bool {
        fontName == nil && fontSizePoints == nil && textColor == nil
            && backgroundColor == nil && backgroundOpacity == nil
            && maxWidthFraction == nil && verticalPositionFraction == nil
            && horizontalPositionFraction == nil && alignment == nil
            && bilingualEnabled == nil && bilingualPrimaryLocale == nil
            && bilingualSecondaryLocale == nil && bilingualSecondarySizeRatio == nil
            && bilingualLineSpacingFraction == nil && bilingualPlacement == nil
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

// MARK: - Parsing from LLM tool arguments

public extension SubtitleStylePatch {
    /// Build a patch from a loose `[String: Any]` dictionary produced by the
    /// LLM's function-call arguments. Unknown keys are ignored. Colors accept
    /// either a hex string (`"#FFCC00"`, `"#FFCC00AA"`) or an object with
    /// `red`/`green`/`blue`/`alpha` fields in [0, 1].
    public static func parse(from raw: [String: Any]) -> SubtitleStylePatch {
        var patch = SubtitleStylePatch()
        patch.fontName = raw["font_name"] as? String
        patch.fontSizePoints = number(raw["font_size_points"])
        patch.textColor = parseColor(raw["text_color"])
        patch.backgroundColor = parseColor(raw["background_color"])
        patch.backgroundOpacity = number(raw["background_opacity"])
        patch.maxWidthFraction = number(raw["max_width_fraction"])
        patch.verticalPositionFraction = number(raw["vertical_position_fraction"])
        patch.horizontalPositionFraction = number(raw["horizontal_position_fraction"])
        if let alignRaw = raw["alignment"] as? String,
           let align = SubtitleStyle.Alignment(rawValue: alignRaw) {
            patch.alignment = align
        }

        // Bilingual sub-fields. `bilingual` is the enable/disable
        // toggle; the `bilingual_*` keys individually override fields
        // of `BilingualDisplayOptions`.
        if let flag = raw["bilingual"] as? Bool {
            patch.bilingualEnabled = flag
        } else if let flagNum = raw["bilingual"] as? NSNumber {
            // OpenAI sometimes encodes booleans as 0/1 when the tool
            // schema advertises `boolean` but the model emits JSON
            // through a path that collapses to number.
            patch.bilingualEnabled = flagNum.boolValue
        }
        if let s = raw["bilingual_primary_locale"] as? String {
            patch.bilingualPrimaryLocale = s
        }
        if let s = raw["bilingual_secondary_locale"] as? String {
            patch.bilingualSecondaryLocale = s
        }
        patch.bilingualSecondarySizeRatio = number(raw["bilingual_secondary_size_ratio"])
        patch.bilingualLineSpacingFraction = number(raw["bilingual_line_spacing_fraction"])
        if let placementRaw = raw["bilingual_placement"] as? String,
           let placement = BilingualDisplayOptions.SecondaryPlacement(rawValue: placementRaw) {
            patch.bilingualPlacement = placement
        }

        return patch
    }

    private static func number(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? NSNumber { return v.doubleValue }
        return nil
    }

    private static func parseColor(_ raw: Any?) -> SubtitleStyle.RGBAColor? {
        if let hex = raw as? String {
            return parseHexColor(hex)
        }
        if let obj = raw as? [String: Any] {
            let r = number(obj["red"]) ?? number(obj["r"])
            let g = number(obj["green"]) ?? number(obj["g"])
            let b = number(obj["blue"]) ?? number(obj["b"])
            let a = number(obj["alpha"]) ?? number(obj["a"]) ?? 1.0
            guard let r, let g, let b else { return nil }
            return SubtitleStyle.RGBAColor(red: r, green: g, blue: b, alpha: a)
        }
        return nil
    }

    /// Parse `#RRGGBB` or `#RRGGBBAA`. Returns nil for unrecognized formats.
    public static func parseHexColor(_ hex: String) -> SubtitleStyle.RGBAColor? {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6 || trimmed.count == 8,
              let value = UInt64(trimmed, radix: 16) else { return nil }

        let r: Double, g: Double, b: Double, a: Double
        if trimmed.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        }
        return SubtitleStyle.RGBAColor(red: r, green: g, blue: b, alpha: a)
    }
}
