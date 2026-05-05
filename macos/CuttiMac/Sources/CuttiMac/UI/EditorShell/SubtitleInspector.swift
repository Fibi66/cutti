import SwiftUI
import AppKit
import CuttiKit

/// Compact floating inspector that appears on the right edge of the viewer
/// while a subtitle is selected. Intentionally minimal — only the four
/// controls the user cares about day-to-day:
///   1. Preset style
///   2. Font size
///   3. Font color
///   4. Background (color + opacity; opacity 0 = no background)
struct SubtitleInspector: View {
    @Binding var style: SubtitleStyle
    var onClose: () -> Void
    /// Human-readable scope label rendered in the inspector header
    /// (e.g. "Editing this cue" / "Editing all cues"). Optional —
    /// callers that don't pass one fall back to the legacy "Subtitle"
    /// label.
    var scopeLabel: String? = nil
    /// True when the active cue carries a non-empty per-cue style
    /// override. Drives footer button visibility — the "Apply to all
    /// cues" + "Reset to default" actions only make sense when the
    /// scope is per-cue and the cue has actually been customized.
    var hasCueOverride: Bool = false
    /// "Apply this cue's style to every cue project-wide", clearing
    /// every other cue's per-cue override so the project becomes
    /// visually consistent. Nil hides the button.
    var onApplyToAllCues: (() -> Void)? = nil
    /// Drop the active cue's per-cue override so it inherits the
    /// project-wide `subtitleStyle` again. Nil hides the button.
    var onResetToDefault: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            fontSizeRow
            fontColorRow
            backgroundRow

            if hasCueOverride && (onApplyToAllCues != nil || onResetToDefault != nil) {
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
        // Absorb taps in the panel's empty areas so clicks on padding don't
        // fall through to the viewer's deselect catcher.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(scopeLabel ?? L("Subtitle"))
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

    // MARK: - Footer (per-cue scope only)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let onApplyToAllCues {
                Button(action: onApplyToAllCues) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 10))
                        Text(L("Apply to all cues"))
                            .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            if let onResetToDefault {
                Button(action: onResetToDefault) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                        Text(L("Reset to default"))
                            .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rows

    private var fontSizeRow: some View {
        labeledSection(L("Font size")) {
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { style.fontSizePoints },
                    set: { style.fontSizePoints = $0; style.presetID = nil }
                ), in: 16...140, step: 1)
                Text("\(Int(style.fontSizePoints.rounded()))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }
        }
    }

    private var fontColorRow: some View {
        labeledSection(L("Font color")) {
            ColorPicker(
                "",
                selection: Binding(
                    get: { asColor(style.textColor) },
                    set: { style.textColor = asRGBA($0, opaque: true); style.presetID = nil }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(height: 22)
        }
    }

    private var backgroundRow: some View {
        labeledSection(L("Background")) {
            HStack(spacing: 8) {
                // Opacity of 0 === "no background", so a single slider covers
                // both "has background" and "how transparent" in one control.
                ColorPicker(
                    "",
                    selection: Binding(
                        get: {
                            // Show the picker with full opacity so the user is
                            // picking a hue; we drive alpha with the slider.
                            var c = style.backgroundColor
                            c.alpha = 1
                            return asColor(c)
                        },
                        set: { newValue in
                            let rgba = asRGBA(newValue, opaque: true)
                            // Preserve the user's current opacity choice.
                            style.backgroundColor = SubtitleStyle.RGBAColor(
                                red: rgba.red,
                                green: rgba.green,
                                blue: rgba.blue,
                                alpha: style.backgroundColor.alpha
                            )
                            style.presetID = nil
                        }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
                .frame(width: 36, height: 22)

                Slider(value: Binding(
                    get: { style.backgroundColor.alpha },
                    set: { newAlpha in
                        style.backgroundColor = SubtitleStyle.RGBAColor(
                            red: style.backgroundColor.red,
                            green: style.backgroundColor.green,
                            blue: style.backgroundColor.blue,
                            alpha: newAlpha
                        )
                        style.presetID = nil
                    }
                ), in: 0...1)

                Text("\(Int((style.backgroundColor.alpha * 100).rounded()))%")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    // MARK: - Helpers

    private func labeledSection<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            content()
        }
    }

    private func asColor(_ c: SubtitleStyle.RGBAColor) -> Color {
        Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    private func asRGBA(_ color: Color, opaque: Bool) -> SubtitleStyle.RGBAColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return SubtitleStyle.RGBAColor(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: opaque ? 1 : Double(ns.alphaComponent)
        )
    }
}
