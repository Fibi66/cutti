import Foundation

// MARK: - SubtitleRunStyle

/// Per-run style overrides for rich subtitle cues. Every field is optional —
/// a nil field means "inherit from the cue's `SubtitleStyle`". This lets
/// `SubtitleRun` represent arbitrary local overrides (a single word colored
/// yellow, a phrase in a different font) without duplicating every knob
/// from `SubtitleStyle`.
///
/// Not every `SubtitleStyle` field is overridable here — only the ones that
/// make sense at the character-range level. Layout fields (position, max
/// width, alignment, background box) stay at the cue level because they
/// apply to the whole line.
public struct SubtitleRunStyle: Codable, Equatable, Hashable, Sendable {

    public enum Weight: String, Codable, Sendable, CaseIterable {
        case regular
        case medium
        case semibold
        case bold
        case heavy
        case black
    }

    /// Font family override. Nil inherits the cue's `fontName`.
    public var fontName: String?

    /// Size multiplier relative to the cue's `fontSizePoints`. `1.0` is
    /// identity; `1.4` is 40% bigger; `0.75` is 25% smaller. Nil inherits
    /// the cue size.
    public var sizeMultiplier: Double?

    /// Font weight override. Nil inherits the weight baked into `fontName`
    /// (typically regular).
    public var weight: Weight?

    /// Fill color override. Nil inherits the cue's `textColor`.
    public var textColor: SubtitleStyle.RGBAColor?

    /// Stroke color override. Nil inherits the cue's `strokeColor`. Only
    /// takes effect when `strokeWidthFractionOverride` (or the cue's
    /// `strokeWidthFraction`) is > 0.
    public var strokeColor: SubtitleStyle.RGBAColor?

    /// Stroke width override as fraction of the final (post-multiplier)
    /// run font size. Nil inherits the cue's `strokeWidthFraction`. Use
    /// `0` to explicitly disable the stroke on this run even when the
    /// cue has one.
    public var strokeWidthFractionOverride: Double?

    /// Pill-shaped highlight drawn behind the run's glyphs. Nil / clear
    /// alpha = no highlight. Used for "marker-pen" style emphasis.
    public var highlightBackground: SubtitleStyle.RGBAColor?

    /// When `true`, draws an underline beneath the run. Nil / false = no
    /// underline.
    public var underline: Bool?

    public init(
        fontName: String? = nil,
        sizeMultiplier: Double? = nil,
        weight: Weight? = nil,
        textColor: SubtitleStyle.RGBAColor? = nil,
        strokeColor: SubtitleStyle.RGBAColor? = nil,
        strokeWidthFractionOverride: Double? = nil,
        highlightBackground: SubtitleStyle.RGBAColor? = nil,
        underline: Bool? = nil
    ) {
        self.fontName = fontName
        self.sizeMultiplier = sizeMultiplier
        self.weight = weight
        self.textColor = textColor
        self.strokeColor = strokeColor
        self.strokeWidthFractionOverride = strokeWidthFractionOverride
        self.highlightBackground = highlightBackground
        self.underline = underline
    }

    /// The identity style — a run carrying `.empty` renders exactly like
    /// plain cue text with no local overrides.
    public static let empty = SubtitleRunStyle()

    /// True when every field is nil / false. A run with an empty style is
    /// indistinguishable from a plain un-styled run at render time, and
    /// `SubtitleRunEditor.normalize` uses this to merge neighbours.
    public var isEmpty: Bool {
        fontName == nil
            && sizeMultiplier == nil
            && weight == nil
            && textColor == nil
            && strokeColor == nil
            && strokeWidthFractionOverride == nil
            && highlightBackground == nil
            && (underline ?? false) == false
    }

    /// Apply a patch on top of this style: for each non-nil field in
    /// `patch`, overwrite; nil fields leave `self` unchanged. This is the
    /// merge-mode behavior used by `SubtitleRunEditor.applyStyle`.
    public func merging(_ patch: SubtitleRunStyle) -> SubtitleRunStyle {
        SubtitleRunStyle(
            fontName: patch.fontName ?? fontName,
            sizeMultiplier: patch.sizeMultiplier ?? sizeMultiplier,
            weight: patch.weight ?? weight,
            textColor: patch.textColor ?? textColor,
            strokeColor: patch.strokeColor ?? strokeColor,
            strokeWidthFractionOverride: patch.strokeWidthFractionOverride
                ?? strokeWidthFractionOverride,
            highlightBackground: patch.highlightBackground ?? highlightBackground,
            underline: patch.underline ?? underline
        )
    }

    // MARK: Codable

    /// Custom decoding so newly-introduced fields default gracefully when
    /// older payloads are loaded.
    private enum CodingKeys: String, CodingKey {
        case fontName
        case sizeMultiplier
        case weight
        case textColor
        case strokeColor
        case strokeWidthFractionOverride
        case highlightBackground
        case underline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        sizeMultiplier = try c.decodeIfPresent(Double.self, forKey: .sizeMultiplier)
        weight = try c.decodeIfPresent(Weight.self, forKey: .weight)
        textColor = try c.decodeIfPresent(SubtitleStyle.RGBAColor.self, forKey: .textColor)
        strokeColor = try c.decodeIfPresent(SubtitleStyle.RGBAColor.self, forKey: .strokeColor)
        strokeWidthFractionOverride = try c.decodeIfPresent(
            Double.self, forKey: .strokeWidthFractionOverride)
        highlightBackground = try c.decodeIfPresent(
            SubtitleStyle.RGBAColor.self, forKey: .highlightBackground)
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(fontName, forKey: .fontName)
        try c.encodeIfPresent(sizeMultiplier, forKey: .sizeMultiplier)
        try c.encodeIfPresent(weight, forKey: .weight)
        try c.encodeIfPresent(textColor, forKey: .textColor)
        try c.encodeIfPresent(strokeColor, forKey: .strokeColor)
        try c.encodeIfPresent(
            strokeWidthFractionOverride, forKey: .strokeWidthFractionOverride)
        try c.encodeIfPresent(highlightBackground, forKey: .highlightBackground)
        try c.encodeIfPresent(underline, forKey: .underline)
    }
}

// MARK: - SubtitleStyle.RGBAColor conformance bridge

// SubtitleStyle.RGBAColor is already Codable + Equatable. Add Hashable so
// it can live inside hashable containers (SubtitleRunStyle, diffs).
extension SubtitleStyle.RGBAColor: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(red)
        hasher.combine(green)
        hasher.combine(blue)
        hasher.combine(alpha)
    }
}

// MARK: - SubtitleRun

/// A contiguous range of characters inside a subtitle cue that shares one
/// style override. A cue with no per-run styling is represented either by
/// `SubtitleEntry.runs == nil` (cheap back-compat path) or by a single run
/// with `style == .empty` (authored but unmodified). Both forms render
/// identically.
///
/// Runs are **value objects** — `SubtitleRunEditor` always returns new
/// arrays; it never mutates in place. `id` is stable across splits
/// (the left half keeps the original id, the right half gets a new one),
/// so UI can animate selection/highlight without flicker.
public struct SubtitleRun: Codable, Equatable, Hashable, Sendable, Identifiable {

    public let id: UUID
    public var text: String
    public var style: SubtitleRunStyle

    public init(
        id: UUID = UUID(),
        text: String,
        style: SubtitleRunStyle = .empty
    ) {
        self.id = id
        self.text = text
        self.style = style
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        style = try c.decodeIfPresent(SubtitleRunStyle.self, forKey: .style) ?? .empty
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        if !style.isEmpty {
            try c.encode(style, forKey: .style)
        }
    }
}
