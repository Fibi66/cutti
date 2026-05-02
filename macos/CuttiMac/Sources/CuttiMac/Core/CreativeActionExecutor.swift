import Foundation
import CuttiKit

/// Applies `CreativeAction` cases that produce Project-level changes
/// (new overlay tracks, anchored segments, etc.). Unlike
/// `CreativeActionMapper` — which plans segment-list edits — this layer
/// mutates a whole `Project` and is invoked by the Agent tool-call
/// dispatcher alongside `edit_timeline` for trim/delete actions.
///
/// Currently supports:
/// - `insertBRoll`: creates (or extends) an overlay track carrying a
///   single TimelineSegment anchored to the given composed time. The
///   segment's `placementOffset` is set so the compositor inserts at
///   the right offset regardless of surrounding segments.
///
/// Follow-ups: `insertTitleCard` (synthetic media asset), `applyKenBurns`
/// (per-segment transform metadata).
enum CreativeActionExecutor {

    enum ExecutionError: Error, LocalizedError {
        case mediaNotFound(UUID)
        case unsupportedAction

        var errorDescription: String? {
            switch self {
            case .mediaNotFound(let id): return "Media asset \(id) not found in project."
            case .unsupportedAction: return "Creative action not yet executable."
            }
        }
    }

    /// Resolves how long the source media actually is so we can clamp the
    /// requested duration without allowing the executor to reach outside
    /// the media's bounds. Returning `nil` means "unknown" and the
    /// executor will trust the requested duration.
    typealias MediaDurationProvider = (UUID) -> Double?

    /// Apply a single CreativeAction to `project`, returning the updated
    /// Project. Throws if the action can't be executed yet.
    @discardableResult
    static func apply(
        _ action: CreativeAction,
        to project: Project,
        mediaDuration: MediaDurationProvider = { _ in nil }
    ) throws -> Project {
        switch action {
        case .insertBRoll(let composedTime, let mediaID, let duration, let muteOriginal):
            return try applyInsertBRoll(
                project: project,
                composedTime: max(0, composedTime),
                mediaID: mediaID,
                duration: max(0.1, duration),
                muteOriginal: muteOriginal,
                mediaDuration: mediaDuration
            )
        case .insertCrossfade, .insertTitleCard, .applyKenBurns:
            // Crossfades are handled by CreativeActionMapper on the
            // segment list; title cards and Ken-Burns need compositor
            // support we haven't shipped yet.
            throw ExecutionError.unsupportedAction
        }
    }

    // MARK: - insertBRoll

    private static func applyInsertBRoll(
        project: Project,
        composedTime: Double,
        mediaID: UUID,
        duration: Double,
        muteOriginal: Bool,
        mediaDuration: MediaDurationProvider
    ) throws -> Project {
        // Clamp to source media length when known. If the caller can't
        // supply a duration we take the request at face value; exporter
        // still clamps per source frame range.
        let effectiveDuration: Double
        if let total = mediaDuration(mediaID), total > 0 {
            effectiveDuration = min(duration, total)
        } else {
            effectiveDuration = duration
        }
        guard effectiveDuration > 0.05 else { throw ExecutionError.unsupportedAction }

        let overlaySegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: mediaID,
            range: TimeRange(startSeconds: 0, endSeconds: effectiveDuration),
            text: "",
            subtitles: [],
            volumeLevel: muteOriginal ? 1.0 : 0.0,
            placementOffset: composedTime
        )

        var next = project
        // Always append a fresh overlay track so concurrent B-roll
        // insertions don't collide on placement. Naming follows the
        // convention used for the primary track (V2, V3, …).
        let overlayCount = next.tracks.filter { $0.kind == .overlay }.count
        let track = Track(
            kind: .overlay,
            name: "V\(overlayCount + 2) (B-roll)",
            segments: [overlaySegment]
        )
        next.tracks.append(track)

        if muteOriginal {
            // Future: also duck the primary track's audio during the
            // overlay window. We leave primary audio untouched for now —
            // the user asked for video overlay, audio ducking is a
            // follow-up that requires a range-based AudioMix curve on
            // the primary track.
        }

        return next
    }
}
