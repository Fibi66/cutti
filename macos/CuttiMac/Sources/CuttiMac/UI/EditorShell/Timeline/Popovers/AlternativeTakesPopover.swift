// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import SwiftUI
import CuttiKit

// MARK: - Alternative Takes Badge

/// Small circular badge rendered on top of a primary timeline segment
/// when the AI first-cut identified equivalent alternate takes for that
/// segment. Clicking it opens a popover that lets the user swap in any
/// of the alternates (the current primary take becomes an alternate in
/// return).
struct AlternativeTakesBadge: View {
    let segment: TimelineSegment
    let isOpen: Bool
    let onOpen: () -> Void
    let onDismiss: () -> Void
    let onSelect: (UUID) -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Circle()
                    .fill(EditorShellStyle.obA1.opacity(0.9))
                    .frame(width: 18, height: 18)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                if segment.alternatives.count > 1 {
                    Text("\(segment.alternatives.count + 1)")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Color.black.opacity(0.7))
                        .clipShape(Capsule())
                        .offset(x: 11, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .help(L("Multiple takes for this phrase — click to switch"))
        .popover(
            isPresented: Binding(
                get: { isOpen },
                set: { if !$0 { onDismiss() } }
            ),
            arrowEdge: .top
        ) {
            AlternativeTakesPopover(
                segment: segment,
                onSelect: onSelect
            )
        }
    }
}

struct AlternativeTakesPopover: View {
    let segment: TimelineSegment
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            T("Alternative Takes")
                .font(.headline)
            Text(String(format: L("The AI found %d takes for this phrase. The active take is highlighted — tap any other to swap it in."), segment.alternatives.count + 1))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(EditorShellStyle.obGreen)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(segment.text.isEmpty ? L("(no text)") : segment.text)
                            .font(.system(size: 12, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(String(format: "%.1fs–%.1fs · %.1fs",
                                    segment.range.startSeconds,
                                    segment.range.endSeconds,
                                    segment.sourceDurationSeconds))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(EditorShellStyle.obGreen.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                ForEach(segment.alternatives) { take in
                    Button {
                        onSelect(take.id)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(EditorShellStyle.obA1)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(take.text.isEmpty ? L("(no text)") : take.text)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                HStack(spacing: 6) {
                                    Text(String(format: "%.1fs–%.1fs · %.1fs",
                                                take.startSeconds,
                                                take.endSeconds,
                                                take.durationSeconds))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let reason = take.reason, !reason.isEmpty {
                                        Text(reason)
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(EditorShellStyle.obA1.opacity(0.22))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(EditorShellStyle.backgroundHover.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}
