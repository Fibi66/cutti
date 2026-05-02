import Foundation
import CoreGraphics

/// Describes how burn-in / viewer subtitles are rendered.
///
/// Units:
/// - `fontSizePoints` is in points at the canonical 1080p height. The renderer
///   scales it linearly with the actual render height so the on-screen size
///   stays visually consistent across export resolutions.
/// - Colors are sRGB with straight alpha, [0, 1].
/// - `verticalPositionFraction` = 0 means top of frame, 1 means bottom.
public struct SubtitleStyle: Codable, Equatable, Sendable {

    public enum Alignment: String, Codable, Sendable, CaseIterable {
        case leading
        case center
        case trailing
    }

    public struct RGBAColor: Codable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        public static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        public static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        public static let yellow = RGBAColor(red: 1, green: 0.85, blue: 0.08, alpha: 1)

        public var cg: CGColor {
            CGColor(
                srgbRed: CGFloat(red),
                green: CGFloat(green),
                blue: CGFloat(blue),
                alpha: CGFloat(alpha)
            )
        }
    }

    public var fontName: String
    /// Font size in points at 1080p canonical height.
    public var fontSizePoints: Double
    public var textColor: RGBAColor
    public var strokeColor: RGBAColor
    /// Stroke width as fraction of font size (0 disables).
    public var strokeWidthFraction: Double
    public var backgroundColor: RGBAColor
    /// Horizontal padding (points @ 1080p) around the background box.
    public var backgroundPaddingHorizontal: Double
    public var backgroundPaddingVertical: Double
    public var cornerRadius: Double
    /// 0 = top, 1 = bottom.
    public var verticalPositionFraction: Double
    /// 0 = left, 1 = right. Defines the *center* of the subtitle box relative
    /// to the video rect. Defaults to 0.5 (centered).
    public var horizontalPositionFraction: Double
    public var alignment: Alignment
    /// Max text width as fraction of frame width (0.1 … 1.0).
    public var maxWidthFraction: Double
    /// Drop shadow blur radius at 1080p (0 disables).
    public var shadowBlurRadius: Double
    public var shadowColor: RGBAColor
    public var shadowOffsetY: Double

    /// A readable name when presented in UI. Empty for ad-hoc custom styles.
    public var presetID: String?

    /// When non-nil, subtitles render as two stacked lines (primary +
    /// translation) using the configuration described here. Additive —
    /// nil means the style behaves exactly like a monolingual subtitle,
    /// which is the back-compat path for every style that existed before
    /// the bilingual feature landed.
    public var bilingual: BilingualDisplayOptions?

    /// Karaoke-mode options (per-word pill sweep during playback). Nil
    /// means "disabled" — identical to pre-karaoke rendering. Opt-in
    /// because it both needs cues to carry `wordTimings` and it's a
    /// stylistic choice that doesn't fit every project (long-form
    /// interviews often want it off).
    public var karaoke: SubtitleKaraokeOptions?

    // MARK: - Codable

    /// Custom decoding so newly-introduced fields default gracefully when an
    /// older on-disk payload is loaded (e.g. before `horizontalPositionFraction`).
    private enum CodingKeys: String, CodingKey {
        case fontName, fontSizePoints, textColor, strokeColor, strokeWidthFraction
        case backgroundColor, backgroundPaddingHorizontal, backgroundPaddingVertical
        case cornerRadius, verticalPositionFraction, horizontalPositionFraction
        case alignment, maxWidthFraction, shadowBlurRadius, shadowColor, shadowOffsetY
        case presetID, bilingual, karaoke
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decode(String.self, forKey: .fontName)
        fontSizePoints = try c.decode(Double.self, forKey: .fontSizePoints)
        textColor = try c.decode(RGBAColor.self, forKey: .textColor)
        strokeColor = try c.decode(RGBAColor.self, forKey: .strokeColor)
        strokeWidthFraction = try c.decode(Double.self, forKey: .strokeWidthFraction)
        backgroundColor = try c.decode(RGBAColor.self, forKey: .backgroundColor)
        backgroundPaddingHorizontal = try c.decode(Double.self, forKey: .backgroundPaddingHorizontal)
        backgroundPaddingVertical = try c.decode(Double.self, forKey: .backgroundPaddingVertical)
        cornerRadius = try c.decode(Double.self, forKey: .cornerRadius)
        verticalPositionFraction = try c.decode(Double.self, forKey: .verticalPositionFraction)
        horizontalPositionFraction = try c.decodeIfPresent(Double.self, forKey: .horizontalPositionFraction) ?? 0.5
        alignment = try c.decode(Alignment.self, forKey: .alignment)
        maxWidthFraction = try c.decode(Double.self, forKey: .maxWidthFraction)
        shadowBlurRadius = try c.decode(Double.self, forKey: .shadowBlurRadius)
        shadowColor = try c.decode(RGBAColor.self, forKey: .shadowColor)
        shadowOffsetY = try c.decode(Double.self, forKey: .shadowOffsetY)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        bilingual = try c.decodeIfPresent(BilingualDisplayOptions.self, forKey: .bilingual)
        karaoke = try c.decodeIfPresent(SubtitleKaraokeOptions.self, forKey: .karaoke)
    }

    public init(
        fontName: String,
        fontSizePoints: Double,
        textColor: RGBAColor,
        strokeColor: RGBAColor,
        strokeWidthFraction: Double,
        backgroundColor: RGBAColor,
        backgroundPaddingHorizontal: Double,
        backgroundPaddingVertical: Double,
        cornerRadius: Double,
        verticalPositionFraction: Double,
        horizontalPositionFraction: Double = 0.5,
        alignment: Alignment,
        maxWidthFraction: Double,
        shadowBlurRadius: Double,
        shadowColor: RGBAColor,
        shadowOffsetY: Double,
        presetID: String?,
        bilingual: BilingualDisplayOptions? = nil,
        karaoke: SubtitleKaraokeOptions? = nil
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
        self.presetID = presetID
        self.bilingual = bilingual
        self.karaoke = karaoke
    }

    // MARK: - Presets

    public static let defaultPresetID = "cutti.default"
    public static let boldYellowPresetID = "cutti.bold-yellow"
    public static let minimalPresetID = "cutti.minimal"

    public static let `default` = SubtitleStyle(
        fontName: "HelveticaNeue-Bold",
        fontSizePoints: 44,
        textColor: .white,
        strokeColor: .black,
        strokeWidthFraction: 0.08,
        backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.55),
        backgroundPaddingHorizontal: 18,
        backgroundPaddingVertical: 8,
        cornerRadius: 6,
        verticalPositionFraction: 0.88,
        alignment: .center,
        maxWidthFraction: 0.82,
        shadowBlurRadius: 3,
        shadowColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.9),
        shadowOffsetY: 1.5,
        presetID: defaultPresetID
    )

    public static let boldYellow = SubtitleStyle(
        fontName: "HelveticaNeue-Bold",
        fontSizePoints: 58,
        textColor: .yellow,
        strokeColor: .black,
        strokeWidthFraction: 0.12,
        backgroundColor: .clear,
        backgroundPaddingHorizontal: 0,
        backgroundPaddingVertical: 0,
        cornerRadius: 0,
        verticalPositionFraction: 0.82,
        alignment: .center,
        maxWidthFraction: 0.88,
        shadowBlurRadius: 6,
        shadowColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.95),
        shadowOffsetY: 3,
        presetID: boldYellowPresetID
    )

    public static let minimal = SubtitleStyle(
        fontName: "HelveticaNeue-Medium",
        fontSizePoints: 36,
        textColor: .white,
        strokeColor: .clear,
        strokeWidthFraction: 0,
        backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.35),
        backgroundPaddingHorizontal: 14,
        backgroundPaddingVertical: 6,
        cornerRadius: 4,
        verticalPositionFraction: 0.9,
        alignment: .center,
        maxWidthFraction: 0.78,
        shadowBlurRadius: 0,
        shadowColor: .clear,
        shadowOffsetY: 0,
        presetID: minimalPresetID
    )

    public static let allPresets: [SubtitleStyle] = [.default, .boldYellow, .minimal]

    public static func preset(id: String) -> SubtitleStyle? {
        allPresets.first { $0.presetID == id }
    }

    public var displayName: String {
        switch presetID {
        case Self.defaultPresetID: return "Default"
        case Self.boldYellowPresetID: return "Bold Yellow"
        case Self.minimalPresetID: return "Minimal"
        default: return "Custom"
        }
    }
}

/// Describes how two language lines (primary + translation) stack when
/// bilingual subtitles are enabled on a `SubtitleStyle`.
///
/// Locale tags are BCP-47 (e.g. `"zh-Hans"`, `"en-US"`, `"ja"`). The
/// primary locale points at the source-language text stored on
/// `SubtitleEntry.text`; the secondary locale points at whichever
/// translation in `SubtitleEntry.translations` should be shown alongside
/// it. When a cue lacks an entry for the secondary locale, the renderer
/// falls back to single-line mode for that cue — a missing translation
/// never blanks out the primary line.
public struct BilingualDisplayOptions: Codable, Equatable, Sendable {
    public enum SecondaryPlacement: String, Codable, Sendable, CaseIterable {
        case below
        case above
    }

    public var primaryLocale: String
    public var secondaryLocale: String
    /// Secondary font size as a fraction of the primary. Renderer clamps
    /// to [0.4, 1.0]. Default 0.75 matches English-plus-Chinese convention.
    public var secondarySizeRatio: Double
    /// Vertical gap between the two lines, as a fraction of the primary
    /// font size at 1080p. Default 0.18.
    public var lineSpacingFraction: Double
    public var placement: SecondaryPlacement

    public init(
        primaryLocale: String,
        secondaryLocale: String,
        secondarySizeRatio: Double = 0.75,
        lineSpacingFraction: Double = 0.18,
        placement: SecondaryPlacement = .below
    ) {
        self.primaryLocale = primaryLocale
        self.secondaryLocale = secondaryLocale
        self.secondarySizeRatio = secondarySizeRatio
        self.lineSpacingFraction = lineSpacingFraction
        self.placement = placement
    }

    public var clampedSecondarySizeRatio: Double {
        max(0.4, min(1.0, secondarySizeRatio))
    }

    public var clampedLineSpacingFraction: Double {
        max(0.0, min(1.0, lineSpacingFraction))
    }

    /// Canonicalize a BCP-47 locale tag so every corner of the codebase
    /// (translate tool, subtitle-style patch, renderer lookup) agrees on
    /// a single dictionary key.
    ///
    /// Rules (idempotent, pure):
    /// 1. Trim whitespace.
    /// 2. Feed through `Locale(identifier:)` — this normalizes
    ///    underscores to dashes (`zh_Hans` → `zh-Hans`) and canonicalizes
    ///    script-tag casing (`zh-hans` → `zh-Hans`).
    /// 3. Fall back to the trimmed input if Apple returns an empty
    ///    identifier so truly exotic tags still flow through untouched
    ///    instead of silently vanishing.
    ///
    /// The translate tool writes `SubtitleEntry.translations` keyed by
    /// the output of this function; the style patch and renderers must
    /// use the same function before looking up translations. Asymmetry
    /// would silently blank the secondary line.
    public static func normalizeLocale(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let canonical = Locale(identifier: trimmed).identifier
        return canonical.isEmpty ? trimmed : canonical
    }
}

/// How a subtitle track is emitted during export.
public enum SubtitleExportOption: Equatable, Sendable {
    /// No subtitle output.
    case none
    /// Write a sidecar `.srt` file next to the output video.
    case sidecarSRT
    /// Write a sidecar `.vtt` file next to the output video.
    case sidecarVTT
    /// Render subtitles into the video frames using the given style.
    case burnIn(SubtitleStyle)

    public var isBurnIn: Bool {
        if case .burnIn = self { return true }
        return false
    }

    public var sidecarExtension: String? {
        switch self {
        case .sidecarSRT: return "srt"
        case .sidecarVTT: return "vtt"
        case .none, .burnIn: return nil
        }
    }
}
