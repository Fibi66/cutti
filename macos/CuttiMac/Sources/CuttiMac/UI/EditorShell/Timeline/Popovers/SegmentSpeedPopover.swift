// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import SwiftUI
import CuttiKit

// MARK: - Segment Speed Popover

struct SegmentSpeedPopover: View {
    let label: String
    let selectionCount: Int
    let currentRate: Double?
    let onApplyRate: (Double) -> Void

    @State private var showPopover = false
    @State private var customRateText = ""

    private let presetRates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private var parsedCustomRate: Double? {
        let trimmed = customRateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        guard value >= TimelineSegment.minimumSpeedRate, value <= TimelineSegment.maximumSpeedRate else { return nil }
        return value
    }

    var body: some View {
        Button {
            if !showPopover {
                customRateText = currentRate.map(AIActionExecutor.formatRate) ?? ""
            }
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            .tooltip(L("Speed"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(label == "Mixed" ? .orange : .secondary)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 14) {
                Text(selectionCount > 1 ? "Selected Segments Speed" : "Segment Speed")
                    .font(.headline)

                Text(selectionCount > 1 ? "Applies to \(selectionCount) selected segments." : "Apply a playback speed to the selected segment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(presetRates, id: \.self) { rate in
                        Button {
                            onApplyRate(rate)
                            customRateText = AIActionExecutor.formatRate(rate)
                            showPopover = false
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(AIActionExecutor.formatRate(rate))x")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                if let currentRate, abs(currentRate - rate) < 0.001 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    T("Custom")
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 8) {
                        TextField("1.33", text: $customRateText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 72)

                        Button {
                            guard let parsedCustomRate else { return }
                            onApplyRate(parsedCustomRate)
                            showPopover = false
                        } label: { T("Apply") }
                        .buttonStyle(.borderedProminent)
                        .disabled(parsedCustomRate == nil)
                    }

                    Text(String(format: L("Allowed range: %@x–%@x"), AIActionExecutor.formatRate(TimelineSegment.minimumSpeedRate), AIActionExecutor.formatRate(TimelineSegment.maximumSpeedRate)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}
