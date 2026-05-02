import SwiftUI
import AppKit
import CuttiKit

/// Sheet UI for rich-text subtitle emphasis: show the cue, let the user
/// pick tokens (tap to toggle), and apply style overrides (size / color
/// / weight / underline) to the selected range. Reached via the
/// S-lane cue context menu ("Emphasize words…") and the chat agent's
/// `emphasize_words` tool (planned, Phase 3).
///
/// Lives as a sheet rather than an always-on inspector because:
///   1. emphasis is a rare, intentional action — users don't want
///      permanent chrome stealing horizontal space,
///   2. the preview at the top can be substantially larger than a
///      sidebar allows, which matters for judging contrast + sizing,
///   3. keyboard dismissal via Esc / Cancel works the same as every
///      other modal in the app.
///
/// Selection model: indices into the tokenized token list. We track
/// indices rather than raw ranges so redundant clicks on the same
/// token toggle correctly. On Apply we translate indices → UTF-16
/// ranges → `MediaCoreViewModel.applyEmphasisToSubtitle`.
struct SubtitleEmphasisSheet: View {

    let cueID: UUID
    let text: String
    let existingRuns: [SubtitleRun]?
    let baseStyle: SubtitleStyle
    /// Invoked with the selected UTF-16 ranges + merged patch. Host wires
    /// this to `MediaCoreViewModel.applyEmphasisToSubtitle`.
    var onApply: (_ ranges: [NSRange], _ patch: SubtitleRunStyle) -> Void
    /// Clears all runs on the cue (maps to `clearEmphasisOnSubtitle`).
    var onClearAll: () -> Void
    var onCancel: () -> Void

    @State private var tokens: [SubtitleWordTokenizer.Token] = []
    @State private var selectedIndices: Set<Int> = []

    // Style controls — nil means "don't apply / inherit". Only non-nil
    // values are packed into the patch, so a user who only changes
    // color doesn't clobber weight.
    @State private var pickedWeight: SubtitleRunStyle.Weight? = nil
    @State private var pickedSize: Double? = nil
    @State private var pickedColor: Color? = nil
    @State private var pickedUnderline: Bool = false

    private let sizeOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Emphasize words"))
                .font(.title3.bold())

            Text(L("Tap words to select them, then pick a style. Changes apply only to the selected range."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            preview

            tokenGrid

            Divider()

            styleControls

            Divider()

            footerButtons
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640,
               minHeight: 480, idealHeight: 540)
        .onAppear {
            tokens = SubtitleWordTokenizer.tokenize(text)
            seedPickersFromExistingRuns()
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Preview"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(previewAttributedString())
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color(nsColor: baseTextNSColor))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.8)))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewAttributedString() -> AttributedString {
        // Visualize the pending patch on top of existing runs so the
        // user sees exactly what Apply will do. We apply the patch to
        // an ephemeral run array then feed the same helper the
        // SubtitleOverlay uses at preview time.
        let seedRuns = existingRuns ?? [SubtitleRun(text: text, style: .empty)]
        var draft = seedRuns
        let patch = buildPatch()
        if !patch.isEmpty && !selectedIndices.isEmpty {
            let ranges = selectedRangesMerged()
            for r in ranges {
                draft = SubtitleRunEditor.applyStyle(
                    to: draft,
                    range: r.location..<(r.location + r.length),
                    patch: patch
                )
            }
            draft = SubtitleRunEditor.normalize(draft)
        }
        return makeSubtitleAttributedString(
            text: text,
            runs: draft,
            baseFontSize: 24,
            baseColor: baseTextNSColor,
            baseWeight: .bold
        )
    }

    // MARK: - Tokens

    private var tokenGrid: some View {
        ScrollView {
            // Flow layout: wrap tokens on width. Swift 5 lacks a nice
            // flow layout, so fall back to LazyVGrid with adaptive
            // columns — works for short cues (the majority case) and
            // degrades acceptably for long ones.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                    tokenButton(index: index, token: token)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 120)
    }

    private func tokenButton(index: Int, token: SubtitleWordTokenizer.Token) -> some View {
        let isSelected = selectedIndices.contains(index)
        return Button {
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
        } label: {
            Text(token.text)
                .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? Color.accentColor
                          : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Style controls

    private var styleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(L("Weight"))
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: Binding(
                    get: { pickedWeight ?? .regular },
                    set: { pickedWeight = $0 }
                )) {
                    ForEach(SubtitleRunStyle.Weight.allCases, id: \.self) { w in
                        Text(L(weightLabel(w))).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(pickedWeight == nil)
                Toggle("", isOn: Binding(
                    get: { pickedWeight != nil },
                    set: { on in pickedWeight = on ? (pickedWeight ?? .bold) : nil }
                ))
                .labelsHidden()
                .help(L("Apply weight"))
            }

            HStack(spacing: 12) {
                Text(L("Size"))
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: Binding(
                    get: { pickedSize ?? 1.0 },
                    set: { pickedSize = $0 }
                )) {
                    ForEach(sizeOptions, id: \.self) { m in
                        Text(sizeLabel(m)).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(pickedSize == nil)
                Toggle("", isOn: Binding(
                    get: { pickedSize != nil },
                    set: { on in pickedSize = on ? (pickedSize ?? 1.25) : nil }
                ))
                .labelsHidden()
                .help(L("Apply size"))
            }

            HStack(spacing: 12) {
                Text(L("Color"))
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
                ColorPicker("", selection: Binding(
                    get: { pickedColor ?? .yellow },
                    set: { pickedColor = $0 }
                ), supportsOpacity: false)
                .labelsHidden()
                .disabled(pickedColor == nil)
                Toggle("", isOn: Binding(
                    get: { pickedColor != nil },
                    set: { on in pickedColor = on ? (pickedColor ?? .yellow) : nil }
                ))
                .labelsHidden()
                .help(L("Apply color"))
                Spacer()
            }

            Toggle(L("Underline"), isOn: $pickedUnderline)
                .toggleStyle(.checkbox)
        }
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            Button(L("Clear all emphasis"), role: .destructive) {
                onClearAll()
            }
            .disabled(existingRuns == nil)

            Spacer()

            Button(L("Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)

            Button(L("Apply")) {
                let patch = buildPatch()
                guard !patch.isEmpty, !selectedIndices.isEmpty else {
                    onCancel()
                    return
                }
                onApply(selectedRangesMerged(), patch)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIndices.isEmpty || buildPatch().isEmpty)
        }
    }

    // MARK: - Helpers

    private var baseTextNSColor: NSColor {
        NSColor(
            srgbRed: baseStyle.textColor.red,
            green: baseStyle.textColor.green,
            blue: baseStyle.textColor.blue,
            alpha: baseStyle.textColor.alpha
        )
    }

    private func selectedRangesMerged() -> [NSRange] {
        let ranges = selectedIndices.sorted().map { tokens[$0].utf16Range }
        return SubtitleWordTokenizer.mergeRanges(ranges)
    }

    private func buildPatch() -> SubtitleRunStyle {
        SubtitleRunStyle(
            fontName: nil,
            sizeMultiplier: pickedSize,
            weight: pickedWeight,
            textColor: pickedColor.flatMap(rgba(from:)),
            strokeColor: nil,
            strokeWidthFractionOverride: nil,
            highlightBackground: nil,
            underline: pickedUnderline ? true : nil
        )
    }

    private func rgba(from color: Color) -> SubtitleStyle.RGBAColor? {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let c = ns else { return nil }
        return SubtitleStyle.RGBAColor(
            red: Double(c.redComponent),
            green: Double(c.greenComponent),
            blue: Double(c.blueComponent),
            alpha: Double(c.alphaComponent)
        )
    }

    private func weightLabel(_ w: SubtitleRunStyle.Weight) -> String {
        switch w {
        case .regular:  return "Reg"
        case .medium:   return "Med"
        case .semibold: return "Semi"
        case .bold:     return "Bold"
        case .heavy:    return "Heavy"
        case .black:    return "Black"
        }
    }

    private func sizeLabel(_ m: Double) -> String {
        String(format: "%.2gx", m)
    }

    /// Pre-populate the style pickers from any overrides that already
    /// exist on the selected tokens' common range. For v1 we keep this
    /// simple: if the cue has runs at all, we don't pre-select — the
    /// user starts with a clean patch and additively layers changes.
    /// A smarter "show the style of the majority selected range" pass
    /// lands with the inspector panel work.
    private func seedPickersFromExistingRuns() {
        pickedWeight = nil
        pickedSize = nil
        pickedColor = nil
        pickedUnderline = false
    }
}
