// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - New-track drop zone (bottom)

    /// Thin hit-target below the last track. Invisible at rest; when a
    /// MediaBrowser drag enters it the zone animates into an overlay-
    /// sized dashed lane with a "+ New overlay track" hint. On drop,
    /// creates a new overlay track whose clip starts at composed t=0 —
    /// the user can then drag the resulting pill to reposition (with
    /// snap to primary-segment boundaries) or use the popover to type
    /// an explicit start time.
    func newTrackDropZone(width: CGFloat) -> some View {
        ZStack {
            if isMediaDropOnNewTrack {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        EditorShellStyle.accentSolid,
                        style: StrokeStyle(lineWidth: 1.4, dash: [5, 3])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(EditorShellStyle.accentSolid.opacity(0.18))
                    )
                    .transition(.opacity)

                HStack(spacing: 4) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 10))
                    T("Drop to create new overlay track at 0:00")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(EditorShellStyle.accentSolid)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .frame(width: width, height: newTrackZoneHeight)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.16), value: isMediaDropOnNewTrack)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first,
                  dragged.hasPrefix("media:"),
                  let uuid = UUID(uuidString: String(dragged.dropFirst("media:".count)))
            else { return false }
            // Initial placement is t=0 per spec; user can drag/type to
            // reposition after the track is created. Pass a sentinel
            // duration — the view model clamps it to the source clip's
            // real length so the overlay pill visually matches the
            // actual clip duration (not a hardcoded 3s block).
            creativeActions.onInsertBRoll(uuid, 0, .greatestFiniteMagnitude)
            return true
        } isTargeted: { hovering in
            isMediaDropOnNewTrack = hovering
        }
    }

}
