import Foundation
import CuttiKit

/// A segment-scoped attachment surfaced in the AI chat composer.
///
/// When one or more attachments are active, the AI editor is constrained
/// to operate exclusively within the union of their composed-timeline
/// ranges. User-facing time references in the prompt are interpreted as
/// *virtual* (segment-local) time, concatenated across attachments in the
/// order they were attached:
///
///   virtual [0, dur0]            -> attachments[0] composed [c0s, c0e]
///   virtual [dur0, dur0+dur1]    -> attachments[1] composed [c1s, c1e]
///   ...
///
/// Attachments are **not persisted** across sessions. They reference a
/// `TimelineSegment` by id; if that segment disappears or is rewritten
/// the attachment becomes invalid and is hidden / ignored by the scope
/// guard. The composed range is captured as a snapshot at attach time so
/// the chip UI has stable labels even if the timeline mutates.
struct ChatAttachment: Identifiable, Equatable, Hashable {
    let id: UUID
    /// Identifies the source `TimelineSegment`. If that segment no longer
    /// exists in `MediaCoreViewModel.timelineSegments`, the attachment is
    /// considered invalid.
    let segmentID: UUID
    /// Composed-timeline seconds at the moment of attachment. Used for
    /// UI labels and as the authoritative scope window for the ScopeGuard.
    let composedStart: Double
    let composedEnd: Double
    /// The source video id backing this segment at attach time — used to
    /// render the first-frame thumbnail. Cached so the chip keeps
    /// rendering even if the underlying segment is mutated mid-session.
    let sourceVideoID: UUID
    /// Source-video seconds of the segment's first frame (`segment.range.startSeconds`
    /// at attach time). Used as the thumbnail seek target.
    let sourceStartSeconds: Double

    init(
        id: UUID = UUID(),
        segmentID: UUID,
        composedStart: Double,
        composedEnd: Double,
        sourceVideoID: UUID,
        sourceStartSeconds: Double
    ) {
        self.id = id
        self.segmentID = segmentID
        self.composedStart = composedStart
        self.composedEnd = composedEnd
        self.sourceVideoID = sourceVideoID
        self.sourceStartSeconds = sourceStartSeconds
    }

    var composedDuration: Double { max(0, composedEnd - composedStart) }
}

// MARK: - Virtual Timeline

/// Maps the AI chat's *virtual* (segment-local, concatenated) timeline
/// onto real composed-timeline coordinates. Built fresh for each LLM
/// turn from the currently-valid attachments in attach order.
struct ChatAttachmentScope: Equatable {
    /// Per-attachment mapping entry.
    struct Entry: Equatable {
        let attachmentID: UUID
        let segmentID: UUID
        /// Virtual timeline start (seconds). First entry is always 0.
        let virtualStart: Double
        /// Virtual timeline end (seconds).
        let virtualEnd: Double
        /// Real composed-timeline start (seconds).
        let composedStart: Double
        /// Real composed-timeline end (seconds).
        let composedEnd: Double

        var virtualDuration: Double { virtualEnd - virtualStart }
    }

    let entries: [Entry]

    /// Total length of the virtual timeline (sum of entry durations).
    var virtualDuration: Double {
        entries.last?.virtualEnd ?? 0
    }

    /// Build a scope from attachments in their current order. Attachments
    /// whose composed range is degenerate (<= 0) are skipped.
    init(attachments: [ChatAttachment]) {
        var cursor: Double = 0
        var out: [Entry] = []
        out.reserveCapacity(attachments.count)
        for att in attachments {
            let dur = att.composedDuration
            guard dur > 0 else { continue }
            let start = cursor
            let end = cursor + dur
            out.append(Entry(
                attachmentID: att.id,
                segmentID: att.segmentID,
                virtualStart: start,
                virtualEnd: end,
                composedStart: att.composedStart,
                composedEnd: att.composedEnd
            ))
            cursor = end
        }
        self.entries = out
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Translate a virtual-time range to one or more composed-time
    /// ranges. A range that spans attachment boundaries decomposes into
    /// multiple composed ranges (one per attachment it overlaps). Returns
    /// `nil` if the input range falls entirely outside the scope.
    func composedRanges(forVirtualStart vStart: Double, end vEnd: Double) -> [ClosedRange<Double>]? {
        guard vEnd > vStart else { return nil }
        var out: [ClosedRange<Double>] = []
        for e in entries {
            let overlapStart = max(vStart, e.virtualStart)
            let overlapEnd = min(vEnd, e.virtualEnd)
            guard overlapEnd > overlapStart else { continue }
            let cs = e.composedStart + (overlapStart - e.virtualStart)
            let ce = e.composedStart + (overlapEnd - e.virtualStart)
            out.append(cs...ce)
        }
        return out.isEmpty ? nil : out
    }

    /// True if the given composed-time range lies entirely inside the
    /// union of the scope's composed ranges (used by ScopeGuard to
    /// reject out-of-scope LLM actions).
    func containsComposedRange(start: Double, end: Double, epsilon: Double = 0.05) -> Bool {
        guard end >= start else { return false }
        // Remaining portion of [start, end] that still needs to be covered.
        var remaining: [ClosedRange<Double>] = [start...end]
        for e in entries {
            var next: [ClosedRange<Double>] = []
            for r in remaining {
                let os = max(r.lowerBound, e.composedStart - epsilon)
                let oe = min(r.upperBound, e.composedEnd + epsilon)
                if oe >= os {
                    // Subtract [os, oe] from r.
                    if r.lowerBound < os { next.append(r.lowerBound...os) }
                    if oe < r.upperBound { next.append(oe...r.upperBound) }
                } else {
                    next.append(r)
                }
            }
            remaining = next
            if remaining.isEmpty { return true }
        }
        // Anything left uncovered (ignoring epsilon-sized slivers) => out of scope.
        return remaining.allSatisfy { $0.upperBound - $0.lowerBound <= epsilon }
    }
}
