import Foundation

public struct AICopilotIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable {
        case info
        case warning
        case critical
    }

    public let severity: Severity
    public let title: String
    public let detail: String?
    public init(
        severity: Severity,
        title: String,
        detail: String? = nil
    ) {
        self.severity = severity
        self.title = title
        self.detail = detail
    }

}

public struct AICopilotSuggestion: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String?
    public init(
        title: String,
        detail: String? = nil
    ) {
        self.title = title
        self.detail = detail
    }

}

public struct AICopilotMarker: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case scene
        case suggestion
        case warning
        case highlight
    }

    /// Where this marker came from. AI-produced markers are managed by
    /// the agent (e.g. wiped + replaced on every `score_hook_candidates`
    /// rerun); user-saved markers persist until the user removes them.
    public enum Origin: String, Codable, Sendable {
        case ai
        case manual
    }

    public let kind: Kind
    public let seconds: Double
    /// Optional end time (source-video seconds). Currently set on
    /// `.highlight` markers persisted by the hook scorer (PR 8) so the
    /// Highlights panel can show a `start–end` chip and slice-drag
    /// payload. Legacy markers and other kinds carry `nil`.
    public let endSeconds: Double?
    public let label: String
    /// Defaults to `.ai` for back-compat decoding of manifests that
    /// predate this field. PR 10 adds the `.manual` value via the
    /// "Save to Highlights" entry-point.
    public let origin: Origin

    public init(
        kind: Kind,
        seconds: Double,
        endSeconds: Double? = nil,
        label: String,
        origin: Origin = .ai
    ) {
        self.kind = kind
        self.seconds = seconds
        self.endSeconds = endSeconds
        self.label = label
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case kind, seconds, endSeconds, label, origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.seconds = try c.decode(Double.self, forKey: .seconds)
        self.endSeconds = try c.decodeIfPresent(Double.self, forKey: .endSeconds)
        self.label = try c.decode(String.self, forKey: .label)
        self.origin = (try c.decodeIfPresent(Origin.self, forKey: .origin)) ?? .ai
    }

}

public struct AICopilotSnapshot: Codable, Equatable, Sendable {
    public var semanticTags: [String]
    public var summary: String?
    public var transcriptPreview: String?
    public var suggestedInSeconds: Double?
    public var suggestedOutSeconds: Double?
    public var issues: [AICopilotIssue]
    public var suggestions: [AICopilotSuggestion]
    public var markers: [AICopilotMarker]
    public var keptRanges: [TimeRange]?
    public var keptTexts: [String]?
    /// Parallel array to `keptRanges`. Each entry is the list of
    /// equivalent alternate takes the LLM grouped with that range's
    /// "chosen" take. Empty arrays for ranges without alternates.
    /// `nil` means the pipeline predates this feature.
    public var keptAlternativesPerRange: [[AlternativeTake]]?
    /// Sentence-level transcript (resegmented from words).
    public var transcript: [TranscriptSegment]?
    /// Raw word-level transcript with accurate start/end times (from
    /// the active ASR backend — Qwen3-ASR's forced aligner when
    /// available, otherwise Apple Speech's word timings).
    /// Used by the editing Agent for precise intent-based operations.
    public var wordTranscript: [TranscriptSegment]?
    public var editLog: String?
    /// LLM-authored suggestions for visual aids (charts, B-roll clips,
    /// screen recordings…) that should drop on top of specific source
    /// time windows. Populated as the final step of the first-cut
    /// pipeline; `nil` means that step has not run (or the project
    /// pre-dates the feature). Empty array means it ran and concluded
    /// no suggestions were warranted.
    public var bRollSuggestions: [BRollSuggestion]?
    /// AI-authored chapter markers covering the *edited* timeline (post-cut).
    /// Each chapter has a start/end (in composed-timeline seconds) and a
    /// short title. Used by the chapter progress bar overlay (preview)
    /// and by the burn-in renderer (export). `nil` means the chapter
    /// pass has not run; empty array means it ran but produced nothing.
    public var chapters: [VideoChapter]?
    /// Style + position overrides for the chapter progress bar. `nil`
    /// means fall back to `ChapterBarStyle.default` (black @ 35% bottom
    /// anchor, white title, 30pt @ 1080p). Persisted so user edits
    /// survive reopen.
    public var chapterBarStyle: ChapterBarStyle?
    /// True iff this snapshot was produced by the transcribe-only path
    /// that backs the `识别说话人` (detect_speakers) tool: it has a
    /// single full-source `keptRange` and exists only to expose a
    /// transcript on the timeline, not to express any LLM-driven cut.
    /// First Cut treats records with this flag as un-analyzed so the
    /// user can still run a real first cut after diarization. `nil` /
    /// `false` means a normal First Cut snapshot.
    public var isTranscribeOnly: Bool?
    /// Per-window RMS energy curve covering the entire **source** audio
    /// (uniformly sampled). Persisted alongside the transcript so any
    /// downstream analyser (hook scoring, monologue detection, energy
    /// dips) can query loudness at a given timestamp without re-reading
    /// raw PCM. `nil` on snapshots produced by pipelines that predate
    /// the field. See `AudioEnergyCurve.valueAt(seconds:)` for lookup.
    public var audioEnergyCurve: AudioEnergyCurve?
    public init(
        semanticTags: [String],
        summary: String? = nil,
        transcriptPreview: String? = nil,
        suggestedInSeconds: Double? = nil,
        suggestedOutSeconds: Double? = nil,
        issues: [AICopilotIssue],
        suggestions: [AICopilotSuggestion],
        markers: [AICopilotMarker],
        keptRanges: [TimeRange]? = nil,
        keptTexts: [String]? = nil,
        keptAlternativesPerRange: [[AlternativeTake]]? = nil,
        transcript: [TranscriptSegment]? = nil,
        wordTranscript: [TranscriptSegment]? = nil,
        editLog: String? = nil,
        bRollSuggestions: [BRollSuggestion]? = nil,
        chapters: [VideoChapter]? = nil,
        chapterBarStyle: ChapterBarStyle? = nil,
        isTranscribeOnly: Bool? = nil,
        audioEnergyCurve: AudioEnergyCurve? = nil
    ) {
        self.semanticTags = semanticTags
        self.summary = summary
        self.transcriptPreview = transcriptPreview
        self.suggestedInSeconds = suggestedInSeconds
        self.suggestedOutSeconds = suggestedOutSeconds
        self.issues = issues
        self.suggestions = suggestions
        self.markers = markers
        self.keptRanges = keptRanges
        self.keptTexts = keptTexts
        self.keptAlternativesPerRange = keptAlternativesPerRange
        self.transcript = transcript
        self.wordTranscript = wordTranscript
        self.editLog = editLog
        self.bRollSuggestions = bRollSuggestions
        self.chapters = chapters
        self.chapterBarStyle = chapterBarStyle
        self.isTranscribeOnly = isTranscribeOnly
        self.audioEnergyCurve = audioEnergyCurve
    }

}

/// Per-window RMS audio energy curve attached to an `AICopilotSnapshot`.
///
/// Values are **linear RMS** in roughly `[0, 1]` (not dB, not normalized
/// to a global peak). The original `AudioQualityService` pipeline computes
/// these for silence detection then discards them; we now persist them so
/// hook scoring, monologue/energy-dip detection, and any future
/// loudness-aware AI tool can look up "how loud is the audio at time t"
/// without re-reading PCM samples.
///
/// Storage cost is small even for long files: at the current 0.5s window,
/// a 60-minute episode is 7200 floats ≈ 29 KB JSON-encoded. We do not
/// quantise; consumers that need a normalized value should divide by
/// `globalPeak`.
public struct AudioEnergyCurve: Codable, Equatable, Sendable {
    /// Per-window linear RMS values, sampled left-to-right across the
    /// full source audio at `windowSeconds` granularity.
    public var values: [Float]
    /// Seconds covered by each window. Always > 0 when `values` is
    /// non-empty. Typically `0.5`.
    public var windowSeconds: Double

    public init(values: [Float], windowSeconds: Double) {
        self.values = values
        self.windowSeconds = windowSeconds
    }

    /// Linear-interpolated RMS at the given source timestamp. Returns
    /// `0` for empty curves and for timestamps outside the sampled
    /// range. Negative `seconds` is treated as out-of-range, not as an
    /// index into a wraparound — callers should clamp at the call site
    /// if they want a different semantics.
    public func valueAt(seconds: Double) -> Double {
        guard !values.isEmpty, windowSeconds > 0, seconds >= 0 else { return 0 }
        let idx = seconds / windowSeconds
        let i0 = Int(idx.rounded(.down))
        guard i0 >= 0, i0 < values.count else { return 0 }
        let i1 = Swift.min(i0 + 1, values.count - 1)
        let frac = idx - Double(i0)
        return Double(values[i0]) * (1 - frac) + Double(values[i1]) * frac
    }

    /// Maximum RMS within `[startSeconds, endSeconds]`. Used by hook
    /// scoring to ask "did the speaker peak inside this cue?". Both
    /// bounds are clamped to the curve; an empty / inverted range
    /// returns `0`.
    public func peakIn(startSeconds: Double, endSeconds: Double) -> Double {
        guard !values.isEmpty, windowSeconds > 0, endSeconds > startSeconds else { return 0 }
        let lo = Swift.max(0, Int((Swift.max(0, startSeconds) / windowSeconds).rounded(.down)))
        let hi = Swift.min(values.count - 1, Int((endSeconds / windowSeconds).rounded(.up)))
        guard lo <= hi else { return 0 }
        return Double(values[lo...hi].max() ?? 0)
    }

    /// Global peak across the whole curve. Divide `peakIn(...)` by this
    /// to get a `[0, 1]` normalised "loudness vs the rest of the file"
    /// score. Returns `0` for empty curves.
    public var globalPeak: Double {
        Double(values.max() ?? 0)
    }

    /// Percentile of the energy distribution. `p` is clamped to `[0, 1]`.
    /// Returns `0` for empty curves. Used as a robust loudness denominator
    /// for hook scoring — a single freak loud frame (cough, mic bump,
    /// laughter) won't deflate every other candidate's energy score the
    /// way `globalPeak` does. Rule of thumb: pass `p = 0.95`.
    public func percentile(_ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let pp = Swift.max(0, Swift.min(1, p))
        let sorted = values.sorted()
        let idx = Int((pp * Double(sorted.count - 1)).rounded(.toNearestOrEven))
        return Double(sorted[idx])
    }
}

/// RGBA color in sRGB-ish space, components in 0…1. Codable so it can
/// live on the snapshot without pulling SwiftUI / AppKit into the
/// data layer.
public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let accentRed = RGBAColor(red: 1.0, green: 0.30, blue: 0.30, alpha: 1)
}

/// User-adjustable appearance + position of the chapter progress bar.
/// Saved to `AICopilotSnapshot.chapterBarStyle` and read by both the
/// preview overlay and the burn-in renderer so they stay WYSIWYG.
public struct ChapterBarStyle: Codable, Equatable, Sendable {
    public enum VerticalAnchor: String, Codable, CaseIterable {
        case top, bottom
    }
    /// Which edge of the video rect the bar sits against.
    public var anchor: VerticalAnchor
    /// Color of the bar's track (unfilled portion) AND of the rounded
    /// rectangle drawn behind the title.
    public var backgroundColor: RGBAColor
    /// 0…1. Applied as a multiplier on `backgroundColor.alpha` when
    /// drawing the background panel behind title + bar.
    public var backgroundOpacity: Double
    /// Color of the current chapter title text.
    public var fontColor: RGBAColor
    /// Font size in 1080p-reference points. The renderer / overlay
    /// both scale this by `renderHeight / 1080` so the bar looks the
    /// same regardless of export resolution.
    public var fontSize: Double

    public static let `default` = ChapterBarStyle(
        anchor: .bottom,
        backgroundColor: .black,
        backgroundOpacity: 0.35,
        fontColor: .white,
        fontSize: 30
    )
    public init(
        anchor: VerticalAnchor,
        backgroundColor: RGBAColor,
        backgroundOpacity: Double,
        fontColor: RGBAColor,
        fontSize: Double
    ) {
        self.anchor = anchor
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.fontColor = fontColor
        self.fontSize = fontSize
    }

}

/// One chapter on the edited timeline. Times are in composed seconds
/// (post-cut), not source seconds.
public struct VideoChapter: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var startSeconds: Double
    public var endSeconds: Double
    public var title: String

    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }

    public init(
        id: UUID = UUID(),
        startSeconds: Double,
        endSeconds: Double,
        title: String
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
    }
}

public struct TimeRange: Codable, Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public init(
        startSeconds: Double,
        endSeconds: Double
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

}

/// Per-segment visual and audio effects.
public struct SegmentEffects: Equatable, Sendable {
    /// Rotation in degrees (0, 90, 180, 270).
    public var rotation: Int = 0
    public var flipHorizontal: Bool = false
    public var flipVertical: Bool = false

    /// Color adjustments — CIColorControls parameters.
    public var brightness: Double = 0     // -1 to 1
    public var contrast: Double = 1       // 0 to 2
    public var saturation: Double = 1     // 0 to 2

    /// Audio fade durations in seconds.
    public var audioFadeInDuration: Double = 0
    public var audioFadeOutDuration: Double = 0

    public static let `default` = SegmentEffects()
    public var isDefault: Bool { self == .default }

    public var hasColorAdjustment: Bool {
        brightness != 0 || contrast != 1 || saturation != 1
    }

    public var hasTransform: Bool {
        rotation != 0 || flipHorizontal || flipVertical
    }

    public var hasAudioFade: Bool {
        audioFadeInDuration > 0 || audioFadeOutDuration > 0
    }

    public var hasAnyVisualEffect: Bool {
        hasColorAdjustment || hasTransform
    }
    public init(
        rotation: Int = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        brightness: Double = 0,
        contrast: Double = 1,
        saturation: Double = 1,
        audioFadeInDuration: Double = 0,
        audioFadeOutDuration: Double = 0
    ) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.audioFadeInDuration = audioFadeInDuration
        self.audioFadeOutDuration = audioFadeOutDuration
    }

}

/// Picture-in-Picture overlay layout for an overlay (V2+) segment.
///
/// When non-nil on an overlay segment, the composition renders the
/// segment's video as a small corner-anchored thumbnail on top of the
/// primary track instead of a full-frame cover. This is the data model
/// for the "presenter cam on top of slides" pattern.
///
/// All fractional values are in canvas-normalized coordinates (0..1),
/// so the same layout survives canvas resolution changes. `corner` +
/// `insetFraction` together determine position; `sizeFraction` scales
/// the thumbnail based on canvas height (PiP stays visually consistent
/// whether the canvas is 720p or 4K).
public struct PiPLayout: Equatable, Codable, Sendable {

    /// Visible silhouette of the PiP thumbnail.
    public enum Shape: String, Codable, CaseIterable {
        case circle
        case roundedSquare
        case square
    }

    /// Which canvas corner the thumbnail anchors to.
    public enum Corner: String, Codable, CaseIterable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    public var shape: Shape
    public var corner: Corner

    /// Thumbnail size as a fraction of canvas height. Clamped to
    /// `[minSizeFraction, maxSizeFraction]` by the normalizer so UI
    /// sliders can't produce degenerate layouts.
    public var sizeFraction: Double

    /// Padding from the anchored corner, as a fraction of canvas
    /// height. Clamped to `[0, maxInsetFraction]`.
    public var insetFraction: Double

    /// Border width in canvas-space points. 0 disables the border.
    public var borderWidthPx: Double

    /// Hex string like "#FFFFFFFF" for the border stroke. Nil when
    /// there is no border.
    public var borderColorHex: String?

    /// Drop shadow toggle. Actual shadow radius / offset are derived
    /// in the renderer so we don't have to store them.
    public var shadowEnabled: Bool

    public static let minSizeFraction: Double = 0.08
    public static let maxSizeFraction: Double = 0.45
    /// Upper bound on `insetFraction` in canvas-height units.
    /// Originally `0.08` to prevent the slider from parking PiP in
    /// the middle of the frame, but the viewer's drag handle needs
    /// enough range to move the thumbnail anywhere sensible on a
    /// typical 16:9 canvas. `0.4` covers essentially any position
    /// reachable from a corner anchor without letting stray values
    /// from disk push the rect off-canvas.
    public static let maxInsetFraction: Double = 0.4

    public static let `default` = PiPLayout(
        shape: .roundedSquare,
        corner: .bottomRight,
        sizeFraction: 0.22,
        insetFraction: 0.025,
        borderWidthPx: 0,
        borderColorHex: nil,
        shadowEnabled: true
    )

    /// Clamp fractional values to their allowed ranges. Renderers and
    /// persistence readers call this defensively so stale or
    /// out-of-range values from disk can't crash layout.
    public func normalized() -> PiPLayout {
        var copy = self
        copy.sizeFraction = min(
            Self.maxSizeFraction,
            max(Self.minSizeFraction, sizeFraction)
        )
        copy.insetFraction = min(
            Self.maxInsetFraction,
            max(0, insetFraction)
        )
        copy.borderWidthPx = max(0, borderWidthPx)
        return copy
    }
    public init(
        shape: Shape,
        corner: Corner,
        sizeFraction: Double,
        insetFraction: Double,
        borderWidthPx: Double,
        borderColorHex: String? = nil,
        shadowEnabled: Bool
    ) {
        self.shape = shape
        self.corner = corner
        self.sizeFraction = sizeFraction
        self.insetFraction = insetFraction
        self.borderWidthPx = borderWidthPx
        self.borderColorHex = borderColorHex
        self.shadowEnabled = shadowEnabled
    }

}

/// A single segment in the timeline, representing one AI-kept range or a user-added range.
public struct TimelineSegment: Identifiable, Equatable, Sendable {
    public static let minimumSpeedRate = 0.25
    public static let maximumSpeedRate = 4.0

    public let id: UUID
    /// Which source video this segment comes from.
    public let sourceVideoID: UUID
    public var range: TimeRange
    public var text: String
    public var subtitles: [SubtitleEntry]
    /// Per-segment volume level (0.0 = mute, 1.0 = full). Applied via AVMutableAudioMix.
    public var volumeLevel: Double = 1.0
    /// When true, the segment's video is hidden from the composition —
    /// audio (if any, governed by `volumeLevel`) still plays and the
    /// segment still occupies its duration on the timeline, but the
    /// picture is replaced with a transparent/empty gap. On the primary
    /// track this shows through as black (or to the next-layer overlay
    /// if one covers the same window). On an overlay track it simply
    /// lets the layer below (or V1) pass through.
    public var isVideoHidden: Bool = false
    /// Per-segment playback speed (1.0 = normal, 2.0 = 2x faster).
    public var speedRate: Double = 1.0
    /// Per-segment visual and audio effects.
    public var effects: SegmentEffects = .default
    /// When non-nil, overrides sequential placement: this segment starts at
    /// `placementOffset` seconds in the composed timeline rather than
    /// flowing from the previous segment. Used by overlay / B-roll tracks
    /// where segments must be anchored to specific composed times. Primary
    /// video/audio tracks leave this nil so segments play back-to-back.
    public var placementOffset: Double? = nil
    /// Equivalent takes the LLM identified as saying the same thing as
    /// this segment (restart-duplicates or same-meaning rewordings).
    /// The primary segment on the timeline is the "chosen" take; these
    /// are the alternates the user can manually swap in. Empty by
    /// default; populated by the first-cut pipeline and persisted so
    /// user swaps survive project reopen.
    public var alternatives: [AlternativeTake] = []
    /// Two-way link used by the Detach Audio feature. When a V1 clip's
    /// audio is detached onto an A2 track, both the V1 `TimelineSegment`
    /// and the mirror aux-audio `TimelineSegment` get each other's UUID
    /// here. Edits on one side (move / trim / split / delete / reattach)
    /// consult this link to keep the paired segment in sync. Nil for
    /// regular (non-detached) segments.
    public var linkedSegmentID: UUID? = nil
    /// Picture-in-Picture layout for overlay (V2+) segments. Nil on
    /// primary-track segments and on overlay segments that should
    /// fully cover V1. When non-nil, CompositionBuilder renders the
    /// segment as a corner-anchored thumbnail using the layout's
    /// shape / corner / size / inset.
    public var pipLayout: PiPLayout? = nil
    /// Free-transform overlay controls. Used for image overlays and
    /// any overlay segment that wants direct position/scale/rotation
    /// control instead of corner-anchored PiP layout semantics. When
    /// both `freeTransform` and `pipLayout` are set, `freeTransform`
    /// wins — `pipLayout` is legacy PiP behavior.
    public var freeTransform: FreeTransform? = nil
    /// When non-nil, marks this overlay segment as AI-generated from
    /// a Remotion template. The cached `.mov` referenced by
    /// `sourceVideoID` is a render of `overlaySpec`; editing the spec
    /// (via the Inspector) triggers a re-render and swaps `sourceVideoID`
    /// to the new cached asset. Nil for all regular (imported-media)
    /// segments. See `OverlayRenderSpec` for the "params as source of
    /// truth" rationale.
    public var overlaySpec: OverlayRenderSpec? = nil
    public var sourceDurationSeconds: Double { range.endSeconds - range.startSeconds }
    public var normalizedSpeedRate: Double {
        max(Self.minimumSpeedRate, min(speedRate, Self.maximumSpeedRate))
    }
    public var durationSeconds: Double { sourceDurationSeconds / normalizedSpeedRate }

    public init(
        id: UUID,
        sourceVideoID: UUID,
        range: TimeRange,
        text: String,
        subtitles: [SubtitleEntry],
        volumeLevel: Double = 1.0,
        isVideoHidden: Bool = false,
        speedRate: Double = 1.0,
        effects: SegmentEffects = .default,
        placementOffset: Double? = nil,
        alternatives: [AlternativeTake] = [],
        linkedSegmentID: UUID? = nil,
        pipLayout: PiPLayout? = nil,
        freeTransform: FreeTransform? = nil,
        overlaySpec: OverlayRenderSpec? = nil
    ) {
        self.id = id
        self.sourceVideoID = sourceVideoID
        self.range = range
        self.text = text
        self.subtitles = subtitles
        self.volumeLevel = volumeLevel
        self.isVideoHidden = isVideoHidden
        self.speedRate = speedRate
        self.effects = effects
        self.placementOffset = placementOffset
        self.alternatives = alternatives
        self.linkedSegmentID = linkedSegmentID
        self.pipLayout = pipLayout
        self.freeTransform = freeTransform
        self.overlaySpec = overlaySpec
    }
}

/// One alternate recording of the same sentence / same meaning.
/// Carries the minimum we need to (a) show it in the swap picker, (b)
/// play it as a preview, and (c) become the new primary segment when
/// the user swaps it in.
public struct AlternativeTake: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var sourceVideoID: UUID
    public let startSeconds: Double
    public let endSeconds: Double
    public var text: String
    /// Short label describing why the LLM grouped this as equivalent
    /// ("restart 重启" / "同义改写" / etc.). Shown in the swap UI.
    public var reason: String?

    public var durationSeconds: Double { endSeconds - startSeconds }

    public init(
        id: UUID = UUID(),
        sourceVideoID: UUID,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        reason: String? = nil
    ) {
        self.id = id
        self.sourceVideoID = sourceVideoID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.reason = reason
    }
}

/// A per-sentence subtitle entry positioned within the composed timeline.
public struct SubtitleEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Offset in seconds from the start of the parent segment
    public let relativeStart: Double
    /// Duration in seconds within the parent segment
    public let relativeDuration: Double
    public let text: String
    /// Optional zero-based speaker index assigned by diarization. `nil`
    /// means "unknown / not diarized yet".
    public var speakerID: Int? = nil
    /// Translations of `text` keyed by BCP-47 locale (e.g. `"zh-Hans"`,
    /// `"en-US"`). Additive — `text` remains the source-language line
    /// and is never replaced when a translation is added. Empty by
    /// default so every cue authored before the bilingual feature
    /// landed round-trips unchanged.
    public var translations: [String: String] = [:]
    /// Optional per-run styling for the primary `text`. Nil means "plain
    /// cue — render `text` with the cue's `SubtitleStyle`", which is the
    /// back-compat path for every cue authored before the rich-text
    /// feature landed. When non-nil, the invariant
    /// `SubtitleRunEditor.plainText(runs) == text` must hold; callers
    /// who edit `runs` are responsible for keeping `text` in sync.
    public var runs: [SubtitleRun]? = nil
    /// Per-word timestamps for karaoke-mode rendering. Times are
    /// **entry-relative** (seconds from `relativeStart`). Nil means
    /// "no word timing available" — typically true for cues authored
    /// before word-timestamp wiring landed, or for manually-edited
    /// cues whose text no longer matches the original audio window.
    /// When present, the cumulative UTF-16 lengths of each timing's
    /// `text` should align with positions in `text`; the karaoke
    /// composer tolerates the ASR's leading-whitespace habit but will
    /// skip timings whose text can't be located.
    public var wordTimings: [WordTiming]? = nil
    /// Per-cue visual override layered on top of the project-wide
    /// `SubtitleStyle`. Nil means "render this cue identically to
    /// every other cue in the project" — the back-compat path for
    /// every cue authored before per-cue style overrides landed.
    /// When present, the renderer applies it via
    /// `styleOverride.applied(to: globalStyle)` for both viewer
    /// preview and burn-in export, so preview is WYSIWYG.
    /// Bilingual locale and karaoke options stay project-wide and
    /// are intentionally absent from `SubtitleCueStyleOverride`.
    public var styleOverride: SubtitleCueStyleOverride? = nil

    public init(
        id: UUID,
        relativeStart: Double,
        relativeDuration: Double,
        text: String,
        speakerID: Int? = nil,
        translations: [String: String] = [:],
        runs: [SubtitleRun]? = nil,
        wordTimings: [WordTiming]? = nil,
        styleOverride: SubtitleCueStyleOverride? = nil
    ) {
        self.id = id
        self.relativeStart = relativeStart
        self.relativeDuration = relativeDuration
        self.text = text
        self.speakerID = speakerID
        self.translations = translations
        self.runs = runs
        self.wordTimings = wordTimings
        self.styleOverride = styleOverride
    }

    /// Returns a copy of this entry with the supplied fields
    /// replaced and every other field preserved. This is the
    /// canonical "tweak an existing cue without forgetting newly
    /// added fields" surface — direct `SubtitleEntry(...)` calls in
    /// transform paths silently drop fields when the struct gains
    /// one (e.g. `runs`, `translations`, now `styleOverride`).
    /// `with(...)` makes the preserve-by-default posture explicit
    /// and survives future field additions.
    ///
    /// Note: nil arguments mean "preserve" (not "clear"). To clear
    /// optional fields like `runs` or `wordTimings` after a text
    /// edit, prefer `withTextChanged(_:)` which encodes that
    /// invariant by name. For other clear scenarios, fall back to
    /// the direct initializer.
    public func with(
        relativeStart: Double? = nil,
        relativeDuration: Double? = nil,
        text: String? = nil,
        speakerID: Int? = nil,
        translations: [String: String]? = nil,
        runs: [SubtitleRun]? = nil,
        wordTimings: [WordTiming]? = nil,
        styleOverride: SubtitleCueStyleOverride? = nil
    ) -> SubtitleEntry {
        SubtitleEntry(
            id: id,
            relativeStart: relativeStart ?? self.relativeStart,
            relativeDuration: relativeDuration ?? self.relativeDuration,
            text: text ?? self.text,
            speakerID: speakerID ?? self.speakerID,
            translations: translations ?? self.translations,
            runs: runs ?? self.runs,
            wordTimings: wordTimings ?? self.wordTimings,
            styleOverride: styleOverride ?? self.styleOverride
        )
    }

    /// Convenience for the common "user rewrote the cue text" path.
    /// Replaces `text`, drops `runs` and `wordTimings` (since both
    /// invariants — runs concatenate to text, timings cover text —
    /// no longer hold once the user typed a different sentence),
    /// and **preserves everything else** including `styleOverride`,
    /// `translations`, and `speakerID`. The caller can still drop
    /// translations afterwards if desired (e.g. translation tool
    /// posture: stale translations get cleared by the translate
    /// agent on its next pass).
    public func withTextChanged(_ newText: String) -> SubtitleEntry {
        SubtitleEntry(
            id: id,
            relativeStart: relativeStart,
            relativeDuration: relativeDuration,
            text: newText,
            speakerID: speakerID,
            translations: translations,
            runs: nil,
            wordTimings: nil,
            styleOverride: styleOverride
        )
    }

    /// True when `runs` is nil or its concatenated plain text matches
    /// `text`. Use in development asserts to catch drift after edits.
    public var hasConsistentRuns: Bool {
        guard let runs else { return true }
        return SubtitleRunEditor.plainText(runs) == text
    }
}

/// A subtitle cue with absolute timing in the composed timeline (for viewer overlay).
public struct ComposedSubtitle: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Start time in composed timeline (seconds, microsecond precision)
    public let startSeconds: Double
    /// End time in composed timeline
    public let endSeconds: Double
    public let text: String
    public var speakerID: Int? = nil
    /// Source video this cue was transcribed from. Present for cues
    /// built by the editor from real timeline segments (nil when tests
    /// construct bare cues). Used together with `sourceStart` to give
    /// the transcript view a **stable reading-order key** so that
    /// tombstoned cues keep appearing at their original reading
    /// position even after the surrounding live cues' composed-time
    /// positions shift due to upstream deletes.
    public let sourceVideoID: UUID?
    /// Pre-speed source-video time of this cue's start, in seconds.
    /// Stable across timeline edits (trims, deletes, reorders) because
    /// it refers to a point in the original footage, not the composed
    /// timeline.
    public let sourceStart: Double?
    /// Translations of `text` keyed by BCP-47 locale (e.g. `"zh-Hans"`).
    /// Mirrors `SubtitleEntry.translations` so the viewer overlay and
    /// burn-in renderer can render a bilingual cue without touching
    /// segment state. Empty by default; populated when the translate
    /// tool has annotated the owning `SubtitleEntry`.
    public let translations: [String: String]
    /// Optional per-run rich-text styling mirroring the owning
    /// `SubtitleEntry.runs`. Nil means "plain cue — render `text`
    /// with the cue-level `SubtitleStyle`", which is the back-compat
    /// path for every cue authored before the rich-text feature
    /// landed. When non-nil, invariant
    /// `SubtitleRunEditor.plainText(runs) == text` holds.
    public let runs: [SubtitleRun]?
    /// Per-word timestamps mirroring `SubtitleEntry.wordTimings` but
    /// **rebased to this cue's `startSeconds`** (and divided by the
    /// owning segment's speed rate so 1 second of timing = 1 second
    /// of composed-timeline playback). To convert to absolute composed
    /// time, add `startSeconds`. The viewer / burn-in renderer can
    /// pass these straight into `SubtitleKaraokeComposer.activeWordRange`
    /// alongside `entryRelativeTime = playhead - cue.startSeconds`.
    /// Nil when the owning entry had no word timings.
    public let wordTimings: [WordTiming]?
    /// Per-cue style override mirroring `SubtitleEntry.styleOverride`.
    /// Nil means "render with the project-wide `SubtitleStyle`" — the
    /// path every cue takes when the user has not customised this cue
    /// individually. When non-nil, every set field replaces the
    /// corresponding global field at render time (viewer + burn-in).
    public let styleOverride: SubtitleCueStyleOverride?

    public init(
        id: UUID,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        speakerID: Int? = nil,
        sourceVideoID: UUID? = nil,
        sourceStart: Double? = nil,
        translations: [String: String] = [:],
        runs: [SubtitleRun]? = nil,
        wordTimings: [WordTiming]? = nil,
        styleOverride: SubtitleCueStyleOverride? = nil
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.speakerID = speakerID
        self.sourceVideoID = sourceVideoID
        self.sourceStart = sourceStart
        self.translations = translations
        self.runs = runs
        self.wordTimings = wordTimings
        self.styleOverride = styleOverride
    }
}

// MARK: - Composed Timeline Index

/// Maps between composed timeline time and source video time.
/// Used by the AI Agent to understand "minute 3 of the final video"
/// and translate it to the correct source segment.
public struct ComposedTimelineIndex {
    public struct Entry {
        public let segmentID: UUID
        public let segmentIndex: Int
        public let sourceVideoID: UUID
        /// Start of this segment in composed timeline
        public let composedStart: Double
        /// End of this segment in composed timeline
        public let composedEnd: Double
        /// Start of this segment in source video
        public let sourceStart: Double
        /// End of this segment in source video
        public let sourceEnd: Double
        public let speedRate: Double
        public let text: String

        public init(
            segmentID: UUID,
            segmentIndex: Int,
            sourceVideoID: UUID,
            composedStart: Double,
            composedEnd: Double,
            sourceStart: Double,
            sourceEnd: Double,
            speedRate: Double,
            text: String
        ) {
            self.segmentID = segmentID
            self.segmentIndex = segmentIndex
            self.sourceVideoID = sourceVideoID
            self.composedStart = composedStart
            self.composedEnd = composedEnd
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd
            self.speedRate = speedRate
            self.text = text
        }
    }

    public let entries: [Entry]
    public let totalDuration: Double

    public init(entries: [Entry], totalDuration: Double) {
        self.entries = entries
        self.totalDuration = totalDuration
    }

    /// Build from timeline segments.
    public static func build(from segments: [TimelineSegment]) -> ComposedTimelineIndex {
        var entries: [Entry] = []
        var composedOffset: Double = 0

        for (i, seg) in segments.enumerated() {
            entries.append(Entry(
                segmentID: seg.id,
                segmentIndex: i,
                sourceVideoID: seg.sourceVideoID,
                composedStart: composedOffset,
                composedEnd: composedOffset + seg.durationSeconds,
                sourceStart: seg.range.startSeconds,
                sourceEnd: seg.range.endSeconds,
                speedRate: seg.normalizedSpeedRate,
                text: seg.text
            ))
            composedOffset += seg.durationSeconds
        }

        return ComposedTimelineIndex(entries: entries, totalDuration: composedOffset)
    }

    /// Find which segment contains the given composed time.
    public func segmentAt(composedTime: Double) -> Entry? {
        entries.first { composedTime >= $0.composedStart && composedTime < $0.composedEnd }
    }

    /// Convert composed timeline time to source video time.
    public func toSourceTime(_ composedTime: Double) -> (sourceVideoID: UUID, sourceTime: Double)? {
        guard let entry = segmentAt(composedTime: composedTime) else { return nil }
        let offset = composedTime - entry.composedStart
        return (entry.sourceVideoID, entry.sourceStart + (offset * entry.speedRate))
    }

    /// Convert source video time to composed timeline time.
    public func toComposedTime(sourceVideoID: UUID, sourceTime: Double) -> Double? {
        guard let entry = entries.first(where: {
            $0.sourceVideoID == sourceVideoID &&
            sourceTime >= $0.sourceStart &&
            sourceTime < $0.sourceEnd
        }) else { return nil }
        let offset = sourceTime - entry.sourceStart
        return entry.composedStart + (offset / entry.speedRate)
    }

    /// Format as context string for the AI Agent.
    public func agentContext(sourceNames: [UUID: String] = [:]) -> String {
        var lines: [String] = []
        lines.append("Total duration: \(formatTime(totalDuration))")
        lines.append("Segments: \(entries.count)")
        lines.append("")

        for entry in entries {
            let srcName = sourceNames[entry.sourceVideoID] ?? entry.sourceVideoID.uuidString.prefix(8).description
            let speedSuffix = abs(entry.speedRate - 1.0) > 0.001
                ? " @\(formatRate(entry.speedRate))x"
                : ""
            lines.append("[\(entry.segmentIndex)] \(formatTime(entry.composedStart))–\(formatTime(entry.composedEnd))\(speedSuffix) ← \(srcName) \(formatTime(entry.sourceStart))–\(formatTime(entry.sourceEnd)): \(entry.text.prefix(60))…")
        }

        return lines.joined(separator: "\n")
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatRate(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.001 {
            return String(format: "%.0f", rate)
        }
        return String(format: "%.2f", rate)
    }
}
