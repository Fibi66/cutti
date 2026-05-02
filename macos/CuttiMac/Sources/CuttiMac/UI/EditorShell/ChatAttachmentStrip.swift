import SwiftUI
import CuttiKit

/// Horizontal chip strip shown above the chat composer when the user has
/// dragged one or more timeline segments into the AI Edit window. Each
/// chip shows:
///   - the first-frame thumbnail of the segment
///   - the composed-timeline range it occupies (e.g. `12.3s → 18.7s`)
///   - a close (×) button that removes just that attachment
///
/// Attachments whose referenced segment has been deleted from the
/// timeline render as a dimmed "removed" chip so the user can clean
/// them up; the AI pipeline already ignores them via
/// `validChatAttachments`.
struct ChatAttachmentStrip: View {
    let attachments: [ChatAttachment]
    let liveSegmentIDs: Set<UUID>
    let records: [MediaAssetRecord]
    let projectRoot: URL?
    let onRemove: (UUID) -> Void
    let onClearAll: () -> Void

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(EditorShellStyle.accentSolid)
                    Text(String(format: L("Scoped to %d segment(s)"), attachments.count))
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(EditorShellStyle.textSecondary)
                    Spacer()
                    Button(action: onClearAll) {
                        T("CLEAR")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(EditorShellStyle.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Remove all attachments"))
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(
                                attachment: attachment,
                                isValid: liveSegmentIDs.contains(attachment.segmentID),
                                records: records,
                                projectRoot: projectRoot,
                                onRemove: { onRemove(attachment.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .background(EditorShellStyle.chromeBackground)
        }
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let isValid: Bool
    let records: [MediaAssetRecord]
    let projectRoot: URL?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SegmentFirstFrameThumbnailView(
                sourceVideoID: attachment.sourceVideoID,
                sourceStartSeconds: attachment.sourceStartSeconds,
                records: records,
                projectRoot: projectRoot,
                size: CGSize(width: 48, height: 30)
            )
            .opacity(isValid ? 1.0 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(timeRangeLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isValid ? EditorShellStyle.textPrimary : EditorShellStyle.textTertiary)
                Text(durationLabel)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(EditorShellStyle.textTertiary)
            }

            if !isValid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(EditorShellStyle.warningSolid)
                    .help(L("This segment no longer exists on the timeline"))
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(EditorShellStyle.textTertiary)
            }
            .buttonStyle(.plain)
            .help(L("Remove attachment"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(EditorShellStyle.panelInsetBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isValid
                        ? EditorShellStyle.accentSolid.opacity(0.4)
                        : EditorShellStyle.borderSubtle,
                    lineWidth: 1
                )
        )
    }

    private var timeRangeLabel: String {
        let s = format(attachment.composedStart)
        let e = format(attachment.composedEnd)
        return "\(s) → \(e)"
    }

    private var durationLabel: String {
        "\(format(attachment.composedDuration)) scope"
    }

    private func format(_ seconds: Double) -> String {
        if seconds >= 60 {
            let m = Int(seconds) / 60
            let s = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%04.1f", m, s)
        }
        return String(format: "%.1fs", seconds)
    }
}
