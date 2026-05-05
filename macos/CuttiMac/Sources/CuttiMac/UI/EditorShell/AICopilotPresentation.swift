import Foundation
import CuttiKit

enum AICopilotPresentation {

    // MARK: - Nested types

    struct AgentStatus: Equatable {
        enum Tone {
            case idle
            case working
            case ready
        }

        let title: String
        let detail: String
        let tone: Tone
    }

    struct InspectorAnalysis: Equatable {
        let title: String
        let supportingText: String
        let transcriptPreview: String?
        let suggestedTrimText: String?
        let issues: [AICopilotIssue]
        let suggestions: [AICopilotSuggestion]
        let showsProgress: Bool
    }

    // MARK: - Project title

    /// Returns the project folder name, or `"Untitled Project"` when `projectRoot` is nil.
    static func projectTitle(for projectRoot: URL?) -> String {
        guard let projectRoot else { return L("Untitled Project") }
        let name = projectRoot.lastPathComponent
        return name.isEmpty ? L("Untitled Project") : name
    }

    // MARK: - Agent status

    /// Returns the aggregate AI agent status across all records.
    /// - When any record is queued, analyzing, or transcoding: tone is `.working`.
    /// - Else if `selectedRecord` has suggestions or markers: tone is `.ready`.
    /// - Otherwise: tone is `.idle`.
    static func agentStatus(records: [MediaAssetRecord], selectedRecord: MediaAssetRecord?) -> AgentStatus {
        let activeCount = records.filter { isActiveStatus($0.status) }.count
        if activeCount > 0 {
            let clipWord = activeCount == 1 ? L("clip is") : L("clips are")
            return AgentStatus(
                title: L("AI is preparing clips"),
                detail: L("%d %@ still processing.", activeCount, clipWord),
                tone: .working
            )
        }

        if let record = selectedRecord, record.status == .ready, let snapshot = record.copilot {
            let hasSuggestions = !snapshot.suggestions.isEmpty
            let hasMarkers = !snapshot.markers.isEmpty
            if hasSuggestions || hasMarkers {
                let sCount = snapshot.suggestions.count
                let mCount = snapshot.markers.count
                let sWord = sCount == 1 ? L("suggestion") : L("suggestions")
                let mWord = mCount == 1 ? L("marker") : L("markers")
                return AgentStatus(
                    title: L("AI suggestions are ready"),
                    detail: L("%d %@ and %d %@ available.", sCount, sWord, mCount, mWord),
                    tone: .ready
                )
            }
        }

        return AgentStatus(
            title: L("AI copilot is idle"),
            detail: L("Import media or run analysis to unlock tags and suggestions."),
            tone: .idle
        )
    }

    // MARK: - Browser tags

    /// Returns at most 3 semantic tags from the record's copilot snapshot.
    static func browserTags(for record: MediaAssetRecord) -> [String] {
        guard let snapshot = record.copilot else { return [] }
        return Array(snapshot.semanticTags.prefix(3))
    }

    // MARK: - Inspector analysis

    /// Returns the inspector analysis panel data for the selected record.
    static func inspectorAnalysis(for record: MediaAssetRecord?) -> InspectorAnalysis {
        guard let record else {
            return InspectorAnalysis(
                title: L("No clip selected"),
                supportingText: L("Select a clip to review AI summary, transcript, and edit suggestions."),
                transcriptPreview: nil,
                suggestedTrimText: nil,
                issues: [],
                suggestions: [],
                showsProgress: false
            )
        }

        switch record.status {
        case .missing, .failed:
            return InspectorAnalysis(
                title: L("AI analysis unavailable"),
                supportingText: L("Relink the original media to resume AI suggestions and markers."),
                transcriptPreview: nil,
                suggestedTrimText: nil,
                issues: [],
                suggestions: [],
                showsProgress: false
            )
        case .queued, .analyzing, .transcoding:
            return InspectorAnalysis(
                title: L("AI analysis in progress"),
                supportingText: L("Cutti is still preparing this clip. Tags and markers will appear when processing finishes."),
                transcriptPreview: nil,
                suggestedTrimText: nil,
                issues: [],
                suggestions: [],
                showsProgress: true
            )
        case .ready:
            guard let snapshot = record.copilot else {
                return InspectorAnalysis(
                    title: L("No AI analysis yet"),
                    supportingText: L("Run clip analysis to unlock tags, suggestions, and scene markers."),
                    transcriptPreview: nil,
                    suggestedTrimText: nil,
                    issues: [],
                    suggestions: [],
                    showsProgress: false
                )
            }
            let fps = record.analysis?.nominalFPS ?? 30
            return InspectorAnalysis(
                title: L("AI analysis ready"),
                supportingText: snapshot.summary ?? L("AI found clip-level insights for this selection."),
                transcriptPreview: snapshot.transcriptPreview,
                suggestedTrimText: suggestedTrimText(for: snapshot, fps: fps),
                issues: snapshot.issues,
                suggestions: snapshot.suggestions,
                showsProgress: false
            )
        }
    }

    // MARK: - Viewer suggestions

    /// Returns the copilot suggestions for the selected record, or an empty array.
    static func viewerSuggestions(for record: MediaAssetRecord?) -> [AICopilotSuggestion] {
        record?.copilot?.suggestions ?? []
    }

    // MARK: - Timeline markers

    /// Returns the copilot markers sorted ascending by `seconds`.
    static func timelineMarkers(for record: MediaAssetRecord) -> [AICopilotMarker] {
        guard let snapshot = record.copilot else { return [] }
        return snapshot.markers.sorted { $0.seconds < $1.seconds }
    }

    // MARK: - Highlights aggregation

    /// Stable identity fingerprint for a highlight marker. Comprises
    /// every load-bearing AICopilotMarker field except `kind` (which
    /// is always `.highlight` here). Used by the panel's
    /// "Remove from Highlights" path to defend against stale row →
    /// new marker dispatches racing with `score_hook_candidates`
    /// reruns: the dispatcher checks both `markerIndex` and the
    /// fingerprint before mutating, so a markerIndex that no longer
    /// addresses the same content is a no-op.
    struct HighlightFingerprint: Equatable {
        let seconds: Double
        let endSeconds: Double?
        let origin: AICopilotMarker.Origin
        let label: String
    }

    /// One highlight marker pinned to its source record. The Highlights
    /// panel renders these as draggable rows.
    struct HighlightRow: Equatable, Hashable, Identifiable {
        let sourceVideoID: UUID
        let seconds: Double
        let endSeconds: Double?
        let label: String
        let origin: AICopilotMarker.Origin
        /// Position of the marker in the *owning record's raw
        /// `copilot.markers` array* — i.e. its persistent index in the
        /// manifest, not its position in the sorted-highlights-only
        /// projection. Doubles as both a stable SwiftUI ID component
        /// and the canonical removal key (`removeHighlight` does
        /// `markers.remove(at: markerIndex)` after a fingerprint
        /// recheck). Using the raw-array index avoids the
        /// sort-key-tie ambiguity that a presentation-order index
        /// would suffer from.
        let markerIndex: Int

        /// Stable identity across re-renders. We don't have a server-
        /// assigned marker ID, so we composite the load-bearing fields
        /// plus the in-snapshot raw-array index as a tiebreaker.
        var id: String {
            let endText = endSeconds.map { String(format: "%.6f", $0) } ?? "nil"
            return "\(sourceVideoID.uuidString)|\(String(format: "%.6f", seconds))|\(endText)|\(markerIndex)|\(origin.rawValue)|\(label)"
        }

        var isDraggable: Bool { endSeconds != nil }

        /// Snapshot of the marker's content used by `removeHighlight`
        /// to verify the markerIndex still addresses the same content
        /// at execute time.
        var fingerprint: HighlightFingerprint {
            HighlightFingerprint(
                seconds: seconds,
                endSeconds: endSeconds,
                origin: origin,
                label: label
            )
        }
    }

    /// All highlights from one source record, sorted by start time.
    struct HighlightGroup: Equatable, Identifiable {
        let recordID: UUID
        let recordTitle: String
        let highlights: [HighlightRow]

        var id: UUID { recordID }
        var count: Int { highlights.count }
    }

    /// Aggregates `.highlight` markers across records, sorted by start
    /// time within each group. Records without highlights are omitted.
    /// Group ordering follows the input `records` array so the panel
    /// matches the Media list above it.
    ///
    /// Sort comparator establishes a total order
    /// (`seconds`, `endSeconds ?? 0`, `origin`, `label`, `markerIndex`)
    /// so identity is deterministic across re-renders even when
    /// multiple highlights tie on the leading keys. The
    /// `markerIndex` we emit on each row matches the marker's
    /// position in the record's raw `copilot.markers` array — NOT
    /// the row's index in this sorted projection — so "remove the
    /// marker behind this row" can target the manifest unambiguously.
    static func highlightGroups(records: [MediaAssetRecord]) -> [HighlightGroup] {
        var result: [HighlightGroup] = []
        for record in records {
            guard let snapshot = record.copilot else { continue }
            // Capture each highlight together with its raw-array
            // index in `markers` so we can carry that index through
            // sorting + filtering into `HighlightRow.markerIndex`.
            let highlightsWithIndex: [(Int, AICopilotMarker)] = snapshot.markers
                .enumerated()
                .compactMap { (idx, marker) in
                    marker.kind == .highlight ? (idx, marker) : nil
                }
            let sorted = highlightsWithIndex.sorted { lhs, rhs in
                let l = lhs.1, r = rhs.1
                if l.seconds != r.seconds { return l.seconds < r.seconds }
                let lEnd = l.endSeconds ?? 0
                let rEnd = r.endSeconds ?? 0
                if lEnd != rEnd { return lEnd < rEnd }
                if l.origin.rawValue != r.origin.rawValue { return l.origin.rawValue < r.origin.rawValue }
                if l.label != r.label { return l.label < r.label }
                return lhs.0 < rhs.0
            }
            let rows = sorted.map { (markerIndex, marker) in
                HighlightRow(
                    sourceVideoID: record.id,
                    seconds: marker.seconds,
                    endSeconds: marker.endSeconds,
                    label: marker.label,
                    origin: marker.origin,
                    markerIndex: markerIndex
                )
            }
            guard !rows.isEmpty else { continue }
            result.append(HighlightGroup(
                recordID: record.id,
                recordTitle: MediaRecordPresentation.title(for: record),
                highlights: rows
            ))
        }
        return result
    }

    /// Total highlight count across all records — drives the section's
    /// header count chip.
    static func highlightCount(records: [MediaAssetRecord]) -> Int {
        records.reduce(0) { sum, record in
            sum + (record.copilot?.markers.filter { $0.kind == .highlight }.count ?? 0)
        }
    }

    /// Drag-and-drop payload format for a highlight row. The Highlights
    /// panel emits this when the user drags a row onto the timeline;
    /// the timeline drop handlers parse it via `parseHighlightPayload`.
    /// Format: `"highlight:<recordID>:<startSeconds>:<endSeconds>"`.
    /// Both times are seconds in source-video coordinates.
    static func highlightDragPayload(recordID: UUID, start: Double, end: Double) -> String {
        "highlight:\(recordID.uuidString):\(String(format: "%.6f", start)):\(String(format: "%.6f", end))"
    }

    /// Parses a `highlight:` payload back into its components, or
    /// returns `nil` if the payload is malformed, has non-finite
    /// coordinates, has a negative start, or has a non-positive span.
    /// Drop handlers route a nil result back to the existing `media:`
    /// parser so a malformed payload doesn't shadow the legitimate
    /// paths.
    static func parseHighlightPayload(_ payload: String) -> (recordID: UUID, start: Double, end: Double)? {
        guard payload.hasPrefix("highlight:") else { return nil }
        let body = String(payload.dropFirst("highlight:".count))
        let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let uuid = UUID(uuidString: String(parts[0])),
              let start = Double(parts[1]),
              let end = Double(parts[2]),
              start.isFinite, end.isFinite,
              start >= 0, end > start else {
            return nil
        }
        return (uuid, start, end)
    }

    // MARK: - Suggested trim text

    /// Formats the snapshot's suggested trim range as `"HH:MM:SS:FF - HH:MM:SS:FF"` at 30 fps,
    /// or returns `nil` when either trim point is absent.
    static func suggestedTrimText(for snapshot: AICopilotSnapshot) -> String? {
        suggestedTrimText(for: snapshot, fps: 30)
    }

    // MARK: - Private helpers

    /// Formats the snapshot's suggested trim range using the provided frame rate.
    private static func suggestedTrimText(for snapshot: AICopilotSnapshot, fps: Double) -> String? {
        guard let inSeconds = snapshot.suggestedInSeconds,
              let outSeconds = snapshot.suggestedOutSeconds else { return nil }
        let inText = TimecodeFormatter.string(seconds: inSeconds, fps: fps)
        let outText = TimecodeFormatter.string(seconds: outSeconds, fps: fps)
        return "\(inText) - \(outText)"
    }

    private static func isActiveStatus(_ status: MediaStatus) -> Bool {
        switch status {
        case .queued, .analyzing, .transcoding: return true
        case .ready, .failed, .missing: return false
        }
    }
}
