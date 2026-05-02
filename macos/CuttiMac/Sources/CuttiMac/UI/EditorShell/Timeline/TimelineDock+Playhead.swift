// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Playhead

    func playheadView(width: CGFloat, totalDuration: Double) -> some View {
        let qTotal = quantizedSeconds(totalDuration)
        let qHead = quantizedSeconds(playheadSeconds)
        let x = qTotal > 0
            ? CGFloat(qHead / qTotal) * width
            : 0

        // Obsidian-style playhead: thin red vertical line with a
        // downward-pointing triangle head sitting on top of the
        // ruler. Matches `editor-obsidian.jsx`'s `OBTimeline`
        // playhead (1px red line, 11×10 triangle).
        //
        // NOTE: alignment MUST be `.topLeading`, not `.top`. A bare
        // `.top` aligns children vertically but leaves horizontal
        // alignment at the default `.center`. The ZStack sizes to its
        // widest child — the 11pt triangle — so the 1pt red rule
        // would be horizontally centred inside that 11pt box. After
        // the `.offset(x: x - 0.5)` is applied to the whole stack,
        // the rule visibly lands ~5pt RIGHT of the intended
        // composition time. That constant offset is why clicking a
        // narrow pill parked the red line near the pill's middle
        // even though the player seek and the pill layout were
        // otherwise correct. Anchoring both children to the leading
        // edge puts the rule at its intended x.
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(EditorShellStyle.timelinePlayhead)
                .frame(width: 1, height: totalContentHeight)

            Triangle()
                .fill(EditorShellStyle.timelinePlayhead)
                .frame(width: 11, height: 10)
                // Centre the triangle head on the 1pt rule by
                // shifting it left by half its width (minus the
                // rule's half-width) so visually it still "sits on
                // top of" the red line.
                .offset(x: -5, y: 0)
        }
        .offset(x: x - 0.5)
        .allowsHitTesting(false)
    }
}
