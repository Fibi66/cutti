// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Ruler

    // MARK: - Playhead scrubbing

    /// Low-latency scrubbing: coalesce overlapping seeks and use
    /// permissive tolerances so the playhead tracks the cursor
    /// without stuttering. Called from `DragGesture.onChanged`.
    func scrubSeek(to seconds: Double) {
        isScrubbing = true
        pendingScrubTime = seconds
        drainScrubQueue()
    }

    func drainScrubQueue() {
        guard !scrubSeekInFlight,
              let target = pendingScrubTime,
              let player
        else { return }
        pendingScrubTime = nil
        scrubSeekInFlight = true

        let time = CMTime(seconds: target, preferredTimescale: 600)
        // Tolerances of ±~0.1s let AVPlayer jump to the nearest
        // cached decode unit instead of hunting for the exact
        // keyframe — this is what makes scrubbing feel instant.
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { _ in
            Task { @MainActor in
                scrubSeekInFlight = false
                // If the user has moved the cursor while this
                // seek was in flight, issue the next one now.
                if pendingScrubTime != nil {
                    drainScrubQueue()
                }
            }
        }
    }

    func rulerView(width: CGFloat, totalDuration: Double) -> some View {
        // Ruler intentionally renders nothing — neither tick marks nor
        // timecode labels. The active playhead time is shown in the
        // toolbar strip above the tracks; an empty strip keeps the
        // layout reservation without adding visual noise.
        Color.clear
            .frame(width: width)
    }

    func rulerInterval(for duration: Double) -> Double {
        if duration > 300 { return 30 }
        if duration > 120 { return 10 }
        if duration > 30 { return 5 }
        return 2
    }

    func formatRulerTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

}
