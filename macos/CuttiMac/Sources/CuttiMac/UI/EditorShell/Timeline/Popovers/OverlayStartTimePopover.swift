// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import SwiftUI
import CuttiKit

// MARK: - Overlay start-time popover

/// Compact popover shown when the user taps an overlay pill. Lets them
/// type an exact start time in seconds (e.g. `38`) so the segment
/// aligns precisely to a known cue on the primary timeline, bypassing
/// the drag-with-snap workflow. Validates that the value is a finite
/// non-negative number before committing.
struct OverlayStartTimePopover: View {
    let initialSeconds: Double
    let totalDuration: Double
    let onCommit: (Double) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            T("Track start time")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField("38.0", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit(commit)

                T("seconds")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(String(format: L("Primary timeline duration: %.2fs"), totalDuration))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button(action: onCancel) { T("Cancel") }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button(action: commit) { T("Set") }
                    .keyboardShortcut(.defaultAction)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear {
            text = String(format: "%.2f", initialSeconds)
            isFocused = true
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(trimmed), parsed.isFinite else {
            onCancel()
            return
        }
        onCommit(max(0, parsed))
    }
}
