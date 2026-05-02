import SwiftUI

/// CapCut-style compact transport row sitting between the preview and
/// the timeline.
///
/// Reference layout (IMG_8070):
///   00:07 / 01:33        ▷        🔁ON  ↶  ↷  ⛶
///   (time leading)   (play center)   (right cluster)
/// Row height matches CapCut's compact chrome (~40pt) so the preview
/// above gets maximum screen real estate.
struct TransportBar: View {
    @EnvironmentObject private var document: ProjectDocument
    @EnvironmentObject private var appState: AppState
    @State private var showFullscreen: Bool = false
    @State private var loopEnabled: Bool = false

    var body: some View {
        ZStack {
            // Left: timecode, leading.
            HStack(spacing: 0) {
                Text(
                    formatHMS(document.currentTime)
                    + " / "
                    + formatHMS(document.primaryDurationSeconds)
                )
                .font(.system(size: 12, weight: .regular).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
            }

            // Center: play/pause — big, centered, no background.
            Button { document.togglePlayback() } label: {
                Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 36)
            }

            // Right cluster: loop-on, undo, redo, fullscreen.
            HStack(spacing: 20) {
                Spacer(minLength: 0)
                iconButton(
                    systemName: loopEnabled ? "repeat.circle.fill" : "repeat",
                    tint: loopEnabled ? .white : .white.opacity(0.9)
                ) {
                    loopEnabled.toggle()
                    document.player.actionAtItemEnd = loopEnabled ? .none : .pause
                }
                iconButton(
                    systemName: "arrow.uturn.backward",
                    tint: document.canUndo ? .white : .white.opacity(0.35),
                    enabled: document.canUndo
                ) { document.undo() }
                iconButton(
                    systemName: "arrow.uturn.forward",
                    tint: document.canRedo ? .white : .white.opacity(0.35),
                    enabled: document.canRedo
                ) { document.redo() }
                iconButton(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    tint: .white
                ) { showFullscreen = true }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.black)
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenPreview()
                .environmentObject(document)
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func iconButton(
        systemName: String,
        tint: Color,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
        }
        .disabled(!enabled)
    }

    private func formatHMS(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
