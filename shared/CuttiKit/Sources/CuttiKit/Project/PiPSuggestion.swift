import Foundation

/// Proactive "this looks like a presenter cam" hint surfaced by the
/// `AutoPiPAnalyzer` after a V2 overlay lands on the timeline. Kept
/// in-memory only: the analyzer is cheap enough to re-run on project
/// reload, and skipping persistence means we don't have to migrate
/// schemas when the heuristic evolves.
///
/// The VM tracks user dismissals by overlay segment ID (not suggestion
/// ID) so re-generating the same overlay's suggestion after an undo
/// doesn't resurrect something the user already waved away.
public struct PiPSuggestion: Identifiable, Equatable {
    public let id: UUID
    public let overlaySegmentID: UUID
    public let layout: PiPLayout
    /// 0…1 analyzer confidence — surfaced in the banner so the user
    /// can gauge how sure we are before clicking Apply.
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        overlaySegmentID: UUID,
        layout: PiPLayout,
        confidence: Double
    ) {
        self.id = id
        self.overlaySegmentID = overlaySegmentID
        self.layout = layout
        self.confidence = confidence
    }
}
