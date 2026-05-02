import Foundation
import CuttiKit

enum MediaRecordPresentation {
    static func title(for record: MediaAssetRecord) -> String {
        URL(fileURLWithPath: record.sourcePath).lastPathComponent
    }

    /// Returns the technical metadata summary when analysis exists.
    /// When analysis isn't ready yet we intentionally return an empty
    /// string so the sidebar cell stays compact — the video itself is
    /// the point, not our pipeline's bookkeeping.
    static func metadataLine(for record: MediaAssetRecord) -> String {
        guard let analysis = record.analysis else { return "" }
        return "\(durationText(for: analysis)) • \(analysis.width)×\(analysis.height)"
    }

    static func statusText(for status: MediaStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .analyzing: return "Analyzing"
        case .transcoding: return "Transcoding"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .missing: return "Missing"
        }
    }

    static func timelineWidth(for record: MediaAssetRecord) -> Double {
        TimelineScale.clipWidth(for: record)
    }

    static func inspectorResolution(for record: MediaAssetRecord) -> String {
        guard let analysis = record.analysis else { return "Unknown" }
        return "\(analysis.width) × \(analysis.height)"
    }

    static func inspectorDuration(for record: MediaAssetRecord) -> String {
        guard let analysis = record.analysis else { return statusText(for: record.status) }
        return durationText(for: analysis)
    }

    static func inspectorAudio(for record: MediaAssetRecord) -> String {
        guard let analysis = record.analysis else { return "Unknown" }
        return analysis.hasAudio ? "Audio detected" : "No audio track"
    }

    private static func durationText(for analysis: AnalysisSummary) -> String {
        let seconds = Int(analysis.durationSeconds.rounded(.down))
        return "\(seconds)s"
    }
}
