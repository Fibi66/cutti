import SwiftUI
import AppKit
import CuttiKit

/// Floating inspector panel for the selected overlay segment's
/// `FreeTransform`. Mirrors the SubtitleInspector / OverlayInspector
/// pattern — a compact card on the right edge of the viewer with
/// numeric controls for the five fields an After-Effects / Premiere
/// user expects on a 2D layer:
///
///   • Position X / Y (canvas-normalized, shown as a percentage)
///   • Scale (multiplier; 1.0 = aspect-fit to canvas)
///   • Rotation (degrees, -180…180)
///   • Opacity (0…100 %)
///
/// There are also two one-click conveniences:
///   • **Reset** — restore `FreeTransform.identity` on the segment.
///   • **Fit / Fill** — snap scale to 1.0 (fit) or to the value that
///     covers the canvas along the long axis (fill). The inspector
///     needs the source and canvas aspect ratios to compute "fill",
///     so those come in alongside the transform.
///
/// Edits stream to the host with `commit: false` while the user
/// drags a slider, then once with `commit: true` on release — same
/// convention as FreeTransformHandle so one undo step captures the
/// whole interaction regardless of whether the user dragged in the
/// viewer or moved a slider here.
struct FreeTransformInspector: View {
    let segmentID: UUID
    let transform: FreeTransform
    /// Source aspect ratio (w/h) — needed by the Fill preset.
    let sourceAspect: CGFloat
    /// Canvas aspect ratio (w/h) — needed by the Fill preset.
    let canvasAspect: CGFloat?
    /// Streamed updates: `commit: false` mid-drag, `commit: true` on
    /// release. Matches FreeTransformHandle so undo is coherent.
    let onUpdate: (UUID, FreeTransform, Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            positionRow
            scaleRow
            rotationRow
            opacityRow

            Divider().opacity(0.4)
            presetRow
        }
        .padding(14)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            T("Transform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Close"))
        }
    }

    // MARK: - Rows

    private var positionRow: some View {
        labeledSection(L("Position")) {
            HStack(spacing: 8) {
                axisField(
                    label: "X",
                    value: transform.positionX,
                    format: .percent,
                    range: -2.0...2.0,
                    step: 0.01
                ) { newVal, commit in
                    var next = transform
                    next.positionX = newVal
                    onUpdate(segmentID, next, commit)
                }
                axisField(
                    label: "Y",
                    value: transform.positionY,
                    format: .percent,
                    range: -2.0...2.0,
                    step: 0.01
                ) { newVal, commit in
                    var next = transform
                    next.positionY = newVal
                    onUpdate(segmentID, next, commit)
                }
            }
        }
    }

    private var scaleRow: some View {
        labeledSection(L("Scale")) {
            numericSliderRow(
                value: transform.scale,
                range: 0.05...4.0,
                step: 0.01,
                format: .scale
            ) { newVal, commit in
                var next = transform
                next.scale = max(0.01, newVal)
                onUpdate(segmentID, next, commit)
            }
        }
    }

    private var rotationRow: some View {
        labeledSection(L("Rotation")) {
            numericSliderRow(
                value: transform.rotationDegrees,
                range: -180...180,
                step: 1,
                format: .degrees
            ) { newVal, commit in
                var next = transform
                next.rotationDegrees = newVal
                onUpdate(segmentID, next, commit)
            }
        }
    }

    private var opacityRow: some View {
        labeledSection(L("Opacity")) {
            numericSliderRow(
                value: transform.opacity,
                range: 0...1,
                step: 0.01,
                format: .percent
            ) { newVal, commit in
                var next = transform
                next.opacity = min(1.0, max(0.0, newVal))
                onUpdate(segmentID, next, commit)
            }
        }
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            Button {
                var next = transform
                next.scale = 1.0
                onUpdate(segmentID, next, true)
            } label: { T("Fit") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L("Scale to fit the canvas"))

            Button {
                onUpdate(segmentID, withFillScale(on: transform), true)
            } label: { T("Fill") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L("Scale to cover the canvas"))

            Spacer()

            Button {
                onUpdate(segmentID, .identity, true)
            } label: { T("Reset") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L("Reset position / scale / rotation / opacity"))
        }
    }

    // MARK: - Reusable controls

    private enum NumericFormat {
        case percent      // 0.5 → "50%"
        case scale        // 1.0 → "1.00×"
        case degrees      // 45 → "45°"
    }

    private func labeledSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Slider + numeric field for a single scalar value. On slider
    /// drag: streams updates with `commit: false` and fires one final
    /// `commit: true` when the drag ends. Typing into the field
    /// commits immediately.
    private func numericSliderRow(
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        format: NumericFormat,
        onChange: @escaping (Double, Bool) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { value },
                    set: { onChange($0, false) }
                ),
                in: range,
                step: step,
                onEditingChanged: { editing in
                    // When editing ends (user released the slider),
                    // fire one committed update so undo captures a
                    // single step.
                    if !editing { onChange(value, true) }
                }
            )
            numericField(value: value, format: format) { onChange($0, true) }
        }
    }

    /// Two-column position field (X and Y share this, with their own
    /// labels). No slider — users scrub by dragging in the viewer;
    /// the field is for fine-grained typed input.
    private func axisField(
        label: String,
        value: Double,
        format: NumericFormat,
        range: ClosedRange<Double>,
        step: Double,
        onChange: @escaping (Double, Bool) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .leading)
            numericField(value: value, format: format) { onChange($0, true) }
            Stepper("", value: Binding(
                get: { value },
                set: { onChange(clamp($0, to: range), true) }
            ), in: range, step: step)
            .labelsHidden()
            .controlSize(.mini)
        }
    }

    private func numericField(
        value: Double,
        format: NumericFormat,
        onCommit: @escaping (Double) -> Void
    ) -> some View {
        let textBinding = Binding<String>(
            get: { formatValue(value, as: format) },
            set: { newString in
                if let parsed = parseValue(newString, as: format) {
                    onCommit(parsed)
                }
            }
        )
        return TextField("", text: textBinding)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 60)
            .font(.system(size: 11, design: .monospaced))
    }

    private func formatValue(_ value: Double, as format: NumericFormat) -> String {
        switch format {
        case .percent: return "\(Int((value * 100).rounded()))%"
        case .scale:   return String(format: "%.2f×", value)
        case .degrees: return "\(Int(value.rounded()))°"
        }
    }

    private func parseValue(_ text: String, as format: NumericFormat) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "×", with: "")
            .replacingOccurrences(of: "°", with: "")
        guard let raw = Double(trimmed) else { return nil }
        switch format {
        case .percent: return raw / 100.0
        case .scale, .degrees: return raw
        }
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// Compute the scale that makes the source aspect-fill the
    /// canvas. If canvasAspect is unknown, fall back to 1.0 (fit).
    private func withFillScale(on base: FreeTransform) -> FreeTransform {
        var next = base
        guard let canvasAspect, canvasAspect > 0 else {
            next.scale = 1.0
            return next
        }
        // Fit scale is 1.0 (layer fits canvas along shorter side).
        // Fill scale is the ratio of longer-side overshoot:
        //   - if source is wider than canvas: fill = canvas / source aspect? No.
        // The aspect-fit base size is min-axis-matching. To fill, we
        // need max-axis-matching. Ratio between them is |canvasAspect
        // / sourceAspect| when source < canvas, and the inverse when
        // source > canvas.
        let ratio = sourceAspect > canvasAspect
            ? sourceAspect / canvasAspect
            : canvasAspect / sourceAspect
        next.scale = ratio
        return next
    }
}
