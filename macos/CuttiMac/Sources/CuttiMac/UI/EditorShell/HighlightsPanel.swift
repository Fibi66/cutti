import SwiftUI
import CuttiKit

/// Right-column section that surfaces persisted `.highlight` markers
/// across all source records — the destination for ⌘⇧3 hook
/// candidates and (PR 10+) any user-saved excerpts. Read-only in PR 9:
/// users can click a row to jump to its source clip, or drag it onto
/// the timeline to insert that span as a new V1 segment.
///
/// Vertically positioned between History and AI Log in the right
/// column. Empty state shows a "run ⌘⇧3" prompt so the panel still
/// answers the question "what's this for?" before any AI run lands.
struct HighlightsPanel: View {
    let groups: [AICopilotPresentation.HighlightGroup]
    let totalCount: Int
    let records: [MediaAssetRecord]
    let projectRoot: URL?
    @Binding var isExpanded: Bool
    let onSelectRecord: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                if groups.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(groups) { group in
                                HighlightGroupView(
                                    group: group,
                                    records: records,
                                    projectRoot: projectRoot,
                                    onSelectRecord: onSelectRecord
                                )
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .background(EditorShellStyle.panelBackground)
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.textTertiary)
                T("HIGHLIGHTS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(EditorShellStyle.textSecondary)
                Spacer()
                Text("\(totalCount)")
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
        .help(isExpanded ? L("Collapse highlights") : L("Expand highlights"))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundStyle(EditorShellStyle.textTertiary)
            T("No highlights yet")
                .font(.system(size: 11))
                .foregroundStyle(EditorShellStyle.textSecondary)
            T("Run ⌘⇧3 to find hook candidates")
                .font(.system(size: 10))
                .foregroundStyle(EditorShellStyle.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Group view

private struct HighlightGroupView: View {
    let group: AICopilotPresentation.HighlightGroup
    let records: [MediaAssetRecord]
    let projectRoot: URL?
    let onSelectRecord: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "film")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.textTertiary)
                Text(group.recordTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(group.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(EditorShellStyle.textTertiary)
            }
            .padding(.horizontal, 6)

            ForEach(group.highlights) { row in
                HighlightRowView(
                    row: row,
                    records: records,
                    projectRoot: projectRoot,
                    onSelectRecord: onSelectRecord
                )
            }
        }
    }
}

// MARK: - Row

private struct HighlightRowView: View {
    let row: AICopilotPresentation.HighlightRow
    let records: [MediaAssetRecord]
    let projectRoot: URL?
    let onSelectRecord: (UUID) -> Void

    var body: some View {
        let content = HStack(alignment: .top, spacing: 8) {
            SegmentFirstFrameThumbnailView(
                sourceVideoID: row.sourceVideoID,
                sourceStartSeconds: row.seconds,
                records: records,
                projectRoot: projectRoot,
                size: CGSize(width: 62, height: 40)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(displayLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorShellStyle.textPrimary)
                    .lineLimit(2)
                Text(timecodeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(EditorShellStyle.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.02))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectRecord(row.sourceVideoID)
        }
        .help(helpText)

        if row.isDraggable, let end = row.endSeconds {
            content.draggable(
                AICopilotPresentation.highlightDragPayload(
                    recordID: row.sourceVideoID,
                    start: row.seconds,
                    end: end
                )
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(displayLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(EditorShellStyle.accentSolid.opacity(0.9))
                .foregroundStyle(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            content
        }
    }

    /// Label shown in the row body. Falls back to a generic
    /// "Highlight" string when the persisted label is empty so the
    /// row never reads as blank.
    private var displayLabel: String {
        let trimmed = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L("Highlight") }
        if trimmed.count > 80 { return String(trimmed.prefix(80)) + "…" }
        return trimmed
    }

    /// Renders `mm:ss–mm:ss` when an end time is known, falls back
    /// to `mm:ss` for legacy markers persisted before PR 8 added the
    /// `endSeconds` field. The compact format keeps rows readable in
    /// the 250pt-wide right column.
    private var timecodeText: String {
        let startText = Self.formatMMSS(row.seconds)
        if let end = row.endSeconds {
            let endText = Self.formatMMSS(end)
            return "\(startText) – \(endText)"
        }
        return startText
    }

    private static func formatMMSS(_ seconds: Double) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let total = Int(safe.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private var helpText: String {
        if row.isDraggable {
            return L("Drag onto the timeline to insert this highlight as a new clip")
        }
        return L("Click to reveal in source")
    }
}
