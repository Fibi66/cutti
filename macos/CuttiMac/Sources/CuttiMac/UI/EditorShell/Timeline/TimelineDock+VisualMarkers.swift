// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Visual markers overlay

    /// Render small colored dots on the ruler for each
    /// `TimelineCreativeActions.MarkerHint`. Dot color encodes the
    /// anomaly kind so the user can tell black frames from scene
    /// changes at a glance.
    func visualMarkersView(width: CGFloat, totalDuration: Double) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(creativeActions.markers) { m in
                let mid = (m.composedStart + m.composedEnd) / 2
                let frac = totalDuration > 0 ? mid / totalDuration : 0
                let x = CGFloat(frac) * width
                Circle()
                    .fill(markerColor(kind: m.kind))
                    .frame(width: 5, height: 5)
                    .offset(x: max(0, x - 2.5), y: -2)
                    .tooltip(markerTooltip(for: m))
            }
        }
        .frame(width: width, alignment: .leading)
        .allowsHitTesting(false)
    }

    func markerColor(kind: String) -> Color {
        switch kind {
        case "black": return .red
        case "no_face": return .orange
        case "scene_change": return .yellow
        default: return .gray
        }
    }

    func markerTooltip(for m: TimelineCreativeActions.MarkerHint) -> String {
        let label: String
        switch m.kind {
        case "black": label = "Black frames"
        case "no_face": label = "No face on screen"
        case "scene_change": label = "Scene change"
        default: label = m.kind
        }
        return "\(label): \(String(format: "%.2fs", m.composedStart))–\(String(format: "%.2fs", m.composedEnd))"
    }

}
