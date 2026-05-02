import Foundation

/// A pending Agent edit that has been *computed* (dry-run) but not yet
/// committed to the timeline. Produced by the tool-call handler in
/// manual mode, shown in chat as a card with Apply / Reject actions.
///
/// The pre-computed `previewSegments` are **advisory**: if the user
/// makes a manual edit between the proposal and their Apply click,
/// the VM re-applies the original `batch` against the *current*
/// timeline, not against the stale preview. That way concurrent user
/// edits aren't clobbered.
public struct ProposedBatch: Identifiable {

    /// Stable identity. Used by chat bubbles to link back to this
    /// proposal. Not the same as the OpenAI tool_call_id (that's
    /// stored separately so a tool reply can be threaded back to the
    /// LLM if we need to).
    public let id: UUID

    /// The OpenAI tool-call id this proposal answers. Used when
    /// forwarding the final outcome (applied / rejected) back into
    /// the model's message history.
    public let toolCallID: String

    /// The original batch emitted by the Agent. Kept verbatim so we
    /// can re-apply it (against current timeline) at Apply time.
    public let batch: AIActionBatch

    /// Counts derived from the dry-run against the snapshot at
    /// proposal time. Purely informational — the true counts at
    /// Apply time may differ if the timeline changed.
    public let previewAppliedCount: Int
    public let previewSkippedCount: Int

    /// Segment IDs that the dry-run would **remove** from the primary
    /// timeline. Used to paint timeline segments red as a diff hint.
    public let deletedSegmentIDs: Set<UUID>

    /// Segment IDs whose speed the dry-run would change. Painted blue.
    public let speedChangedSegmentIDs: Set<UUID>

    /// Segment IDs whose volume the dry-run would change. Painted
    /// amber. (Lower signal than speed/delete but still useful.)
    public let volumeChangedSegmentIDs: Set<UUID>

    /// Whether this proposal would change the subtitle style.
    public let touchesSubtitleStyle: Bool

    /// Short per-segment before→after delta rows for the proposal
    /// card. Rendered as "Seg #3 vol 1.00 → 0.50" lines so the user
    /// can see exactly what a multi-action batch would change beyond
    /// the aggregate chip counts. Capped at 10 entries to keep the
    /// card compact — anything extra is summarized via the chips.
    public let diffRows: [DiffRow]

    /// Total duration before / after (seconds). Shown in the card so
    /// the user immediately sees whether a destructive batch shortens
    /// the edit.
    public let beforeTotalSeconds: Double
    public let afterTotalSeconds: Double

    public struct DiffRow: Equatable {
        public enum Kind: String {
            case delete, speed, volume, trim, split, reorder, subtitle
        }
        /// 1-based segment index in the before snapshot (deletes /
        /// modifications) or after snapshot (splits / new).
        public let segmentIndex: Int
        public let kind: Kind
        public let before: String
        public let after: String
    }

    /// Wall-clock creation time. Helps with ordering + trace views.
    public let createdAt: Date

    /// Lifecycle. Starts `.pending`. Terminal states are recorded so a
    /// history of applied/rejected proposals can be shown in the trace
    /// view (F3) without needing to re-parse chat bubbles.
    public var decision: Decision

    public enum Decision: String, Equatable, Codable, Sendable {
        case pending
        case applied
        case rejected
        /// The proposal couldn't be applied because the timeline it
        /// referenced no longer exists (e.g. user undid the segments
        /// it targeted before clicking Apply).
        case stale
    }

    /// Short human-readable description ("Delete 23 filler cues")
    /// used for chat card titles and trace nodes.
    public var title: String {
        if !batch.explanation.isEmpty { return batch.explanation }
        if previewAppliedCount == 0 {
            return "No-op (\(batch.actions.count) action\(batch.actions.count == 1 ? "" : "s") skipped)"
        }
        let delCount = deletedSegmentIDs.count
        if delCount > 0 && delCount == previewAppliedCount {
            return "Delete \(delCount) segment\(delCount == 1 ? "" : "s")"
        }
        return "Apply \(previewAppliedCount) edit\(previewAppliedCount == 1 ? "" : "s")"
    }

    // MARK: - Factory

    /// Build a proposal from a dry-run executor result against a
    /// snapshot of segments. The caller already ran
    /// `AIActionExecutor.apply` and passes both the `before` segments
    /// and the resulting `Result`.
    public static func make(
        id: UUID = UUID(),
        toolCallID: String,
        batch: AIActionBatch,
        before: [TimelineSegment],
        dryRun: AIActionExecutor.Result,
        now: Date = Date()
    ) -> ProposedBatch {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let beforeIndexByID = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($0.element.id, $0.offset) })
        let afterIDs = Set(dryRun.segments.map(\.id))

        var deleted = Set<UUID>()
        var speedChanged = Set<UUID>()
        var volumeChanged = Set<UUID>()
        var rows: [DiffRow] = []

        for seg in before {
            if !afterIDs.contains(seg.id) {
                deleted.insert(seg.id)
                if rows.count < 10 {
                    rows.append(DiffRow(
                        segmentIndex: (beforeIndexByID[seg.id] ?? 0) + 1,
                        kind: .delete,
                        before: String(format: "%.1fs", seg.durationSeconds),
                        after: "∅"
                    ))
                }
            }
        }
        for seg in dryRun.segments {
            guard let prev = beforeByID[seg.id] else { continue }
            if abs(prev.speedRate - seg.speedRate) > 0.001 {
                speedChanged.insert(seg.id)
                if rows.count < 10 {
                    rows.append(DiffRow(
                        segmentIndex: (beforeIndexByID[seg.id] ?? 0) + 1,
                        kind: .speed,
                        before: String(format: "%.2fx", prev.speedRate),
                        after: String(format: "%.2fx", seg.speedRate)
                    ))
                }
            }
            if abs(prev.volumeLevel - seg.volumeLevel) > 0.001 {
                volumeChanged.insert(seg.id)
                if rows.count < 10 {
                    rows.append(DiffRow(
                        segmentIndex: (beforeIndexByID[seg.id] ?? 0) + 1,
                        kind: .volume,
                        before: String(format: "%.2f", prev.volumeLevel),
                        after: String(format: "%.2f", seg.volumeLevel)
                    ))
                }
            }
        }

        let beforeTotal = before.reduce(0.0) { $0 + $1.durationSeconds }
        let afterTotal = dryRun.segments.reduce(0.0) { $0 + $1.durationSeconds }

        return ProposedBatch(
            id: id,
            toolCallID: toolCallID,
            batch: batch,
            previewAppliedCount: dryRun.appliedCount,
            previewSkippedCount: dryRun.skippedCount,
            deletedSegmentIDs: deleted,
            speedChangedSegmentIDs: speedChanged,
            volumeChangedSegmentIDs: volumeChanged,
            touchesSubtitleStyle: dryRun.subtitleStyle != nil || dryRun.showSubtitles != nil,
            diffRows: rows,
            beforeTotalSeconds: beforeTotal,
            afterTotalSeconds: afterTotal,
            createdAt: now,
            decision: .pending
        )
    }
}
