import SwiftUI
import AppKit
import CuttiKit

/// Floating inspector panel for an AI-generated Remotion overlay.
///
/// Architecture: **params are the source of truth**, the `.mov` on the
/// overlay track is a content-addressable render of those params.
/// Editing a field here calls `scheduleOverlayPropsPatch` on the view
/// model, which debounces 500ms and then triggers a cache lookup +
/// re-render + mediaID swap on the segment.
///
/// The form is **schema-driven**: each template in the Remotion catalog
/// declares its editable fields in ``overlayTemplateSchemas`` below.
/// The view renders them generically. To expose a new prop for editing,
/// add a field entry — no new SwiftUI code required.
///
/// Shallow-merge caveat: ``MediaCoreViewModel.updateOverlayProps`` does
/// a top-level dict merge, so array / nested-object fields (TripleTap
/// icons, SequenceSteps items, Comparison left/right) **always** send
/// the complete new value; per-row editors read from local state and
/// emit the whole collection on every keystroke.
struct OverlayInspector: View {
    let spec: OverlayRenderSpec
    let isRendering: Bool
    var onPatch: ([String: Any]) -> Void
    var onClose: () -> Void

    /// Decoded props (top-level only). Updated from `spec` on appear
    /// and whenever `cacheKey` changes (e.g. the agent edited the same
    /// overlay from another surface).
    @State private var props: [String: Any] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().opacity(0.5)

            if let schema = overlayTemplateSchemas[spec.templateID] {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(schema.fields.enumerated()), id: \.offset) { _, field in
                            OverlayFieldRow(
                                field: field,
                                props: props,
                                onPatch: patchField
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 440)
            } else {
                Text(String(format: L("No editable props for %@ yet."), spec.templateID))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if isRendering {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                    T("Re-rendering…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {}
        .onAppear { syncPropsFromSpec() }
        .onChange(of: spec.cacheKey) { _, _ in syncPropsFromSpec() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EditorShellStyle.accentSolid)
            Text(overlayTemplateSchemas[spec.templateID]?.displayName ?? spec.templateID)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
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

    private func syncPropsFromSpec() {
        guard
            let data = spec.propsJSON.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            props = [:]
            return
        }
        props = obj
    }

    /// Central patch sink. Updates local `props` so downstream rows see
    /// the new value immediately (important for array editors that
    /// read-modify-write), then forwards to the debounced view-model
    /// hook.
    private func patchField(_ key: String, _ value: Any?) {
        if let value {
            props[key] = value
            onPatch([key: value])
        } else {
            // NSNull is how we tell mergeJSON "clear this key"; but the
            // current merge doesn't honor deletions, so we just emit an
            // empty string for string fields. Callers that want to
            // actually remove a key should send `""` or the default.
            props.removeValue(forKey: key)
            onPatch([key: NSNull()])
        }
    }
}

// MARK: - Schema model

/// Declarative description of a single editable prop. Rendered
/// generically by ``OverlayFieldRow``. Keep this list small and simple —
/// the point is to stay declarative so adding a field is one line.
enum OverlayFieldSpec {
    /// Single-line string (TextField).
    case text(key: String, label: String, placeholder: String = "", maxLength: Int? = nil)
    /// Multi-line string (TextEditor-ish TextField with `axis: .vertical`).
    case multiline(key: String, label: String, placeholder: String = "", maxLength: Int? = nil)
    /// Enum picker (segmented when ≤3 options, otherwise Menu).
    case picker(key: String, label: String, options: [(id: String, label: String)], defaultID: String)
    /// #RRGGBB color via NSColorPanel-backed SwiftUI ColorPicker.
    case color(key: String, label: String, defaultHex: String)
    /// Integer stepper + slider.
    case number(key: String, label: String, min: Double, max: Double, defaultValue: Double, step: Double = 1)
    /// Array of plain strings. Add/remove rows, each is a single-line TextField.
    case stringArray(key: String, label: String, minCount: Int, maxCount: Int, itemMaxLength: Int = 60, itemPlaceholder: String = "Item")
    /// Array of TripleTap-style icon items (emoji / label / color).
    case iconArray(key: String, label: String, minCount: Int, maxCount: Int)
    /// Array of SequenceSteps items (label / optional icon / optional caption / optional atSeconds).
    case sequenceItems(key: String, label: String, minCount: Int, maxCount: Int)
    /// Nested object — renders a sub-form for the named child key.
    /// Emits the whole child object on every edit because mergeJSON is shallow.
    case nested(key: String, label: String, fields: [OverlayFieldSpec])
}

struct OverlayTemplateSchema {
    let displayName: String
    let fields: [OverlayFieldSpec]
}

// MARK: - Generic field row

private struct OverlayFieldRow: View {
    let field: OverlayFieldSpec
    let props: [String: Any]
    var onPatch: (String, Any?) -> Void

    var body: some View {
        switch field {
        case let .text(key, label, placeholder, maxLen):
            labeled(label) {
                TextField(
                    placeholder,
                    text: Binding(
                        get: { props[key] as? String ?? "" },
                        set: { new in
                            let trimmed = maxLen.map { String(new.prefix($0)) } ?? new
                            onPatch(key, trimmed)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            }

        case let .multiline(key, label, placeholder, maxLen):
            labeled(label) {
                TextField(
                    placeholder,
                    text: Binding(
                        get: { props[key] as? String ?? "" },
                        set: { new in
                            let trimmed = maxLen.map { String(new.prefix($0)) } ?? new
                            onPatch(key, trimmed)
                        }
                    ),
                    axis: .vertical
                )
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            }

        case let .picker(key, label, options, defaultID):
            labeled(label) {
                let binding = Binding<String>(
                    get: { (props[key] as? String) ?? defaultID },
                    set: { onPatch(key, $0) }
                )
                if options.count <= 3 {
                    Picker("", selection: binding) {
                        ForEach(options, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } else {
                    Picker("", selection: binding) {
                        ForEach(options, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

        case let .color(key, label, defaultHex):
            labeled(label) {
                HStack(spacing: 8) {
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { OverlayColorBridge.color(from: (props[key] as? String) ?? defaultHex) },
                            set: { onPatch(key, OverlayColorBridge.hex(from: $0)) }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 38, height: 22)
                    Text((props[key] as? String) ?? defaultHex)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

        case let .number(key, label, min, max, defaultValue, step):
            labeled(label) {
                let binding = Binding<Double>(
                    get: {
                        if let d = props[key] as? Double { return d }
                        if let i = props[key] as? Int { return Double(i) }
                        if let n = props[key] as? NSNumber { return n.doubleValue }
                        return defaultValue
                    },
                    set: { onPatch(key, ($0 * 1).rounded() == $0.rounded() && step >= 1 ? Int($0.rounded()) : $0) }
                )
                HStack(spacing: 10) {
                    Slider(value: binding, in: min...max, step: step)
                    Text("\(Int(binding.wrappedValue))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 36, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

        case let .stringArray(key, label, minCount, maxCount, itemMaxLen, placeholder):
            OverlayStringArrayEditor(
                label: label,
                values: (props[key] as? [String]) ?? [],
                minCount: minCount,
                maxCount: maxCount,
                itemMaxLength: itemMaxLen,
                placeholder: placeholder,
                onChange: { onPatch(key, $0) }
            )

        case let .iconArray(key, label, minCount, maxCount):
            OverlayIconArrayEditor(
                label: label,
                items: (props[key] as? [[String: Any]]) ?? [],
                minCount: minCount,
                maxCount: maxCount,
                onChange: { onPatch(key, $0) }
            )

        case let .sequenceItems(key, label, minCount, maxCount):
            OverlaySequenceItemsEditor(
                label: label,
                items: (props[key] as? [[String: Any]]) ?? [],
                minCount: minCount,
                maxCount: maxCount,
                onChange: { onPatch(key, $0) }
            )

        case let .nested(key, label, fields):
            OverlayNestedEditor(
                label: label,
                parentKey: key,
                childProps: (props[key] as? [String: Any]) ?? [:],
                fields: fields,
                onChange: { onPatch(key, $0) }
            )
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Array editors

private struct OverlayStringArrayEditor: View {
    let label: String
    let values: [String]
    let minCount: Int
    let maxCount: Int
    let itemMaxLength: Int
    let placeholder: String
    var onChange: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if values.count < maxCount {
                        onChange(values + [""])
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(values.count < maxCount ? EditorShellStyle.accentSolid : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(values.count >= maxCount)
                .help(L("Add row"))
            }
            VStack(spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { idx, value in
                    HStack(spacing: 4) {
                        TextField(
                            placeholder,
                            text: Binding(
                                get: { value },
                                set: { new in
                                    var next = values
                                    let trimmed = String(new.prefix(itemMaxLength))
                                    if idx < next.count { next[idx] = trimmed } else { next.append(trimmed) }
                                    onChange(next)
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        Button {
                            if values.count > minCount {
                                var next = values
                                next.remove(at: idx)
                                onChange(next)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(values.count > minCount ? .secondary : Color.secondary.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(values.count <= minCount)
                    }
                }
            }
        }
    }
}

private struct OverlayIconArrayEditor: View {
    let label: String
    let items: [[String: Any]]
    let minCount: Int
    let maxCount: Int
    var onChange: ([[String: Any]]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if items.count < maxCount {
                        onChange(items + [["emoji": "✨", "label": "Item", "accentColor": "#00E0C7"]])
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(items.count < maxCount ? EditorShellStyle.accentSolid : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(items.count >= maxCount)
            }
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            TextField(
                                "Emoji",
                                text: Binding(
                                    get: { item["emoji"] as? String ?? "" },
                                    set: { new in
                                        var next = items
                                        next[idx]["emoji"] = String(new.prefix(4))
                                        onChange(next)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .frame(width: 52)

                            TextField(
                                "Label",
                                text: Binding(
                                    get: { item["label"] as? String ?? "" },
                                    set: { new in
                                        var next = items
                                        next[idx]["label"] = String(new.prefix(20))
                                        onChange(next)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))

                            ColorPicker(
                                "",
                                selection: Binding(
                                    get: { OverlayColorBridge.color(from: item["accentColor"] as? String ?? "#FF4D6A") },
                                    set: { c in
                                        var next = items
                                        next[idx]["accentColor"] = OverlayColorBridge.hex(from: c)
                                        onChange(next)
                                    }
                                ),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                            .frame(width: 32, height: 22)

                            Button {
                                if items.count > minCount {
                                    var next = items
                                    next.remove(at: idx)
                                    onChange(next)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(items.count > minCount ? .secondary : Color.secondary.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .disabled(items.count <= minCount)
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
}

private struct OverlaySequenceItemsEditor: View {
    let label: String
    let items: [[String: Any]]
    let minCount: Int
    let maxCount: Int
    var onChange: ([[String: Any]]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if items.count < maxCount {
                        onChange(items + [["label": "New step"]])
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(items.count < maxCount ? EditorShellStyle.accentSolid : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(items.count >= maxCount)
            }
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            TextField(
                                L("Label"),
                                text: Binding(
                                    get: { item["label"] as? String ?? "" },
                                    set: { new in
                                        var next = items
                                        next[idx]["label"] = String(new.prefix(80))
                                        onChange(next)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))

                            Button {
                                if items.count > minCount {
                                    var next = items
                                    next.remove(at: idx)
                                    onChange(next)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(items.count > minCount ? .secondary : Color.secondary.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .disabled(items.count <= minCount)
                        }
                        HStack(spacing: 4) {
                            TextField(
                                L("Icon"),
                                text: Binding(
                                    get: { item["icon"] as? String ?? "" },
                                    set: { new in
                                        var next = items
                                        if new.isEmpty { next[idx].removeValue(forKey: "icon") }
                                        else { next[idx]["icon"] = String(new.prefix(4)) }
                                        onChange(next)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .frame(width: 52)

                            TextField(
                                L("Caption"),
                                text: Binding(
                                    get: { item["caption"] as? String ?? "" },
                                    set: { new in
                                        var next = items
                                        if new.isEmpty { next[idx].removeValue(forKey: "caption") }
                                        else { next[idx]["caption"] = String(new.prefix(20)) }
                                        onChange(next)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
}

private struct OverlayNestedEditor: View {
    let label: String
    let parentKey: String
    let childProps: [String: Any]
    let fields: [OverlayFieldSpec]
    var onChange: ([String: Any]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    OverlayFieldRow(
                        field: field,
                        props: childProps,
                        onPatch: { key, value in
                            var next = childProps
                            if let value = value, !(value is NSNull) {
                                next[key] = value
                            } else {
                                next.removeValue(forKey: key)
                            }
                            onChange(next)
                        }
                    )
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Color helpers

enum OverlayColorBridge {
    static func color(from hex: String) -> Color {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let rgb = UInt32(cleaned, radix: 16) else {
            return Color(red: 0, green: 0.88, blue: 0.78)
        }
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Template registry

/// Options for the shared `backdropMode` prop.
private let backdropOptions: [(id: String, label: String)] = [
    ("transparent", "Float"),
    ("dim", "Dim"),
    ("solid", "Solid"),
]

/// Font slugs from `remotion/src/fonts.ts`. Keep in sync; an unknown
/// slug makes Remotion fall back to the default system stack (safe).
private let fontOptions: [(id: String, label: String)] = [
    ("", "Default"),
    ("bebas-neue", "Bebas Neue"),
    ("playfair-display", "Playfair Display"),
    ("lobster", "Lobster"),
    ("pacifico", "Pacifico"),
    ("dancing-script", "Dancing Script"),
    ("caveat", "Caveat"),
    ("great-vibes", "Great Vibes"),
    ("permanent-marker", "Permanent Marker"),
    ("ma-shan-zheng", "马善政"),
    ("zcool-kuaile", "站酷快乐"),
    ("zcool-xiaowei", "站酷小薇"),
    ("zcool-qingke-huangyou", "站酷庆科"),
    ("long-cang", "龙藏"),
    ("zhi-mang-xing", "知墨行"),
    ("liu-jian-mao-cao", "柳建毛草"),
    ("noto-serif-sc", "思源宋体"),
]

/// The one place that knows which props each overlay template exposes
/// to the user. Keep field labels short — the inspector panel is 340pt
/// wide. When adding a new template, mirror its Zod schema here.
let overlayTemplateSchemas: [String: OverlayTemplateSchema] = [
    "ChapterTitle": OverlayTemplateSchema(
        displayName: "Chapter Title",
        fields: [
            .text(key: "title", label: "Title", placeholder: "Chapter title", maxLength: 80),
            .text(key: "subtitle", label: "Subtitle", placeholder: "Optional", maxLength: 80),
            .picker(key: "theme", label: "Theme", options: [
                ("dark", "Dark"), ("light", "Light"), ("accent", "Accent"),
            ], defaultID: "dark"),
            .color(key: "accentColor", label: "Accent color", defaultHex: "#00E0C7"),
            .picker(key: "titleFontSlug", label: "Font", options: fontOptions, defaultID: ""),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "solid"),
        ]
    ),

    "TitleCard": OverlayTemplateSchema(
        displayName: "Title Card",
        fields: [
            .text(key: "title", label: "Title", placeholder: "Your Title", maxLength: 60),
            .text(key: "subtitle", label: "Subtitle", placeholder: "A short tagline", maxLength: 120),
            .color(key: "backgroundColor", label: "Background", defaultHex: "#0D0D0D"),
            .color(key: "accentColor", label: "Accent", defaultHex: "#FFFFFF"),
            .picker(key: "titleFontSlug", label: "Font", options: fontOptions, defaultID: ""),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "transparent"),
        ]
    ),

    "ChatBubble": OverlayTemplateSchema(
        displayName: "Chat Bubble",
        fields: [
            .text(key: "appName", label: "App name", placeholder: "Assistant", maxLength: 40),
            .text(key: "appInitial", label: "Avatar initial", placeholder: "A", maxLength: 2),
            .multiline(key: "userMessage", label: "User message", placeholder: "Write me a …", maxLength: 400),
            .multiline(key: "assistantReply", label: "Assistant reply", placeholder: "Sure — here's…", maxLength: 600),
            .color(key: "accentColor", label: "Accent", defaultHex: "#10A37F"),
        ]
    ),

    "PromptTyping": OverlayTemplateSchema(
        displayName: "Prompt Typing",
        fields: [
            .text(key: "agentName", label: "Agent name", placeholder: "Main Agent", maxLength: 40),
            .text(key: "agentStatus", label: "Status", placeholder: "Online", maxLength: 60),
            .text(key: "agentAvatar", label: "Avatar", placeholder: "✨", maxLength: 4),
            .multiline(key: "promptText", label: "Prompt text", placeholder: "The long prompt…", maxLength: 800),
            .text(key: "greeting", label: "Greeting", placeholder: "Hey — I'm here…", maxLength: 120),
            .text(key: "reply", label: "Reply", placeholder: "Got it ✓", maxLength: 160),
            .text(key: "inputPlaceholder", label: "Input placeholder", placeholder: "Type a message…", maxLength: 40),
            .color(key: "accentColor", label: "Accent", defaultHex: "#6366F1"),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "solid"),
        ]
    ),

    "SkillMeter": OverlayTemplateSchema(
        displayName: "Skill Meter",
        fields: [
            .text(key: "label", label: "Heading", placeholder: "Total skills", maxLength: 60),
            .number(key: "maxValue", label: "Max value", min: 5, max: 100, defaultValue: 22),
            .number(key: "lowZoneEnd", label: "Low zone end", min: 1, max: 98, defaultValue: 6),
            .number(key: "sweetSpotEnd", label: "Sweet-spot end", min: 2, max: 99, defaultValue: 14),
            .number(key: "peakValue", label: "Peak", min: 1, max: 100, defaultValue: 18),
            .number(key: "restValue", label: "Rest value", min: 0, max: 100, defaultValue: 14),
            .text(key: "lowZoneLabel", label: "Low-zone label", placeholder: "Too few", maxLength: 30),
            .text(key: "sweetSpotLabel", label: "Sweet-spot label", placeholder: "Recommended", maxLength: 30),
            .text(key: "warningText", label: "Warning", placeholder: "⚠ …", maxLength: 60),
            .color(key: "accentColor", label: "Accent", defaultHex: "#34D399"),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "transparent"),
        ]
    ),

    "CodeGen": OverlayTemplateSchema(
        displayName: "Code Gen",
        fields: [
            .text(key: "assistantName", label: "Assistant name", placeholder: "Assistant", maxLength: 40),
            .text(key: "modelLabel", label: "Model label", placeholder: "v1.0", maxLength: 40),
            .text(key: "assistantInitial", label: "Avatar initial", placeholder: "A", maxLength: 2),
            .multiline(key: "userPrompt", label: "User prompt", placeholder: "Build me…", maxLength: 400),
            .stringArray(key: "replyLines", label: "Reply lines", minCount: 1, maxCount: 20, itemMaxLength: 200, itemPlaceholder: "Line (use ``` for code blocks)"),
            .color(key: "accentColor", label: "Accent", defaultHex: "#D97757"),
        ]
    ),

    "ContextBar": OverlayTemplateSchema(
        displayName: "Context Bar",
        fields: [
            .text(key: "label", label: "Heading", placeholder: "Context window", maxLength: 60),
            .text(key: "leftCapLabel", label: "Left cap", placeholder: "0", maxLength: 20),
            .text(key: "rightCapLabel", label: "Right cap", placeholder: "200K tokens", maxLength: 40),
            .text(key: "calloutText", label: "Callout", placeholder: "⚡ Compacted", maxLength: 60),
            .number(key: "restPercent", label: "Rest %", min: 0, max: 80, defaultValue: 15),
            .color(key: "accentColor", label: "Accent", defaultHex: "#FFD700"),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "transparent"),
        ]
    ),

    "GitHubCard": OverlayTemplateSchema(
        displayName: "GitHub Card",
        fields: [
            .text(key: "repoName", label: "Repo", placeholder: "owner/repo", maxLength: 80),
            .multiline(key: "description", label: "Description", placeholder: "…", maxLength: 200),
            .text(key: "language", label: "Language", placeholder: "TypeScript", maxLength: 30),
            .color(key: "languageColor", label: "Lang color", defaultHex: "#3178C6"),
            .number(key: "targetStars", label: "Stars", min: 0, max: 1_000_000, defaultValue: 2400, step: 50),
            .color(key: "accentColor", label: "Accent", defaultHex: "#58A6FF"),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "transparent"),
        ]
    ),

    "TripleTap": OverlayTemplateSchema(
        displayName: "Triple Tap",
        fields: [
            .iconArray(key: "icons", label: "Icons", minCount: 2, maxCount: 6),
            .text(key: "tagline", label: "Tagline", placeholder: "Triple tap!", maxLength: 40),
            .color(key: "accentColor", label: "Accent", defaultHex: "#FF4D6A"),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "transparent"),
        ]
    ),

    "SequenceSteps": OverlayTemplateSchema(
        displayName: "Sequence Steps",
        fields: [
            .text(key: "heading", label: "Heading", placeholder: "Key takeaways", maxLength: 60),
            .picker(key: "layout", label: "Layout", options: [
                ("list", "List"), ("flow", "Flow"), ("timeline", "Timeline"),
            ], defaultID: "list"),
            .picker(key: "listStyle", label: "List style", options: [
                ("numbered", "1. 2. 3."), ("bulleted", "• • •"), ("emoji", "Emoji"),
            ], defaultID: "numbered"),
            .picker(key: "orientation", label: "Orientation", options: [
                ("horizontal", "Horizontal"), ("vertical", "Vertical"),
            ], defaultID: "horizontal"),
            .sequenceItems(key: "items", label: "Items", minCount: 2, maxCount: 6),
            .color(key: "accentColor", label: "Accent", defaultHex: "#00E0C7"),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "transparent"),
        ]
    ),

    "Quote": OverlayTemplateSchema(
        displayName: "Quote",
        fields: [
            .multiline(key: "quote", label: "Quote", placeholder: "Stay hungry…", maxLength: 240),
            .text(key: "attribution", label: "Attribution", placeholder: "Optional", maxLength: 80),
            .color(key: "backgroundColor", label: "Background", defaultHex: "#0D0D0D"),
            .color(key: "accentColor", label: "Accent", defaultHex: "#00E0C7"),
            .picker(key: "quoteFontSlug", label: "Font", options: fontOptions, defaultID: ""),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "transparent"),
        ]
    ),

    "Comparison": OverlayTemplateSchema(
        displayName: "Comparison",
        fields: [
            .text(key: "heading", label: "Heading", placeholder: "Optional", maxLength: 60),
            .text(key: "dividerLabel", label: "Divider", placeholder: "VS", maxLength: 12),
            .nested(key: "left", label: "Left side", fields: [
                .text(key: "title", label: "Title", placeholder: "Option A", maxLength: 30),
                .stringArray(key: "bullets", label: "Bullets", minCount: 1, maxCount: 5, itemMaxLength: 60),
                .color(key: "accentColor", label: "Accent", defaultHex: "#FF6B6B"),
            ]),
            .nested(key: "right", label: "Right side", fields: [
                .text(key: "title", label: "Title", placeholder: "Option B", maxLength: 30),
                .stringArray(key: "bullets", label: "Bullets", minCount: 1, maxCount: 5, itemMaxLength: 60),
                .color(key: "accentColor", label: "Accent", defaultHex: "#00E0C7"),
            ]),
            .picker(key: "backdropMode", label: "Backdrop", options: backdropOptions, defaultID: "transparent"),
        ]
    ),
]
