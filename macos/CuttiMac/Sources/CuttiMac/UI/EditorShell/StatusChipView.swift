import SwiftUI
import CuttiKit

struct StatusChipView: View {
    let status: MediaStatus

    var body: some View {
        Text(MediaRecordPresentation.statusText(for: status))
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.18))
            .foregroundStyle(backgroundColor)
            .overlay(
                Capsule()
                    .strokeBorder(backgroundColor.opacity(0.35), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch status {
        case .queued: return EditorShellStyle.accentSolid
        case .analyzing, .transcoding: return EditorShellStyle.warningSolid
        case .ready: return EditorShellStyle.successSolid
        case .failed: return EditorShellStyle.destructiveSolid
        case .missing: return EditorShellStyle.timelineAudioTrack
        }
    }
}
