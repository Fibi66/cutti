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
    ///
    /// Historically this field doubled as the user-editable popover
    /// text. New suggestions emit a separate `userTitle` for that role
    /// and keep `prompt` as the longer scene description; pre-existing
    /// persisted suggestions still work because `userTitle` is nullable
    /// and the popover falls back to `prompt` when it's missing.
    public let prompt: String

    /// One-sentence explanation of why the suggestion helps — shown in
    /// the popover so the user can decide at a glance.
    public let rationale: String

    /// Soft-delete flag set by the user's "Dismiss" action.
    public var isDismissed: Bool = false

    /// Crisp, human-friendly card title (≤20 chars in the language of
    /// the transcript). Seeds the popover textfield so the user sees
    /// something they can read at a glance and edit if they want.
    /// `nil` for suggestions persisted before this field existed —
    /// callers fall back to `prompt`.
    public let userTitle: String?

    /// Per-`kind` extracted signal the downstream "Generate animation"
    /// agent can lift directly into the overlay's props. Format depends
    /// on the suggestion's role:
    ///   • enumeration  →  `item1 | item2 | item3`
    ///   • process      →  `step1 → step2 → step3`
    ///   • chronology   →  `2020: founded | 2022: series A | 2024: ipo`
    ///   • quote        →  `"<sentence>" — <attribution>`
    ///   • comparison   →  `LEFT: <label> :: RIGHT: <label>`
    ///   • other        →  may be `nil`
    /// `nil` for suggestions persisted before this field existed; the
    /// agent falls back to extracting from the anchor-window transcript.
    public let agentHint: String?

    /// Phase-1 section role this suggestion is anchored in. One of the
    /// closed set the LLM was constrained to: `intro`, `thesis`,
    /// `setup`, `enumeration`, `process`, `chronology`, `example`,
    /// `comparison`, `quote`, `data`, `anecdote`, `emotional`,
    /// `transition`, `conclusion`, or `other`. Unknown / off-schema
    /// strings are normalized to `other` before persistence so the
    /// downstream string-equality routing stays deterministic. `nil`
    /// for suggestions persisted before this field existed.
    public let sectionRole: String?

    public init(
        id: UUID = UUID(),
        sourceVideoID: UUID,
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        kind: Kind,
        prompt: String,
        rationale: String,
        isDismissed: Bool = false,
        userTitle: String? = nil,
        agentHint: String? = nil,
        sectionRole: String? = nil
    ) {
        self.id = id
        self.sourceVideoID = sourceVideoID
        self.sourceStartSeconds = sourceStartSeconds
        self.sourceEndSeconds = sourceEndSeconds
        self.kind = kind
        self.prompt = prompt
        self.rationale = rationale
        self.isDismissed = isDismissed
        self.userTitle = userTitle
        self.agentHint = agentHint
        self.sectionRole = sectionRole
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
