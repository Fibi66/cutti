import SwiftUI
import CuttiKit

/// Bottom-sheet picker of preset text styles. Filling out the two
/// previously stubbed buttons (`文字模板` / `花字`) on the 文本 tab.
///
/// A template is just a curated bundle of `IOSSessionState.TextOverlay`
/// fields (font, size, colour, stroke). Tapping a template adds a new
/// overlay at the current playhead with those fields applied — the
/// user can still edit / drag / retitle afterwards via the existing
/// TextOverlayEditorSheet.
///
/// Two groups:
///   - `.template` — clean subtitle / title presets (white, yellow,
///     mono italic, two-line subtitle bar, big hero title …).
///   - `.fancy` (花字) — bold colour + heavy stroke combos that read
///     as "decorative" without needing the shadow/gradient renderer
///     features iOS doesn't ship yet.
struct TextTemplatesSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    /// Initial group to highlight when the sheet opens.
    let initialGroup: TextTemplate.Group

    @State private var selectedGroup: TextTemplate.Group

    init(initialGroup: TextTemplate.Group = .template) {
        self.initialGroup = initialGroup
        _selectedGroup = State(initialValue: initialGroup)
    }

    private var visible: [TextTemplate] {
        TextTemplate.all.filter { $0.group == selectedGroup }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $selectedGroup) {
                    Text("文字模板").tag(TextTemplate.Group.template)
                    Text("花字").tag(TextTemplate.Group.fancy)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 14) {
                        ForEach(visible) { tpl in
                            Button { apply(tpl) } label: {
                                TemplateTile(template: tpl)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("文本样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func apply(_ tpl: TextTemplate) {
        let id = document.addTextOverlay(text: tpl.sampleText)
        document.updateTextOverlay(id: id) { o in
            o.colorR = tpl.colorR
            o.colorG = tpl.colorG
            o.colorB = tpl.colorB
            o.fontSizeRel = tpl.fontSizeRel
            o.fontName = tpl.fontName
            o.italic = tpl.italic
            o.strokeEnabled = tpl.strokeEnabled
        }
        dismiss()
    }
}

// MARK: - Template catalogue

struct TextTemplate: Identifiable, Equatable {
    enum Group: Hashable { case template, fancy }
    let id: String
    let name: String
    let group: Group
    let sampleText: String
    let colorR: Double
    let colorG: Double
    let colorB: Double
    let fontSizeRel: Double
    let fontName: String?
    let italic: Bool
    let strokeEnabled: Bool

    static let all: [TextTemplate] = [
        // ---- 文字模板 ----
        TextTemplate(id: "subtitle", name: "经典字幕", group: .template,
                     sampleText: "请输入字幕",
                     colorR: 1, colorG: 1, colorB: 1,
                     fontSizeRel: 0.055, fontName: nil, italic: false, strokeEnabled: true),
        TextTemplate(id: "title-big", name: "大标题", group: .template,
                     sampleText: "标题",
                     colorR: 1, colorG: 1, colorB: 1,
                     fontSizeRel: 0.10, fontName: nil, italic: false, strokeEnabled: true),
        TextTemplate(id: "lower-third", name: "下三分之一",
                     group: .template,
                     sampleText: "嘉宾姓名",
                     colorR: 1, colorG: 1, colorB: 1,
                     fontSizeRel: 0.045, fontName: nil, italic: false, strokeEnabled: true),
        TextTemplate(id: "elegant", name: "优雅斜体", group: .template,
                     sampleText: "Elegant",
                     colorR: 1, colorG: 1, colorB: 1,
                     fontSizeRel: 0.07, fontName: "Georgia-Italic", italic: true, strokeEnabled: false),
        TextTemplate(id: "mono", name: "等宽代码", group: .template,
                     sampleText: "code()",
                     colorR: 0.85, colorG: 1, colorB: 0.7,
                     fontSizeRel: 0.05, fontName: "Menlo-Bold", italic: false, strokeEnabled: false),
        TextTemplate(id: "tag", name: "标签", group: .template,
                     sampleText: "#话题",
                     colorR: 1, colorG: 0.85, colorB: 0,
                     fontSizeRel: 0.045, fontName: nil, italic: false, strokeEnabled: true),

        // ---- 花字 ----
        TextTemplate(id: "fancy-yellow", name: "霓虹黄", group: .fancy,
                     sampleText: "炸裂！",
                     colorR: 1, colorG: 0.85, colorB: 0,
                     fontSizeRel: 0.10, fontName: nil, italic: false, strokeEnabled: true),
        TextTemplate(id: "fancy-red", name: "热血红", group: .fancy,
                     sampleText: "重磅",
                     colorR: 1, colorG: 0.18, colorB: 0.18,
                     fontSizeRel: 0.10, fontName: nil, italic: false, strokeEnabled: true),
        TextTemplate(id: "fancy-cyan", name: "电光青", group: .fancy,
                     sampleText: "GO!",
                     colorR: 0.2, colorG: 0.95, colorB: 1,
                     fontSizeRel: 0.11, fontName: nil, italic: true, strokeEnabled: true),
        TextTemplate(id: "fancy-pink", name: "甜心粉", group: .fancy,
                     sampleText: "好可爱",
                     colorR: 1, colorG: 0.55, colorB: 0.78,
                     fontSizeRel: 0.09, fontName: nil, italic: false, strokeEnabled: true),
        TextTemplate(id: "fancy-mint", name: "薄荷绿", group: .fancy,
                     sampleText: "清新一夏",
                     colorR: 0.4, colorG: 0.92, colorB: 0.7,
                     fontSizeRel: 0.085, fontName: nil, italic: false, strokeEnabled: true),
        TextTemplate(id: "fancy-violet", name: "迷幻紫", group: .fancy,
                     sampleText: "神秘力",
                     colorR: 0.7, colorG: 0.5, colorB: 1,
                     fontSizeRel: 0.10, fontName: nil, italic: true, strokeEnabled: true),
    ]
}

// MARK: - Tile

private struct TemplateTile: View {
    let template: TextTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 84)
                Text(template.sampleText)
                    .font(.system(
                        size: max(14, CGFloat(template.fontSizeRel) * 280),
                        weight: .heavy,
                        design: template.fontName?.contains("Menlo") == true ? .monospaced : .default
                    ))
                    .italic(template.italic)
                    .foregroundStyle(Color(
                        red: template.colorR,
                        green: template.colorG,
                        blue: template.colorB
                    ))
                    .shadow(color: template.strokeEnabled ? .black : .clear, radius: 0, x: 1, y: 1)
                    .shadow(color: template.strokeEnabled ? .black : .clear, radius: 0, x: -1, y: -1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 8)
            }
            Text(template.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// Tiny Identifiable wrapper so we can drive `.sheet(item:)` from a
/// non-Identifiable enum without bouncing through a Bool + computed
/// initialGroup pair.
struct TextTemplateGroupID: Identifiable, Equatable {
    let group: TextTemplate.Group
    var id: TextTemplate.Group { group }
}
