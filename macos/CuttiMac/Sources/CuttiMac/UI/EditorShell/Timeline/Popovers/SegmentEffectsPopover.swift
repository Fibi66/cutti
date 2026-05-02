// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import SwiftUI
import CuttiKit

// MARK: - Segment Effects Popover

struct SegmentEffectsPopover: View {
    let segment: TimelineSegment
    let index: Int
    let onSetColor: (Int, Double?, Double?, Double?) -> Void
    let onSetAudioFade: (Int, Double?, Double?) -> Void
    let onResetEffects: (Int) -> Void

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundColor(segment.effects.isDefault ? .secondary : .blue)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .tooltip(L("Effects"))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                T("Segment Effects")
                    .font(.headline)

                // Color controls
                Group {
                    T("Color").font(.subheadline.weight(.medium))

                    effectSlider(
                        label: L("Brightness"),
                        value: segment.effects.brightness,
                        range: -1...1,
                        defaultValue: 0
                    ) { onSetColor(index, $0, nil, nil) }

                    effectSlider(
                        label: L("Contrast"),
                        value: segment.effects.contrast,
                        range: 0...2,
                        defaultValue: 1
                    ) { onSetColor(index, nil, $0, nil) }

                    effectSlider(
                        label: L("Saturation"),
                        value: segment.effects.saturation,
                        range: 0...2,
                        defaultValue: 1
                    ) { onSetColor(index, nil, nil, $0) }
                }

                Divider()

                // Audio fade controls
                Group {
                    T("Audio Fade").font(.subheadline.weight(.medium))

                    effectSlider(
                        label: L("Fade In"),
                        value: segment.effects.audioFadeInDuration,
                        range: 0...5,
                        defaultValue: 0,
                        unit: "s"
                    ) { onSetAudioFade(index, $0, nil) }

                    effectSlider(
                        label: L("Fade Out"),
                        value: segment.effects.audioFadeOutDuration,
                        range: 0...5,
                        defaultValue: 0,
                        unit: "s"
                    ) { onSetAudioFade(index, nil, $0) }
                }

                Divider()

                Button {
                    onResetEffects(index)
                } label: { T("Reset All Effects") }
                .disabled(segment.effects.isDefault)
            }
            .padding(16)
            .frame(width: 280)
        }
    }

    private func effectSlider(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        defaultValue: Double,
        unit: String = "",
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { value },
                    set: { onChange($0) }
                ),
                in: range
            )

            let displayValue = unit.isEmpty
                ? String(format: "%.2f", value)
                : String(format: "%.1f%@", value, unit)
            Text(displayValue)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            // Reset to default
            Button {
                onChange(defaultValue)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 10))
                    .foregroundColor(value != defaultValue ? .blue : .gray)
            }
            .buttonStyle(.plain)
            .disabled(value == defaultValue)
        }
    }
}
