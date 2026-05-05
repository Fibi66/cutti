import Foundation

/// A "deleted but remembered" subtitle cue. Created when the user
/// selects cues in the transcript editor and hits Delete: the
/// underlying composed time range is removed from the timeline via
/// `AIAction.deleteRange`, but the cue's text (and enough metadata to
/// restore the source video range later) is preserved so the
/// transcript can render the deleted passage with strikethrough —
/// the Descript-style "soft delete" that lets users keep reading the
/// removed words in place.
///
/// Persisted in `EditorSessionState.subtitleTombstones` and captured
/// in every `EditorRevision` so Cmd+Z rewinds tombstones alongside
/// the timeline edit that created them.
public struct SubtitleTombstone: Codable, Equatable, Identifiable, Sendable {
    /// Same `id` as the `SubtitleEntry` that owned this cue before
    /// deletion. Kept stable so the UI can keep selection state
    /// across the delete.
    public let id: UUID
    public let text: String
    public let speakerID: Int?
    /// Source asset + range needed to reconstruct a `TimelineSegment`
    /// when the user restores this tombstone.
    public let sourceVideoID: UUID
    public let sourceStart: Double
    public let sourceEnd: Double
    public let speedRate: Double
    /// Composed-time coordinates at the moment the cue was deleted.
    /// Used ONLY for ordering the strikethrough blob among the
    /// surviving cues when rendering the transcript; never read back
    /// into timeline math.
    public let originalComposedStart: Double
    public let originalComposedEnd: Double
    /// Per-cue style override carried across delete/restore so a
    /// resurrected cue comes back wearing the same custom font/colour
    /// the user set on it. Optional → nil round-trips for tombstones
    /// authored before this field existed; back-compat is safe
    /// because Swift's synthesized Codable uses `decodeIfPresent`
    /// for optional properties.
    public let styleOverride: SubtitleCueStyleOverride?

    public init(
        id: UUID,
        text: String,
        speakerID: Int?,
        sourceVideoID: UUID,
        sourceStart: Double,
        sourceEnd: Double,
        speedRate: Double,
        originalComposedStart: Double,
        originalComposedEnd: Double,
        styleOverride: SubtitleCueStyleOverride? = nil
    ) {
        self.id = id
        self.text = text
        self.speakerID = speakerID
        self.sourceVideoID = sourceVideoID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speedRate = speedRate
        self.originalComposedStart = originalComposedStart
        self.originalComposedEnd = originalComposedEnd
        self.styleOverride = styleOverride
    }
}
