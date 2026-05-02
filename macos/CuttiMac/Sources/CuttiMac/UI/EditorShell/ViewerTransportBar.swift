import AVKit
import SwiftUI

struct ViewerTransportBar: View {
    let player: AVPlayer?
    let fps: Double

    @Binding var currentTime: Double
    @Binding var durationSeconds: Double
    @Binding var playbackRate: Double
    @Binding var isLooping: Bool
    let onSetPlaybackRate: (Double) -> Void
    let onToggleLoop: () -> Void
    let onToggleFullscreen: () -> Void
    /// Called when the focus-mode (immersive) toggle button is tapped.
    /// Independent from `onToggleFullscreen`: focus collapses panels
    /// in the main window; fullscreen also collapses the timeline.
    let onToggleFocus: () -> Void
    /// True when the host is in focus mode (panels hidden, timeline kept).
    let isFocusActive: Bool
    /// True when the host is in fullscreen mode (panels + timeline hidden).
    let isFullscreenActive: Bool

    @State private var isPlaying = false
    /// True while the user is dragging the scrub slider; suppresses timer-driven refreshes of `currentTime`.
    @State private var isScrubbing = false
    /// True when scrubbing is happening outside this view (e.g. on
    /// the timeline playhead). Drives the same gating as
    /// `isScrubbing` so the 60 Hz refresh timer doesn't overwrite
    /// `currentTime` with the player's (still-seeking) stale time
    /// and snap the playhead backwards mid-drag.
    var externallyScrubbing: Bool = false
    /// Number of programmatic seeks currently in flight (e.g. frame-step, external seeks).
    /// Suppresses timer-driven refreshes of `currentTime` until all in-flight seeks complete.
    /// Using a counter rather than a boolean prevents an earlier seek's completion callback from
    /// clearing the flag while a later seek is still in progress.
    @State private var seekingCount = 0

    // Tick ~60 Hz so the timeline playhead moves smoothly during playback
    // instead of jumping in visible 0.25s steps.
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let availableRates: [Double] = [0.5, 1.0, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 8) {
            // Frame step backward
            Button {
                stepFrame(by: -1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)
            .tooltip(L("Previous frame"))

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)
            .tooltip(isPlaying ? L("Pause") : L("Play"))

            // Frame step forward
            Button {
                stepFrame(by: 1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)
            .tooltip(L("Next frame"))

            // Speed picker
            Menu {
                ForEach(availableRates, id: \.self) { rate in
                    Button {
                        onSetPlaybackRate(rate)
                    } label: {
                        HStack {
                            Text("\(rate, specifier: rate == floor(rate) ? "%.0f" : "%.1f")x")
                            if rate == playbackRate {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text("\(playbackRate, specifier: playbackRate == floor(playbackRate) ? "%.0f" : "%.1f")x")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(playbackRate != 1.0 ? EditorShellStyle.accentSurface : Color.clear)
                    .foregroundStyle(playbackRate != 1.0 ? EditorShellStyle.accentSolid : EditorShellStyle.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
            .disabled(player == nil)
            .tooltip(L("Playback speed"))

            // Loop toggle
            Button {
                onToggleLoop()
            } label: {
                Image(systemName: isLooping ? "repeat.circle.fill" : "repeat")
                    .foregroundStyle(isLooping ? EditorShellStyle.accentSolid : EditorShellStyle.textTertiary)
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)
            .tooltip(isLooping ? L("Loop on") : L("Loop"))

            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { newValue in
                        currentTime = newValue
                        player?.seek(
                            to: CMTime(seconds: newValue, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    }
                ),
                in: 0...max(durationSeconds, 0.1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                }
            )
            .disabled(player == nil)

            Text(TimecodeFormatter.string(seconds: currentTime, fps: fps))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(EditorShellStyle.textPrimary)

            Text(TimecodeFormatter.string(seconds: durationSeconds, fps: fps))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(EditorShellStyle.textTertiary)

            Divider().frame(height: 16)

            // Focus mode — collapses chat / inspector / BGM / pane tabs
            // and puts the main window into native fullscreen, but
            // keeps the timeline + subtitles visible.
            Button { onToggleFocus() } label: {
                Image(systemName: isFocusActive
                      ? "rectangle.compress.vertical"
                      : "rectangle.expand.vertical")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isFocusActive
                                     ? EditorShellStyle.accentSolid
                                     : EditorShellStyle.textSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)
            .tooltip(L("Toggle focus mode (Esc to exit)"))

            // Fullscreen — same in-window approach as focus, but ALSO
            // collapses the timeline so the viewer (with subtitles +
            // chapter overlays) takes the whole screen.
            Button { onToggleFullscreen() } label: {
                Image(systemName: isFullscreenActive
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isFullscreenActive
                                     ? EditorShellStyle.accentSolid
                                     : EditorShellStyle.textSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)
            .tooltip(L("Toggle fullscreen (Esc to exit)"))
        }
        .padding(.horizontal, EditorShellStyle.panelPadding)
        .padding(.vertical, 10)
        .background(EditorShellStyle.chromeBackground)
        .onReceive(timer) { _ in
            refresh()
        }
    }

    private func refresh() {
        guard let player else {
            currentTime = 0
            durationSeconds = 0
            isPlaying = false
            return
        }

        // Don't overwrite currentTime while the user is scrubbing or a programmatic seek is in flight.
        // This prevents the timer from snapping the playhead back mid-interaction.
        if !isScrubbing && !externallyScrubbing && seekingCount == 0 {
            let currentSeconds = player.currentTime().seconds
            currentTime = max(0, currentSeconds.isFinite ? currentSeconds : 0)
        }

        let totalSeconds = player.currentItem?.duration.seconds ?? 0
        durationSeconds = max(0, totalSeconds.isFinite ? totalSeconds : 0)
        isPlaying = player.rate > 0
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            player.playImmediately(atRate: Float(playbackRate))
        }
        refresh()
    }

    private func stepFrame(by frames: Int) {
        guard let player else { return }

        // Pause so the stepped frame remains visible instead of being instantly
        // advanced by active playback.
        player.pause()
        isPlaying = false

        let frameDuration = 1.0 / max(fps, 1)
        let newTime = max(0, currentTime + frameDuration * Double(frames))
        let seekTime = min(newTime, durationSeconds)
        currentTime = seekTime

        // Suppress timer-driven refresh until the seek completes to avoid
        // the playhead snapping back before the new position is committed.
        // Increment before seeking; decrement in the completion handler so that
        // rapid consecutive frame-steps keep the counter > 0 until ALL seeks land.
        seekingCount += 1
        let target = CMTime(seconds: seekTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                seekingCount = max(0, seekingCount - 1)
            }
        }
    }
}
