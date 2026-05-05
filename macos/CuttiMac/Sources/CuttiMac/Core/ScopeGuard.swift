import Foundation
import CuttiKit

/// Filters an `AIActionBatch` to only actions that fall within an active
/// `ChatAttachmentScope`. Used as a belt-and-suspenders safeguard: even
/// if the LLM ignores the "ATTACHED SCOPE" system prompt instructions
/// and emits an edit outside the scope, the guard prevents that edit
/// from ever touching the timeline.
///
/// Policy:
/// - No scope (empty) ⇒ pass-through, never filters.
/// - Range actions (`deleteRange`, `setSpeedRange`) ⇒ kept iff their
///   `[start, end]` composed range is fully contained in the scope's
///   composed union (with a small epsilon for rounding).
/// - Segment-id actions (`deleteSegment`, `trimStart/End`, `setSpeed`,
///   `setVolume`, `splitSegment`, `reorderSegments`) ⇒ kept iff every
///   referenced segment id is in the attached set.
/// - Subtitle mutations with a time anchor (`editSubtitle(atSeconds:)`)
///   ⇒ kept iff the anchor falls inside the scope.
/// - Timeline-wide subtitle commands (`replaceSubtitleText`,
///   `setSubtitleStyle`, `setSubtitlesVisible`) ⇒ always rejected in
///   scoped mode (they implicitly affect content outside the scope).
enum ScopeGuard {
    struct FilterResult {
        let kept: AIActionBatch
        let rejected: [AIAction]

        var didFilter: Bool { !rejected.isEmpty }
    }

    static func filter(
        batch: AIActionBatch,
        scope: ChatAttachmentScope,
        segments: [TimelineSegment]
    ) -> FilterResult {
        guard !scope.isEmpty else {
            return FilterResult(kept: batch, rejected: [])
        }

        let attachedIDs = Set(scope.entries.map(\.segmentID))
        let index = ComposedTimelineIndex.build(from: segments)

        func segmentInScope(_ id: UUID) -> Bool {
            guard attachedIDs.contains(id),
                  let e = index.entries.first(where: { $0.segmentID == id }) else {
                return false
            }
            return scope.containsComposedRange(start: e.composedStart, end: e.composedEnd)
        }

        func rangeInScope(_ start: Double, _ end: Double) -> Bool {
            scope.containsComposedRange(start: start, end: end)
        }

        var kept: [AIAction] = []
        var rejected: [AIAction] = []

        for action in batch.actions {
            let inScope: Bool
            switch action {
            case .deleteSegment(let id):
                inScope = segmentInScope(id)
            case .splitSegment(let id, _):
                inScope = segmentInScope(id)
            case .trimStart(let id, _):
                inScope = segmentInScope(id)
            case .trimEnd(let id, _):
                inScope = segmentInScope(id)
            case .setVolume(let id, _):
                inScope = segmentInScope(id)
            case .setSpeed(let id, _):
                inScope = segmentInScope(id)
            case .deleteRange(let s, let e):
                inScope = rangeInScope(s, e)
            case .setSpeedRange(let s, let e, _):
                inScope = rangeInScope(s, e)
            case .reorderSegments(let ids):
                // Reorder is only meaningful when it touches only
                // attached segments *and* doesn't implicitly move
                // segments across the scope boundary.
                inScope = !ids.isEmpty && ids.allSatisfy { attachedIDs.contains($0) }
            case .insertSourceClip:
                // insertSourceClip pulls in arbitrary source media
                // and doesn't fit cleanly inside an attached scope
                // (the new clip's source range has no
                // attached-segment id, and the splice point can shift
                // unattached content). Conservatively reject; users
                // can run hook insertion with no scope attached.
                inScope = false
            case .editSubtitle(_, let atSeconds, _):
                if let at = atSeconds {
                    inScope = rangeInScope(at, at)
                } else {
                    // Cue-id only — we can't cheaply resolve its
                    // composed time here, so conservatively reject.
                    inScope = false
                }
            case .replaceSubtitleText, .setSubtitleStyle, .setSubtitlesVisible:
                // Timeline-wide; implicitly affects content outside
                // the scope.
                inScope = false
            }
            if inScope {
                kept.append(action)
            } else {
                rejected.append(action)
            }
        }

        return FilterResult(
            kept: AIActionBatch(actions: kept, explanation: batch.explanation),
            rejected: rejected
        )
    }

    /// Short human-readable line describing which rejected action kinds
    /// were filtered. Surfaced in a chat system bubble so the user
    /// knows what the AI attempted.
    static func describeRejections(_ actions: [AIAction]) -> String {
        guard !actions.isEmpty else { return "" }
        let names: [String] = actions.map { action in
            switch action {
            case .deleteSegment: return "delete segment"
            case .deleteRange: return "delete range"
            case .splitSegment: return "split segment"
            case .trimStart: return "trim start"
            case .trimEnd: return "trim end"
            case .setVolume: return "set volume"
            case .setSpeed: return "set speed"
            case .setSpeedRange: return "set speed range"
            case .reorderSegments: return "reorder segments"
            case .insertSourceClip: return "insert source clip"
            case .editSubtitle: return "edit subtitle"
            case .replaceSubtitleText: return "replace subtitle text"
            case .setSubtitleStyle: return "set subtitle style"
            case .setSubtitlesVisible: return "toggle subtitles"
            }
        }
        // Tally and emit "2× delete range, 1× set speed".
        let tally = names.reduce(into: [(String, Int)]()) { acc, name in
            if let idx = acc.firstIndex(where: { $0.0 == name }) {
                acc[idx].1 += 1
            } else {
                acc.append((name, 1))
            }
        }
        return tally.map { "\($0.1)× \($0.0)" }.joined(separator: ", ")
    }
}
