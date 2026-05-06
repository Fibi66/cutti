import SwiftUI
import CuttiKit

/// Right-column section that surfaces persisted `.highlight` markers
/// across all source records — the destination for ⌘⇧3 hook
/// candidates and (PR 10+) any user-saved excerpts. Read-only in PR 9:
/// users can click a row to jump to its source clip, or drag it onto
/// the timeline to insert that span as a new V1 segment. PR 10 adds
/// the inverse direction: drag a V1 segment onto the panel to save it
/// as a manual highlight.
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
    /// Bulk save callback fired when a V1 segment (or selection of
    /// segments) is dropped onto the panel. Caller maps each segment
    /// ID to a source range + writes a `.manual` highlight via
    /// `MediaCoreViewModel.saveTimelineSegmentsToHighlights`.
    let onSaveSegmentsToHighlights: ([UUID]) -> Void
    /// Per-row removal callback fired by the row context menu's
    /// "Remove from Highlights" action. Carries the row identity so
    /// the VM can do a fingerprint recheck before mutating.
    let onRemoveHighlight: (AICopilotPresentation.HighlightRow) -> Void
    /// Per-row "Use as hook" callback fired by the lightning button.
    /// VM assembles a `HookTeaserInputs` from the row and inserts a
    /// Pending opening-hook ProposedBatch — equivalent to the LLM
    /// calling `add_hook_teaser` with this highlight's coords.
    let onUseAsHook: (AICopilotPresentation.HighlightRow) -> Void
    /// Predicate gating the lightning button's enabled state. Returns
    /// false during active agent runs, when scope chips are attached,
    /// or when the source record is missing — see
    /// `MediaCoreViewModel.canUseHighlightAsHook` for the truth table.
    let canUseAsHook: (AICopilotPresentation.HighlightRow) -> Bool

    /// Drives the drop-target visual feedback (border + tint) on the
    /// outer panel container. Bound to `.dropDestination(...)`'s
    /// `isTargeted` callback.
    @State private var isDropTargeted: Bool = false

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
                                    onSelectRecord: onSelectRecord,
                                    onRemoveHighlight: onRemoveHighlight,
                                    onUseAsHook: onUseAsHook,
                                    canUseAsHook: canUseAsHook
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
        // Drop target on the WHOLE panel (not just the body) so the
        // user can save a V1 segment even when the section is
        // collapsed — successful drops auto-expand to confirm receipt.
        // Accepts bare segment UUIDs (single-segment drag) and
        // `multi:UUID|UUID|...` payloads (multi-selection drag);
        // rejects `media:` (whole-clip drop is meaningless here) and
        // `highlight:` (the panel doesn't accept its own rows back).
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(EditorShellStyle.accentSolid, lineWidth: isDropTargeted ? 2 : 0)
                .padding(2)
                .allowsHitTesting(false)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            if payload.hasPrefix("media:") || payload.hasPrefix("highlight:") {
                return false
            }
            let ids: [UUID]
            if payload.hasPrefix("multi:") {
                let body = String(payload.dropFirst("multi:".count))
                ids = body
                    .split(separator: "|", omittingEmptySubsequences: true)
                    .compactMap { UUID(uuidString: String($0)) }
            } else if let id = UUID(uuidString: payload) {
                ids = [id]
            } else {
                return false
            }
            guard !ids.isEmpty else { return false }
            onSaveSegmentsToHighlights(ids)
            if !isExpanded {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded = true
                }
            }
            return true
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
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
    let onRemoveHighlight: (AICopilotPresentation.HighlightRow) -> Void
    let onUseAsHook: (AICopilotPresentation.HighlightRow) -> Void
    let canUseAsHook: (AICopilotPresentation.HighlightRow) -> Bool

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
                    onSelectRecord: onSelectRecord,
                    onRemoveHighlight: onRemoveHighlight,
                    onUseAsHook: onUseAsHook,
                    canUseAsHook: canUseAsHook
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
    let onRemoveHighlight: (AICopilotPresentation.HighlightRow) -> Void
    let onUseAsHook: (AICopilotPresentation.HighlightRow) -> Void
    let canUseAsHook: (AICopilotPresentation.HighlightRow) -> Bool

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
                HStack(spacing: 4) {
                    OriginBadge(origin: row.origin)
                    Text(timecodeText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(EditorShellStyle.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ⚡ "Use as hook" button. Hidden for legacy markers
            // without `endSeconds` (no span = nothing to insert);
            // disabled for transient blockers (active agent run /
            // scope chips / missing record), surfaced via `.help`.
            if row.endSeconds != nil {
                useAsHookButton
            }
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
        .contextMenu {
            Button { onSelectRecord(row.sourceVideoID) } label: { T("Reveal in source") }
            if row.endSeconds != nil {
                Button(L("Use as opening hook")) {
                    onUseAsHook(row)
                }
                .disabled(!canUseAsHook(row))
            }
            Divider()
            Button(L("Remove from Highlights"), role: .destructive) {
                onRemoveHighlight(row)
            }
        }

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

    /// Compact lightning button rendered on the right of each row.
    /// Tap creates a Pending opening-hook ProposedBatch from this
    /// exact span — same end-state as the LLM calling
    /// `add_hook_teaser`. The wrapping `Button` style strips macOS's
    /// default chrome so the icon sits flush against the row.
    private var useAsHookButton: some View {
        let enabled = canUseAsHook(row)
        return Button {
            onUseAsHook(row)
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled
                                 ? EditorShellStyle.accentSolid
                                 : EditorShellStyle.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(enabled
                              ? EditorShellStyle.accentSolid.opacity(0.12)
                              : Color.white.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled
              ? L("Use as opening hook — insert this highlight at the start of the timeline")
              : L("Use-as-hook is unavailable right now"))
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

// MARK: - Origin badge

/// Compact `[AI]` / `[Manual]` chip rendered next to the timecode on
/// each row so the user can tell at a glance which highlights are
/// auto-generated (and thus replaceable on the next ⌘⇧3 run) vs.
/// hand-curated (permanent until the user removes them).
private struct OriginBadge: View {
    let origin: AICopilotMarker.Origin

    var body: some View {
        let isManual = origin == .manual
        let label: String = isManual ? L("Manual") : L("AI")
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .default))
            .foregroundStyle(isManual ? Color.black : EditorShellStyle.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isManual
                          ? EditorShellStyle.accentSolid.opacity(0.85)
                          : Color.white.opacity(0.08))
            )
    }
}
