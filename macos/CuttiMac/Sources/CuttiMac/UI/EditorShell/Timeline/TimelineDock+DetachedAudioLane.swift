// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Detached-audio (A2) lane

    /// Renders one detached-audio track lane. Each aux segment is
    /// positioned absolutely at `placementOffset * pps` with a width of
    /// `durationSeconds * pps`. Kept visually lighter than the primary
    /// audio waveform so users read it as a companion lane rather than
    /// a second V1.
    @ViewBuilder
    func detachedAudioLaneView(
        row: TimelineCreativeActions.DetachedAudioRow,
        width: CGFloat,
        pps: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(EditorShellStyle.panelInsetBackground.opacity(0.6))
                .frame(width: width, height: audioTrackHeight)

            ForEach(row.segments) { seg in
                detachedAudioPill(seg: seg, pps: pps)
            }
        }
        .frame(width: width, height: audioTrackHeight, alignment: .leading)
    }

    @ViewBuilder
    func detachedAudioPill(
        seg: TimelineCreativeActions.DetachedAudioSegmentHint,
        pps: CGFloat
    ) -> some View {
        // V1 (and now A1) render via HStack with each clip occupying
        // segWidth pts and its visual body filling segWidth - 2pt; no
        // separator rectangles between pills (we removed them in
        // f29f3d7). So clip N's left edge is at sum(durations[0..<N])
        // * pps with no separator accumulation.
        let x = max(0, CGFloat(quantizedSeconds(seg.startSeconds)) * pps)
        let segWidth = max(24, CGFloat(quantizedSeconds(seg.durationSeconds)) * pps)
        let visualWidth = max(8, segWidth - EditorShellStyle.timelineClipGap)
        let isSelected = selectedDetachedAudioID == seg.id
        let proxy = proxyURL(forSourceID: seg.sourceVideoID)

        Group {
            if let proxy {
                SegmentWaveform(
                    videoURL: proxy,
                    startSeconds: seg.sourceStartSeconds,
                    endSeconds: seg.sourceEndSeconds,
                    width: visualWidth,
                    height: audioTrackHeight - 4
                )
            } else {
                RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                    .fill(EditorShellStyle.obA1.opacity(0.25))
                    .frame(width: visualWidth, height: audioTrackHeight - 4)
            }
        }
        .frame(width: visualWidth, height: audioTrackHeight - 4)
        .overlay(
            RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                .strokeBorder(
                    isSelected ? EditorShellStyle.timelineClipBorderSelected : EditorShellStyle.obA1.opacity(0.55),
                    lineWidth: isSelected ? EditorShellStyle.timelineClipBorderSelectedWidth : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Detached audio has its own selection model — tapping
            // the pill selects the aux-audio clip itself, leaving
            // the V1 selection untouched so a user can (e.g.)
            // delete just the audio without losing their V1 cursor.
            selectedDetachedAudioID = seg.id
        }
        .position(x: x + visualWidth / 2, y: audioTrackHeight / 2)
        .contextMenu {
            if seg.linkedV1ID != nil {
                Button {
                    creativeActions.onReattachAudio(seg.id)
                } label: { T("Reattach to Video") }
            }
                Button(role: .destructive) {
                    creativeActions.onDeleteDetachedAudio(seg.id)
                } label: { T("Delete Audio") }
        }
    }

}
