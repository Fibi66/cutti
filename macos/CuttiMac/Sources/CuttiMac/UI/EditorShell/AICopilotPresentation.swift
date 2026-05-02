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
