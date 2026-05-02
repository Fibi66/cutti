import SwiftUI
import CuttiKit

/// Right-side panel showing revision history (checkpoints).
/// Users can see every AI/user action and restore to any point.
struct WorkflowPanel: View {
    let revisions: [EditorRevision]
    let currentRevisionIndex: Int
    @Binding var isExpanded: Bool
    let onRestore: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — click to collapse/expand
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(EditorShellStyle.textTertiary)
                T("HISTORY")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(EditorShellStyle.textSecondary)
                    Spacer()
                    Text("\(revisions.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(EditorShellStyle.textTertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(EditorShellStyle.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? L("Collapse history") : L("Expand history"))

            if isExpanded {
                Divider()

                // Revision list (newest at top) — wrapped in ScrollView so
                // the panel stays scrollable when the user shrinks it via
                // the resizable divider.
                ScrollView {
                    if revisions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 24))
                                .foregroundStyle(EditorShellStyle.textTertiary)
                            T("No edits yet")
                                .font(.system(size: 11))
                                .foregroundStyle(EditorShellStyle.textSecondary)
                            T("Start editing or run AI analysis\nto create checkpoints")
                                .font(.system(size: 10))
                                .foregroundStyle(EditorShellStyle.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(revisions.enumerated().reversed()), id: \.element.id) { index, revision in
                                RevisionRow(
                                    revision: revision,
                                    isCurrent: index == currentRevisionIndex,
                                    onRestore: { onRestore(revision.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .background(EditorShellStyle.panelBackground)
    }
}

// MARK: - Revision Row

private struct RevisionRow: View {
    let revision: EditorRevision
    let isCurrent: Bool
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Trigger icon
            Image(systemName: triggerIcon)
                .font(.system(size: 10))
                .foregroundStyle(triggerColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(L(revision.label))
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? EditorShellStyle.textPrimary : EditorShellStyle.textSecondary)
                    .lineLimit(1)

                Text(timeAgo)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(EditorShellStyle.textTertiary)
            }

            Spacer()

            if isCurrent {
                T("CURRENT")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(EditorShellStyle.accentSolid)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(EditorShellStyle.accentSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Button { onRestore() } label: { T("Restore") }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundStyle(EditorShellStyle.accentSolid)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent ? EditorShellStyle.accentSurface.opacity(0.6) : Color.clear)
        )
    }

    private var triggerIcon: String {
        switch revision.trigger {
        case .aiAction: return "sparkles"
        case .userEdit: return "hand.tap"
        case .analysis: return "wand.and.stars"
        case .restore: return "arrow.uturn.backward"
        case .importMedia: return "square.and.arrow.down"
        case .autosave: return "clock.arrow.circlepath"
        case .manualSave: return "bookmark.fill"
        }
    }

    private var triggerColor: Color {
        switch revision.trigger {
        case .aiAction:    return EditorShellStyle.accentSolid
        case .userEdit:    return EditorShellStyle.timelineVideoTrack
        case .analysis:    return EditorShellStyle.warningSolid
        case .restore:     return EditorShellStyle.textTertiary
        case .importMedia: return EditorShellStyle.successSolid
        case .autosave:    return EditorShellStyle.textTertiary
        case .manualSave:  return EditorShellStyle.accentSolid
        }
    }

    private var timeAgo: String {
        let interval = Date().timeIntervalSince(revision.timestamp)
        if interval < 60 { return L("just now") }
        if interval < 3600 { return L("%dm ago", Int(interval / 60)) }
        if interval < 86400 { return L("%dh ago", Int(interval / 3600)) }
        return L("%dd ago", Int(interval / 86400))
    }
}
