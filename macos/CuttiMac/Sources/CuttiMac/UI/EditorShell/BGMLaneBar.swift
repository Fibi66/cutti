import SwiftUI
import CuttiKit

/// Compact control bar for non-primary audio (BGM) tracks. Rendered just
/// above the timeline dock so users can see aux tracks they've added,
/// adjust their volume, mute them, or remove them without opening a
/// separate panel.
///
/// Intentionally minimal: one row per audio track. The timeline dock
/// itself still renders only the primary video+audio; multitrack
/// rendering in the main timeline is a larger UI task deferred until
/// the project supports >1 video/overlay track.
struct BGMLaneBar: View {
    let tracks: [Track]
    let onVolumeChange: (UUID, Double) -> Void
    let onToggleMute: (UUID) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        if tracks.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(String(format: L("BGM %d"), tracks.count))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(tracks) { track in
                    row(for: track)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func row(for track: Track) -> some View {
        HStack(spacing: 10) {
            Button {
                onToggleMute(track.id)
            } label: {
                Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(track.isMuted ? EditorShellStyle.destructiveSolid : EditorShellStyle.accentSolid)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(track.isMuted ? L("Unmute") : L("Mute"))

            Text(track.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(track.isMuted ? .secondary : .primary)

            Slider(
                value: Binding(
                    get: { track.segments.first?.volumeLevel ?? 0 },
                    set: { onVolumeChange(track.id, $0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .frame(maxWidth: 160)
            .disabled(track.isMuted)

            Text(String(format: "%.0f%%", (track.segments.first?.volumeLevel ?? 0) * 100))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()

            Spacer(minLength: 0)

            Button {
                onRemove(track.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Remove track"))
        }
    }
}
