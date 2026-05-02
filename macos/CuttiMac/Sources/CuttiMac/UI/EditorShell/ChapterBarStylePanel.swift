import SwiftUI
import CuttiKit

/// Modal sheet for adjusting the chapter progress bar's visual style:
/// background color + opacity, font color + size, and anchor position.
/// Changes are held locally until the user hits **Apply**, at which
/// point the parent view persists + pushes a revision via the
/// `onApply` callback.
struct ChapterBarStylePanel: View {
    let initialStyle: ChapterBarStyle
    let onApply: (ChapterBarStyle) -> Void
    let onCancel: () -> Void

    @State private var anchor: ChapterBarStyle.VerticalAnchor
    @State private var backgroundColor: Color
    @State private var backgroundOpacity: Double
    @State private var fontColor: Color
    @State private var fontSize: Double

    init(
        initialStyle: ChapterBarStyle,
        onApply: @escaping (ChapterBarStyle) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialStyle = initialStyle
        self.onApply = onApply
        self.onCancel = onCancel

        _anchor = State(initialValue: initialStyle.anchor)
        _backgroundColor = State(initialValue: Color(
            red: initialStyle.backgroundColor.red,
            green: initialStyle.backgroundColor.green,
            blue: initialStyle.backgroundColor.blue
        ))
        _backgroundOpacity = State(initialValue: initialStyle.backgroundOpacity)
        _fontColor = State(initialValue: Color(
            red: initialStyle.fontColor.red,
            green: initialStyle.fontColor.green,
            blue: initialStyle.fontColor.blue
        ))
        _fontSize = State(initialValue: initialStyle.fontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            T("Chapter bar style")
                .font(.title3.weight(.semibold))

            // Live preview strip
            previewStrip
                .frame(height: 70)
                .background(
                    LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(6)

            Form {
                Picker(selection: $anchor) {
                    T("Bottom").tag(ChapterBarStyle.VerticalAnchor.bottom)
                    T("Top").tag(ChapterBarStyle.VerticalAnchor.top)
                } label: { T("Position") }
                .pickerStyle(.segmented)

                ColorPicker(L("Background"), selection: $backgroundColor, supportsOpacity: false)

                HStack {
                    T("Background opacity")
                    Slider(value: $backgroundOpacity, in: 0...1)
                    Text(String(format: "%.0f%%", backgroundOpacity * 100))
                        .font(.caption.monospaced())
                        .frame(width: 46, alignment: .trailing)
                }

                ColorPicker(L("Font color"), selection: $fontColor, supportsOpacity: false)

                HStack {
                    T("Font size")
                    Slider(value: $fontSize, in: 16...60, step: 1)
                    Text(String(format: "%.0f", fontSize))
                        .font(.caption.monospaced())
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button {
                    let d = ChapterBarStyle.default
                    anchor = d.anchor
                    backgroundColor = Color(red: d.backgroundColor.red, green: d.backgroundColor.green, blue: d.backgroundColor.blue)
                    backgroundOpacity = d.backgroundOpacity
                    fontColor = Color(red: d.fontColor.red, green: d.fontColor.green, blue: d.fontColor.blue)
                    fontSize = d.fontSize
                } label: { T("Reset") }
                Spacer()
                Button(action: onCancel) { T("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    onApply(currentStyle())
                } label: { T("Apply") }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var previewStrip: some View {
        // Miniature mock of the chapter bar with current style.
        GeometryReader { geo in
            let scale = geo.size.height / 120.0
            let barH = max(3, 6 * scale * 2) // 2x bigger for legibility
            let titleSize = max(10, fontSize * scale * 1.3)
            let w = geo.size.width
            ZStack {
                // BG panel
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor.opacity(backgroundOpacity))
                    .padding(6)
                VStack(spacing: 4) {
                    if anchor == .top {
                        dividerBar(width: w - 40, barH: barH)
                        T("Chapter title")
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundStyle(fontColor)
                    } else {
                        T("Chapter title")
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundStyle(fontColor)
                        dividerBar(width: w - 40, barH: barH)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dividerBar(width: CGFloat, barH: CGFloat) -> some View {
        HStack(spacing: 2) {
            Capsule().fill(Color.white.opacity(0.85)).frame(width: width * 0.4, height: barH)
            Capsule().fill(Color(red: 1, green: 0.3, blue: 0.3)).frame(width: width * 0.2, height: barH)
            Capsule().fill(Color.white.opacity(0.30)).frame(width: width * 0.4, height: barH)
        }
    }

    private func currentStyle() -> ChapterBarStyle {
        ChapterBarStyle(
            anchor: anchor,
            backgroundColor: color(from: backgroundColor),
            backgroundOpacity: backgroundOpacity,
            fontColor: color(from: fontColor),
            fontSize: fontSize
        )
    }

    /// Extract sRGB components from a SwiftUI `Color` via NSColor. This
    /// is best-effort; fallback values preserve the user's intent for
    /// unusual color spaces (system/dynamic colors rarely appear in
    /// ColorPicker output).
    private func color(from color: Color) -> RGBAColor {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let ns else {
            return RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        return RGBAColor(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }
}
