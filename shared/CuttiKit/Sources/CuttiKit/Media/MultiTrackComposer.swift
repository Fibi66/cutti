import Foundation

/// Pure (no AVFoundation, no I/O) planner for multi-track video rendering.
///
/// Takes the project's primary segments + overlay tracks and produces:
///   1. A placement plan — where each segment lives on the composed
///      timeline, and on which render lane (primary = 0, overlays = 1..n).
///   2. Layer-instruction intervals — time ranges together with which
///      lanes are active, so the compositor can stack layers top-to-bottom.
///
/// Primary segments play back-to-back starting at t=0. Overlay track
/// segments may either flow sequentially *within* their track (starting
/// from `trackStart`, the first segment's `placementOffset ?? 0`) or be
/// individually anchored via each segment's `placementOffset`. An overlay
/// track with no `placementOffset` on any segment starts at composed t=0
/// which is usually wrong; callers should set the offset on the first
/// segment.
public enum MultiTrackComposer {

    /// A single segment's resolved position on the composed timeline and
    /// which render lane it belongs to. `laneIndex == 0` is the primary
    /// video track; 1..n are overlays in input order.
    public struct Placement: Equatable {
        public let laneIndex: Int
        public let segment: TimelineSegment
        public let composedStart: Double
        public let composedEnd: Double
        public var composedDuration: Double { composedEnd - composedStart }
    }

    /// A time interval during which a fixed set of lanes are active. The
    /// lanes array is ordered **bottom-to-top** — element 0 is the
    /// background, the last element is the topmost layer rendered.
    public struct Interval: Equatable {
        public let start: Double
        public let end: Double
        /// Lane indices active during this interval, bottom-first. Always
        /// includes `0` (primary) whenever the primary has coverage here.
        public let lanes: [Int]
    }

    public struct Plan: Equatable {
        public let placements: [Placement]
        public let intervals: [Interval]
        public let totalDuration: Double
    }

    /// Build the render plan.
    ///
    /// - Parameters:
    ///   - primarySegments: the main video track's segments. Laid end-to-
    ///     end starting at t=0. Placement offsets on the primary are
    ///     ignored (primary is always sequential).
    ///   - overlayTracks: overlay video tracks in z-order (first is
    ///     lowest). Each track's segments flow sequentially from the
    ///     first segment's `placementOffset ?? 0`, unless a segment
    ///     provides its own `placementOffset` which resets the running
    ///     offset to that value.
    public static func plan(
        primarySegments: [TimelineSegment],
        overlayTracks: [Track]
    ) -> Plan {
        var placements: [Placement] = []

        // Primary lane — sequential.
        var t = 0.0
        for seg in primarySegments {
            let start = t
            let end = t + seg.durationSeconds
            placements.append(Placement(
                laneIndex: 0,
                segment: seg,
                composedStart: start,
                composedEnd: end
            ))
            t = end
        }
        let primaryEnd = t

        // Overlay lanes — each with its own running offset; reset when a
        // segment supplies an explicit placementOffset.
        for (trackIdx, track) in overlayTracks.enumerated() {
            let lane = trackIdx + 1
            var cursor = track.segments.first?.placementOffset ?? 0
            for seg in track.segments {
                if let anchor = seg.placementOffset {
                    cursor = anchor
                }
                let start = cursor
                let end = cursor + seg.durationSeconds
                placements.append(Placement(
                    laneIndex: lane,
                    segment: seg,
                    composedStart: start,
                    composedEnd: end
                ))
                cursor = end
            }
        }

        let totalDuration = max(primaryEnd, placements.map(\.composedEnd).max() ?? 0)
        let intervals = buildIntervals(placements: placements, totalDuration: totalDuration)
        return Plan(
            placements: placements,
            intervals: intervals,
            totalDuration: totalDuration
        )
    }

    /// Given resolved placements, split the composed timeline into
    /// intervals during which a fixed set of lanes is active. Produces a
    /// sorted, non-overlapping list of `Interval`s covering
    /// `[0, totalDuration)`.
    public static func buildIntervals(
        placements: [Placement],
        totalDuration: Double
    ) -> [Interval] {
        guard totalDuration > 0 else { return [] }
        // Collect every boundary where the active set could change.
        var boundaries = Set<Double>([0, totalDuration])
        for p in placements {
            boundaries.insert(max(0, p.composedStart))
            boundaries.insert(min(totalDuration, p.composedEnd))
        }
        let sorted = boundaries.sorted()
        var out: [Interval] = []
        for i in 0..<(sorted.count - 1) {
            let s = sorted[i]
            let e = sorted[i + 1]
            guard e - s > 0.0005 else { continue }
            let mid = (s + e) / 2
            let active = placements
                .filter { mid >= $0.composedStart && mid < $0.composedEnd }
                .map(\.laneIndex)
                .sorted()
            guard !active.isEmpty else { continue }
            // Merge with the previous interval if its active-lane set is
            // identical; primary-only segment boundaries are a common case
            // (e.g. two primary segments end-to-end should yield one
            // interval, not N).
            if var last = out.last, last.lanes == active, abs(last.end - s) < 0.0005 {
                last = Interval(start: last.start, end: e, lanes: active)
                out[out.count - 1] = last
            } else {
                out.append(Interval(start: s, end: e, lanes: active))
            }
        }
        return out
    }
}
