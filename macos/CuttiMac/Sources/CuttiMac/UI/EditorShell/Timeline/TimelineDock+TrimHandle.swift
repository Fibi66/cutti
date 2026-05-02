// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    func trimHandle(edge: HorizontalEdge, index: Int, height: CGFloat, pps: CGFloat) -> some View {
        TrimHandleView(edge: edge, height: height,
            onDragChanged: { delta in
                if !trimHasFiredStart {
                    trimHasFiredStart = true
                    trimActiveIndex = index
                    trimActiveEdge = edge
                    trimOriginalDuration = segments[index].durationSeconds
                    lastAppliedTrimPixelDelta = .infinity
                    onBeginTrim(index)
                }
                // Quantise to whole-pixel deltas. Anything finer
                // would be below the zoom's display resolution but
                // would still bounce the whole timeline.
                let pixelDelta = delta.rounded()
                if abs(pixelDelta - lastAppliedTrimPixelDelta) < 1 { return }
                lastAppliedTrimPixelDelta = pixelDelta
                let deltaSeconds = Double(pixelDelta) / Double(pps)
                // Explicitly disable implicit animations: without
                // this, SwiftUI can try to interpolate every tiny
                // layout change and the high update frequency turns
                // that into visible overshoot/oscillation.
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    onLiveTrim(index, edge, deltaSeconds)
                }
            },
            onDragEnded: { _ in
                trimHasFiredStart = false
                trimActiveIndex = nil
                trimActiveEdge = nil
                trimOriginalDuration = 0
                lastAppliedTrimPixelDelta = .infinity
                onEndTrim(index)
            }
        )
    }

    /// During left-edge trim, compute how much the segment grew so we can apply negative padding.
    func leftTrimGrowth(for index: Int, pps: CGFloat) -> CGFloat {
        guard trimActiveIndex == index, trimActiveEdge == .leading else { return 0 }
        let currentDuration = segments[index].durationSeconds
        return max(0, CGFloat(currentDuration - trimOriginalDuration) * pps)
    }

    /// Current growth (in seconds) of the segment under a leading-edge trim,
    /// or 0 when no such trim is active. Positive when the user has dragged
    /// the left edge to the LEFT (segment got longer); negative when dragged
    /// to the RIGHT (segment got shorter). Callers translate this into a
    /// global scroll offset so the segment's right edge stays pinned in
    /// BOTH directions — extending shifts left-side content left, shrinking
    /// shifts left-side content right.
    func activeLeftTrimGrowthSec() -> Double {
        guard let idx = trimActiveIndex, trimActiveEdge == .leading,
              idx >= 0, idx < segments.count else { return 0 }
        return segments[idx].durationSeconds - trimOriginalDuration
    }

    /// Pixel offset to apply to any element sitting in a segment AFTER the
    /// one currently being leading-trimmed, so that it visually stays put
    /// instead of being pushed right by the growing duration.
    ///
    /// The video track already does this via `leftTrimGrowth` (applied as
    /// negative leading padding on the trimmed clip). Subtitle pills and
    /// aux-audio pills live in absolute-positioned overlays, so they need
    /// to be shifted back by the same amount — otherwise the user sees
    /// the subtitles "slide right" while the video clips appear to stay.
    /// That inconsistency is what the drag felt wrong.
    func leftTrimCompensationPx(forSegmentIndex index: Int, pps: CGFloat) -> CGFloat {
        guard let activeIdx = trimActiveIndex,
              trimActiveEdge == .leading,
              index > activeIdx else { return 0 }
        return -CGFloat(activeLeftTrimGrowthSec()) * pps
    }

    /// Time-based variant of `leftTrimCompensationPx(forSegmentIndex:pps:)`
    /// for overlays that don't know which V1 segment they belong to
    /// (e.g. detached / aux-audio clips). Applies the same negative shift
    /// to anything whose composed start lives past the trimmed segment's
    /// current right edge.
    func leftTrimCompensationPx(atComposedStart composedStart: Double, pps: CGFloat) -> CGFloat {
        guard let activeIdx = trimActiveIndex,
              trimActiveEdge == .leading,
              activeIdx >= 0, activeIdx < segments.count else { return 0 }
        var currentRightEdge = 0.0
        for i in 0...activeIdx { currentRightEdge += segments[i].durationSeconds }
        if composedStart >= currentRightEdge - 0.0001 {
            return -CGFloat(activeLeftTrimGrowthSec()) * pps
        }
        return 0
    }

    /// Global horizontal shift applied to the entire scrollable timeline
    /// content while a leading-edge trim is in progress. Equals
    /// `-growthPx` so that the right side of the timeline (everything at
    /// or past the trimmed segment's pre-trim right edge) visually stays
    /// put, while the trimmed segment itself and all content to its left
    /// slide left by the trim growth. This matches the user expectation
    /// of "dragging the left handle anchors the right edge".
    func leftTrimScrollOffsetPx(pps: CGFloat) -> CGFloat {
        -CGFloat(activeLeftTrimGrowthSec()) * pps
    }

}
