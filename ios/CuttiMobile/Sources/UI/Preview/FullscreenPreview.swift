import SwiftUI
import CuttiKit

/// Immersive full-screen preview. Shown as a `.fullScreenCover` over
/// the editor; the preview pane fills the whole display with a thin
/// bottom bar (time · play/pause · close). Tap the video area to
/// toggle chrome visibility — same gesture CapCut uses in its
/// fullscreen player. The underlying AVPlayer is shared, so state
/// (play position, play/pause) is continuous with the editor.
struct FullscreenPreview: View {
    @EnvironmentObject private var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    @State private var chromeVisible: Bool = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewPane()
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chromeVisible.toggle()
                    }
                }
            if chromeVisible {
                VStack {
                    topChrome
                    Spacer()
                    bottomChrome
                }
                .transition(.opacity)
            }
            KeyboardShortcutsLayer()
        }
        .statusBarHidden(!chromeVisible)
        .onAppear {
            // Auto-hide chrome after a moment, like a system video player.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    chromeVisible = false
                }
            }
        }
    }

    private var topChrome: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomChrome: some View {
        HStack(spacing: 16) {
            Text(formatHMS(document.currentTime))
                .font(.system(size: 13, weight: .regular).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 56, alignment: .leading)

            scrubber

            Text(formatHMS(document.primaryDurationSeconds))
                .font(.system(size: 13, weight: .regular).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 56, alignment: .trailing)

            Button { document.togglePlayback() } label: {
                Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var scrubber: some View {
        GeometryReader { proxy in
            let total = max(document.primaryDurationSeconds, 0.001)
            let progress = max(0, min(1, document.currentTime / total))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                    .frame(height: 3)
                Capsule().fill(Color.white)
                    .frame(width: proxy.size.width * progress, height: 3)
                Circle().fill(Color.white)
                    .frame(width: 12, height: 12)
                    .offset(x: proxy.size.width * progress - 6)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = max(0, min(1, value.location.x / max(proxy.size.width, 1)))
                        document.seek(toSeconds: p * total)
                    }
            )
        }
        .frame(height: 44)
    }

    private func formatHMS(_ s: Double) -> String {
        let total = Int(max(0, s).rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
