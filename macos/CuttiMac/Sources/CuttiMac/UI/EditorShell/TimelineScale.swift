import Foundation
import CuttiKit

/// Shared scale math for the Cutti timeline.
///
/// All timeline geometry — clip widths, marker offsets, and playhead offsets — derives
/// from a single `pointsPerSecond` constant so every layer stays in sync.
enum TimelineScale {

    // MARK: - Constants

    /// Points per second used for all timeline layout calculations.
    static let pointsPerSecond: Double = 28

    /// Minimum clip width in points (clips shorter than ~5.7 s still get a usable tile).
    static let minimumClipWidth: Double = 160

    /// Maximum clip width in points (prevents very long clips from dominating the scroll area).
    static let maximumClipWidth: Double = 720

    /// Fallback clip duration used when `AnalysisSummary` is absent.
    static let fallbackDurationSeconds: Double = 3

    // MARK: - Duration

    /// Returns the analysed duration for `record`, or `fallbackDurationSeconds` when analysis is unavailable.
    static func duration(for record: MediaAssetRecord) -> Double {
        record.analysis?.durationSeconds ?? fallbackDurationSeconds
    }

    // MARK: - Clip width

    /// Returns the timeline width in points for `record`, clamped between
    /// `minimumClipWidth` and `maximumClipWidth`.
    static func clipWidth(for record: MediaAssetRecord) -> Double {
        let raw = duration(for: record) * pointsPerSecond
        return max(minimumClipWidth, min(raw, maximumClipWidth))
    }

    // MARK: - Marker offset

    /// Returns the horizontal offset in points for a marker at `seconds` within a clip of
    /// `durationSeconds`, mapped proportionally over `clipWidth`.
    ///
    /// Using normalized progress `(clampedSeconds / durationSeconds) * clipWidth` ensures the
    /// offset is correct even when `clipWidth` has been clamped away from its natural
    /// `durationSeconds * pointsPerSecond` value (i.e. for very short or very long clips).
    static func markerOffset(seconds: Double, clipWidth: Double, durationSeconds: Double) -> Double {
        guard durationSeconds > 0 else { return 0 }
        let clamped = max(0, min(seconds, durationSeconds))
        return (clamped / durationSeconds) * clipWidth
    }

    // MARK: - Playhead offset

    /// Returns the horizontal offset in points for a playhead at `seconds`, using the same
    /// normalized-progress mapping as `markerOffset`.
    static func playheadOffset(seconds: Double, clipWidth: Double, durationSeconds: Double) -> Double {
        markerOffset(seconds: seconds, clipWidth: clipWidth, durationSeconds: durationSeconds)
    }
}
