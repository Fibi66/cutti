import SwiftUI
import CuttiKit

/// A thin horizontal strip that renders AI timeline markers for a single clip.
///
/// `AICopilotMarker` is not `Identifiable`, so the `ForEach` uses an explicit
/// enumerated index as the stable key.
struct TimelineAIMarkerStrip: View {
    let record: MediaAssetRecord
    let markers: [AICopilotMarker]
    /// The available content width in points (card width minus horizontal insets).
    let width: Double

    var body: some View {
        ZStack(alignment: .leading) {
            // Base track
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.06))
                .frame(width: CGFloat(width), height: 6)

            // Marker bars — enumerated to avoid relying on Identifiable
            ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                markerBar(for: marker)
            }
        }
        .frame(width: CGFloat(width), height: 6, alignment: .leading)
    }

    private func markerBar(for marker: AICopilotMarker) -> some View {
        let xOffset = TimelineScale.markerOffset(
            seconds: marker.seconds,
            clipWidth: width,
            durationSeconds: TimelineScale.duration(for: record)
        )
        return RoundedRectangle(cornerRadius: 1)
            .fill(markerColor(for: marker.kind))
            .frame(width: 3, height: 6)
            .offset(x: CGFloat(xOffset))
    }

    private func markerColor(for kind: AICopilotMarker.Kind) -> Color {
        switch kind {
        case .scene:      return EditorShellStyle.timelineScene
        case .suggestion: return EditorShellStyle.agentReady
        case .warning:    return EditorShellStyle.warningSolid
        case .highlight:  return EditorShellStyle.obSub
        }
    }
}
