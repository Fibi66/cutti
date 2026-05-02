import SwiftUI
import CuttiKit
import AppKit

/// Inspectable view over the agent's editing history. Each "turn" is one
/// user prompt and all the `.aiAction` revisions it produced; the user
/// can expand a turn to see its step list, undo the whole plan at once,
/// or export the trace as JSON for debugging.
struct AgentTraceView: View {
    let turns: [(userMessageID: UUID, revisions: [EditorRevision])]
    let messageLookup: (UUID) -> String?
    var onUndoTurn: (UUID) -> Void
    var onExportTurn: (UUID) -> String?

    @State private var expandedTurnID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if turns.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(turns, id: \.userMessageID) { turn in
                            turnRow(turn)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 300)
        .background(EditorShellStyle.panelBackground)
    }

    private var header: some View {
        HStack {
            Image(systemName: "brain.head.profile")
                .foregroundStyle(.secondary)
            T("Agent Trace").font(.headline)
            Spacer()
            Text("\(turns.count) turn\(turns.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            T("No agent edits yet")
                .font(.headline)
            T("Ask the Agent to edit your timeline. Each plan appears here with a step-by-step trace and an undo option.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private func turnRow(_ turn: (userMessageID: UUID, revisions: [EditorRevision])) -> some View {
        let isExpanded = expandedTurnID == turn.userMessageID
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    expandedTurnID = isExpanded ? nil : turn.userMessageID
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(messageLookup(turn.userMessageID) ?? L("User prompt"))
                        .font(.system(size: 13))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(String(format: L("%d step(s)"), turn.revisions.count))
                        if let first = turn.revisions.first {
                            Text("·").foregroundStyle(.secondary)
                            Text(first.timestamp.formatted(date: .omitted, time: .shortened))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        onUndoTurn(turn.userMessageID)
                    } label: {
                        Label { T("Undo Entire Plan") } icon: { Image(systemName: "arrow.uturn.backward") }
                    }
                    Button {
                        if let json = onExportTurn(turn.userMessageID) {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(json, forType: .string)
                        }
                    } label: {
                        Label { T("Copy Trace JSON") } icon: { Image(systemName: "doc.on.clipboard") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(turn.revisions) { rev in
                        HStack(spacing: 6) {
                            Circle().fill(EditorShellStyle.accentSolid).frame(width: 5, height: 5)
                            Text(rev.label)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(rev.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(EditorShellStyle.backgroundSurface)
        .clipShape(RoundedRectangle(cornerRadius: EditorShellStyle.radiusMedium))
    }
}
