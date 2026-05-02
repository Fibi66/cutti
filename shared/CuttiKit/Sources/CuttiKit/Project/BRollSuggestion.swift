import Foundation

/// A single "drop something visual in here" hint produced by the LLM
/// **after** the first-cut decision has been made. Anchored to a source
/// time range (not composed time) so that the suggestion survives the
/// user re-cutting the timeline downstream: the timeline view projects
/// it to a composed-time position by asking `ComposedTimelineIndex`
/// where that source-time window now lives.
///
/// Suggestions are persisted inside `AICopilotSnapshot.bRollSuggestions`
/// so they survive a reload; the user's "Dismiss" action is stored
/// inline as `isDismissed = true` rather than deleting the row, so the
/// agent has the option to surface a "show dismissed" history later.
public struct BRollSuggestion: Codable, Equatable, Identifiable, Sendable {
    /// Stable identity so the UI can diff bubbles without rebuilding
    /// them every frame. Generated client-side; LLM never sees it.
    public var id: UUID = UUID()

    /// Which source clip the suggestion anchors to.
    public let sourceVideoID: UUID

    /// Source-time window (seconds) the suggestion targets — typically
    /// covers exactly the sentence(s) that motivated it.
    public let sourceStartSeconds: Double
    public let sourceEndSeconds: Double

    public let kind: Kind

    /// Short, concrete description ready to be fed to an image-gen
    /// model later (feature A). Example: "bar chart, 3 bars labelled
    /// Q1/Q2/Q3, minimal flat style".
    public let prompt: String

    /// One-sentence explanation of why the suggestion helps — shown in
    /// the popover so the user can decide at a glance.
    public let rationale: String

    /// Soft-delete flag set by the user's "Dismiss" action.
    public var isDismissed: Bool = false

    public init(
        id: UUID = UUID(),
        sourceVideoID: UUID,
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        kind: Kind,
        prompt: String,
        rationale: String,
        isDismissed: Bool = false
    ) {
        self.id = id
        self.sourceVideoID = sourceVideoID
        self.sourceStartSeconds = sourceStartSeconds
        self.sourceEndSeconds = sourceEndSeconds
        self.kind = kind
        self.prompt = prompt
        self.rationale = rationale
        self.isDismissed = isDismissed
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case chart
        case animation
        case image
        case screenRecording
        case mapGraphic
        case dataTable
        case other

        /// SF Symbol used on the timeline bubble.
        public var systemImage: String {
            switch self {
            case .chart:            return "chart.bar.fill"
            case .animation:        return "play.rectangle.fill"
            case .image:            return "photo.fill"
            case .screenRecording:  return "rectangle.inset.filled.and.cursorarrow"
            case .mapGraphic:       return "map.fill"
            case .dataTable:        return "tablecells.fill"
            case .other:            return "sparkles"
            }
        }

        /// Human label for the popover header.
        public var label: String {
            switch self {
            case .chart:            return "Chart"
            case .animation:        return "Animation"
            case .image:            return "Image"
            case .screenRecording:  return "Screen recording"
            case .mapGraphic:       return "Map"
            case .dataTable:        return "Data table"
            case .other:            return "B-roll"
            }
        }
    }
}
