import SwiftUI
import CuttiKit

/// Inline editor for a single free-floating text overlay. Lets the
/// user rewrite the text, pick a color, nudge the vertical position
/// and size, and trim the visible time window. Deletions are one tap.
struct TextOverlayEditorSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    let overlayID: UUID

    var body: some View {
        let o = document.textOverlays.first(where: { $0.id == overlayID })
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("编辑文字").font(.headline).foregroundStyle(.white)
                Spacer()
                Button(role: .destructive) {
                    document.deleteTextOverlay(id: overlayID)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.white)
                }
                Button("完成") { dismiss() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.95, green: 0.25, blue: 0.35)))
            }

            TextField(
                "",
                text: Binding(
                    get: { o?.text ?? "" },
                    set: { v in document.updateTextOverlay(id: overlayID) { $0.text = v } }
                ),
                prompt: Text("输入文字…").foregroundStyle(.white.opacity(0.4)),
                axis: .vertical
            )
            .lineLimit(2...4)
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))

            HStack(spacing: 10) {
                Text("颜色").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                ForEach(palette, id: \.0) { name, color in
                    Button {
                        let (r, g, b) = components(color)
                        document.updateTextOverlay(id: overlayID) {
                            $0.colorR = r; $0.colorG = g; $0.colorB = b
                        }
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().stroke(Color.white, lineWidth: isSelected(o, color) ? 2 : 0)
                            )
                    }
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("位置 Y").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    Slider(
                        value: Binding(
                            get: { o?.positionY ?? 0.18 },
                            set: { v in document.updateTextOverlay(id: overlayID) { $0.positionY = v } }
                        ),
                        in: 0.05...0.95,
                        onEditingChanged: { document.interactiveEdit($0) }
                    ).tint(.white)
                }
                HStack {
                    Text("字号").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    Slider(
                        value: Binding(
                            get: { o?.fontSizeRel ?? 0.06 },
                            set: { v in document.updateTextOverlay(id: overlayID) { $0.fontSizeRel = v } }
                        ),
                        in: 0.03...0.16,
                        onEditingChanged: { document.interactiveEdit($0) }
                    ).tint(.white)
                }
                HStack {
                    Text("时长").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    Slider(
                        value: Binding(
                            get: {
                                guard let o else { return 2.0 }
                                return o.endSeconds - o.startSeconds
                            },
                            set: { v in
                                document.updateTextOverlay(id: overlayID) {
                                    $0.endSeconds = $0.startSeconds + max(0.3, v)
                                }
                            }
                        ),
                        in: 0.5...10,
                        onEditingChanged: { document.interactiveEdit($0) }
                    ).tint(.white)
                    Text(String(format: "%.1fs", (o?.endSeconds ?? 0) - (o?.startSeconds ?? 0)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 42, alignment: .trailing)
                }
            }

            fontPickerRow(o)

            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { o?.italic ?? false },
                    set: { v in document.updateTextOverlay(id: overlayID) { $0.italic = v } }
                )) {
                    Text("斜体").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                }
                .toggleStyle(.switch)
                .tint(Color(red: 0.95, green: 0.25, blue: 0.35))

                Toggle(isOn: Binding(
                    get: { o?.strokeEnabled ?? true },
                    set: { v in document.updateTextOverlay(id: overlayID) { $0.strokeEnabled = v } }
                )) {
                    Text("描边").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                }
                .toggleStyle(.switch)
                .tint(Color(red: 0.95, green: 0.25, blue: 0.35))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }

    /// Horizontally-scrollable list of named font swatches that render
    /// the preview text (or "Aa" as fallback) in that face. Tapping
    /// applies the PostScript name to the overlay.
    @ViewBuilder
    private func fontPickerRow(_ o: IOSSessionState.TextOverlay?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("字体").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(fontCatalog, id: \.postScript) { entry in
                        fontChip(entry, selected: (o?.fontName ?? "") == entry.postScript)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fontChip(_ entry: FontEntry, selected: Bool) -> some View {
        Button {
            document.updateTextOverlay(id: overlayID) {
                // Empty PostScript name means "system default" — store
                // nil so JSON stays clean rather than a sentinel string.
                $0.fontName = entry.postScript.isEmpty ? nil : entry.postScript
            }
        } label: {
            Text(L(entry.sample))
                .font(.custom(entry.postScript, size: 20))
                .foregroundStyle(.white)
                .frame(minWidth: 60, minHeight: 40)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    selected
                                        ? Color(red: 0.95, green: 0.25, blue: 0.35)
                                        : Color.clear,
                                    lineWidth: 2
                                )
                        )
                )
        }
    }

    private struct FontEntry {
        let postScript: String
        let sample: String
    }

    /// Curated iOS-bundled font catalogue. PostScript names verified
    /// against UIFont.fontNames — all ship with iOS 15+. Using SF Pro
    /// via empty PostScript name means `.font(.custom("", size:))`
    /// falls back to system, and `UIFont(name: "")` returns nil so
    /// the rasterizer picks system too. Chinese text auto-fills via
    /// Core Text's cascade list when the primary font lacks CJK.
    private var fontCatalog: [FontEntry] {
        [
            FontEntry(postScript: "",                           sample: "系统"),
            FontEntry(postScript: "HelveticaNeue-Bold",         sample: "Aa 汉"),
            FontEntry(postScript: "AvenirNext-Bold",            sample: "Aa"),
            FontEntry(postScript: "AvenirNext-Heavy",           sample: "Aa"),
            FontEntry(postScript: "Futura-Bold",                sample: "Aa"),
            FontEntry(postScript: "Georgia-Bold",               sample: "Aa"),
            FontEntry(postScript: "MarkerFelt-Wide",            sample: "Aa"),
            FontEntry(postScript: "Chalkduster",                sample: "Aa"),
            FontEntry(postScript: "SnellRoundhand-Black",       sample: "Aa"),
            FontEntry(postScript: "Copperplate-Bold",           sample: "AA"),
            FontEntry(postScript: "AmericanTypewriter-Bold",    sample: "Aa"),
            FontEntry(postScript: "Menlo-Bold",                 sample: "Aa")
        ]
    }

    private var palette: [(String, Color)] {
        [
            ("white", .white),
            ("yellow", .yellow),
            ("red", Color(red: 0.95, green: 0.25, blue: 0.35)),
            ("cyan", Color(red: 0.20, green: 0.75, blue: 0.95)),
            ("green", Color(red: 0.35, green: 0.85, blue: 0.45)),
            ("black", .black)
        ]
    }

    private func components(_ color: Color) -> (Double, Double, Double) {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func isSelected(_ o: IOSSessionState.TextOverlay?, _ color: Color) -> Bool {
        guard let o else { return false }
        let (r, g, b) = components(color)
        return abs(o.colorR - r) < 0.01 && abs(o.colorG - g) < 0.01 && abs(o.colorB - b) < 0.01
    }
}
