import SwiftUI
import CuttiKit

/// CapCut-style bottom dock. Starts at the `.main` page listing the
/// top-level categories (剪辑, 音频, 文本, …). Tapping a category
/// replaces the dock contents with that category's sub-actions plus a
/// leading back arrow. "剪辑" sub-actions operate on the currently
/// selected segment.
///
/// The dock also exposes an AI pill on the left edge of the main page,
/// which the parent layout (EditorPhoneLayout) observes via
/// `onAITapped` to present a sheet.
struct ToolDock: View {
    @EnvironmentObject private var document: ProjectDocument
    @State private var page: Page = .main

    let onAITapped: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    if page != .main {
                        backButton
                    }
                    ForEach(items, id: \.id) { item in
                        item.view
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .frame(height: 62)
        }
        .background(Color.black)
        .sheet(isPresented: $presentVolumePopover) {
            VolumeAdjustSheet()
                .environmentObject(document)
                .presentationDetents([.height(160)])
        }
        .sheet(isPresented: $presentSpeedPopover) {
            SpeedAdjustSheet()
                .environmentObject(document)
                .presentationDetents([.height(200)])
        }
        .sheet(isPresented: $presentColorPopover) {
            ColorAdjustSheet()
                .environmentObject(document)
                .presentationDetents([.height(300)])
        }
        .sheet(isPresented: $presentAudioPicker) {
            AudioPicker(
                onPicked: { url in
                    presentAudioPicker = false
                    Task { await importAudio(url) }
                },
                onCancel: { presentAudioPicker = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $presentBGMPicker) {
            AudioPicker(
                onPicked: { url in
                    presentBGMPicker = false
                    Task { await importBGM(url) }
                },
                onCancel: { presentBGMPicker = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $presentTextSheet) {
            AddTextSheet()
                .environmentObject(document)
                .presentationDetents([.height(260)])
        }
        .sheet(isPresented: Binding(
            get: { editingOverlayID != nil },
            set: { if !$0 { editingOverlayID = nil } }
        )) {
            if let id = editingOverlayID {
                TextOverlayEditorSheet(overlayID: id)
                    .environmentObject(document)
                    .presentationDetents([.height(380)])
            }
        }
        .sheet(isPresented: $presentTextStyleSheet) {
            TextStyleSheet()
                .environmentObject(document)
                .presentationDetents([.height(420)])
        }
        .sheet(isPresented: $presentFadeSheet) {
            FadeAdjustSheet()
                .environmentObject(document)
                .presentationDetents([.height(240)])
        }
        .sheet(isPresented: $presentAudioExtractPicker) {
            AudioPicker(
                onPicked: { url in
                    presentAudioExtractPicker = false
                    Task { await importAudio(url) }
                },
                onCancel: { presentAudioExtractPicker = false },
                includeVideo: true
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $presentVoiceRecorder) {
            VoiceRecorderSheet()
                .environmentObject(document)
                .presentationDetents([.height(420)])
        }
        .sheet(isPresented: $presentStickerPicker) {
            StickerPickerSheet()
                .environmentObject(document)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $presentBackgroundPicker) {
            BackgroundPickerSheet()
                .environmentObject(document)
                .presentationDetents([.height(480)])
        }
        .sheet(isPresented: $presentPiPOpacity) {
            PiPOpacitySheet()
                .environmentObject(document)
                .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $presentFreeTransform) {
            FreeTransformSheet()
                .environmentObject(document)
        }
        .sheet(item: $textTemplatesGroup) { wrap in
            TextTemplatesSheet(initialGroup: wrap.group)
                .environmentObject(document)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $presentChapters) {
            ChaptersSheet()
                .environmentObject(document)
        }
        .sheet(isPresented: $presentTranscriptEditor) {
            TranscriptSheet()
                .environmentObject(document)
                .presentationDetents([.large])
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(L(errorMessage ?? "")) }
        )
    }

    private func importAudio(_ url: URL) async {
        do {
            try await document.importAudio(at: url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importBGM(_ url: URL) async {
        do {
            try await document.importBGM(at: url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Page state

    enum Page: Equatable {
        case main
        case cut
        case audio
        case text
        case sticker
        case pip
        case effect
        case filter
        case transition
        case ratio
        case background
    }

    private var backButton: some View {
        Button {
            page = .main
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16))
                Text("返回")
                    .font(.system(size: 10))
            }
            .frame(width: 40, height: 46)
            .foregroundStyle(.white)
        }
    }

    private struct Item: Identifiable {
        let id: String
        let view: AnyView
    }

    /// Items rendered for the current page.
    private var items: [Item] {
        switch page {
        case .main:     return mainItems
        case .cut:      return cutItems
        case .audio:    return audioItems
        case .text:     return textItems
        case .sticker:  return stubItems(for: page)
        case .pip:      return stubItems(for: page)
        case .effect:   return stubItems(for: page)
        case .filter:   return stubItems(for: page)
        case .transition: return transitionItems
        case .ratio:    return stubItems(for: page)
        case .background: return stubItems(for: page)
        }
    }

    // MARK: - Main page

    private var mainItems: [Item] {
        let aiItem = Item(id: "ai", view: AnyView(
            DockButton(icon: "sparkles", label: "AI", iconColor: .pink) {
                onAITapped()
            }
        ))

        let pages: [(String, String, Page)] = [
            ("scissors", "剪辑", .cut),
            ("music.note", "音频", .audio),
            ("textformat", "文本", .text),
            ("face.smiling", "贴纸", .sticker),
            ("rectangle.on.rectangle", "画中画", .pip),
            ("sparkle", "特效", .effect),
            ("camera.filters", "滤镜", .filter),
            ("arrow.triangle.swap", "转场", .transition),
            ("aspectratio", "比例", .ratio),
            ("photo", "背景", .background),
        ]
        return [aiItem] + pages.map { (icon, label, p) in
            Item(id: label, view: AnyView(
                DockButton(icon: icon, label: label) { page = p }
            ))
        }
    }

    // MARK: - 剪辑 (Cut)

    private var cutItems: [Item] {
        let hasSelection = document.selectedSegmentID != nil
        func mk(_ icon: String, _ label: String, enabled: Bool = true,
                action: @escaping () -> Void) -> Item {
            Item(id: label, view: AnyView(
                DockButton(icon: icon, label: label, enabled: enabled, action: action)
            ))
        }
        return [
            mk("scissors", "分割") { document.splitAtPlayhead() },
            mk("trash", "删除", enabled: hasSelection) { document.deleteSelectedSegment() },
            mk("plus.square.on.square", "复制", enabled: hasSelection) { document.duplicateSelectedSegment() },
            mk("arrow.left.and.right.square", "合并", enabled: document.canMergeSelected) { document.mergeSelectedWithNext() },
            mk("arrow.left.to.line", "左移", enabled: hasSelection) { document.moveSelectedSegment(offset: -1) },
            mk("arrow.right.to.line", "右移", enabled: hasSelection) { document.moveSelectedSegment(offset: 1) },
            mk("speedometer", "变速", enabled: hasSelection) { presentSpeedPopover = true },
            mk("speaker.wave.2", "音量", enabled: hasSelection) { presentVolumePopover = true },
            mk("slider.horizontal.3", "调节", enabled: hasSelection) { presentColorPopover = true },
            mk("rotate.right", "旋转", enabled: hasSelection) { document.rotateSelectedSegment90() },
            mk("arrow.left.and.right.righttriangle.left.righttriangle.right", "水平镜像", enabled: hasSelection) { document.flipSelectedSegmentHorizontal() },
            mk("arrow.up.and.down.righttriangle.up.righttriangle.down", "垂直镜像", enabled: hasSelection) { document.flipSelectedSegmentVertical() },
            mk("eye.slash", "隐藏", enabled: hasSelection) { document.toggleSelectedSegmentVideoHidden() },
            mk(document.isPrimaryTrackMuted ? "speaker.wave.2" : "speaker.slash", document.isPrimaryTrackMuted ? "开启原声" : "关闭原声") {
                document.togglePrimaryTrackMuted()
            },
            mk("list.number", "章节") { presentChapters = true },
        ]
    }

    @State private var presentVolumePopover = false
    @State private var presentSpeedPopover = false
    @State private var presentColorPopover = false
    @State private var presentAudioPicker = false
    @State private var presentBGMPicker = false
    @State private var presentTextSheet = false
    @State private var presentTextStyleSheet = false
    @State private var presentFadeSheet = false
    @State private var presentAudioExtractPicker = false
    @State private var presentVoiceRecorder = false
    @State private var presentStickerPicker = false
    @State private var presentBackgroundPicker = false
    @State private var presentPiPOpacity = false
    @State private var presentFreeTransform = false
    @State private var presentChapters = false
    @State private var presentTranscriptEditor = false
    @State private var textTemplatesGroup: TextTemplateGroupID? = nil
    @State private var transcribingSegmentID: UUID?
    @State private var errorMessage: String?
    @State private var editingOverlayID: UUID?

    // MARK: - 音频 (Audio)

    private var audioItems: [Item] {
        let hasSelection = document.selectedSegmentID != nil
        return [
            Item(id: "添加音乐", view: AnyView(
                DockButton(icon: "music.note.list", label: "添加音乐") {
                    presentAudioPicker = true
                }
            )),
            Item(id: "背景音乐", view: AnyView(
                DockButton(icon: "music.quarternote.3", label: "背景音乐") {
                    presentBGMPicker = true
                }
            )),
            Item(id: "淡入淡出", view: AnyView(
                DockButton(icon: "waveform.path.ecg", label: "淡入淡出", enabled: hasSelection) {
                    presentFadeSheet = true
                }
            )),
            Item(id: "录音", view: AnyView(
                DockButton(icon: "waveform.badge.plus", label: "录音") {
                    presentVoiceRecorder = true
                }
            )),
            Item(id: "提取音乐", view: AnyView(
                DockButton(icon: "speaker.wave.3", label: "提取音乐") {
                    presentAudioExtractPicker = true
                }
            )),
            Item(id: "关闭原声", view: AnyView(
                DockButton(
                    icon: document.isPrimaryTrackMuted ? "speaker.wave.2" : "speaker.slash",
                    label: document.isPrimaryTrackMuted ? "开启原声" : "关闭原声"
                ) { document.togglePrimaryTrackMuted() }
            )),
        ]
    }

    // MARK: - 转场 (Transition)

    /// Transition dock mirrors CapCut's dedicated 转场 tab. Lets the
    /// user toggle / tune the cross-fade on the selected cut, and also
    /// apply a uniform cut-wide fade in one tap. Named-style presets
    /// (wipe, zoom, flash) are intentionally deferred — the current
    /// compositor only does cross-dissolve, exposing fake styles would
    /// lie to the user.
    private var transitionItems: [Item] {
        let hasSelection = document.selectedSegmentID != nil
        let selID = document.selectedSegmentID
        let current: Double = selID.map { document.transitions[$0] ?? 0 } ?? 0

        func setSel(_ seconds: Double) {
            guard let id = selID else {
                errorMessage = "请先在时间轴选中一个片段"
                return
            }
            document.setTransitionDuration(for: id, seconds: seconds)
        }

        func isAt(_ seconds: Double) -> Bool {
            abs(current - seconds) < 0.02
        }

        func durationTile(_ label: String, _ seconds: Double, _ icon: String) -> Item {
            Item(id: "dur-\(label)", view: AnyView(
                DockButton(
                    icon: icon,
                    label: label,
                    iconColor: isAt(seconds) ? .pink : .white,
                    enabled: hasSelection
                ) { setSel(seconds) }
            ))
        }

        return [
            Item(id: "无转场", view: AnyView(
                DockButton(
                    icon: "circle.slash",
                    label: "无",
                    iconColor: current <= 0 ? .pink : .white,
                    enabled: hasSelection
                ) { setSel(0) }
            )),
            durationTile("快", 0.3, "hare"),
            durationTile("中", 0.6, "equal"),
            durationTile("慢", 1.2, "tortoise"),
            Item(id: "应用到全部", view: AnyView(
                DockButton(icon: "rectangle.3.group", label: "应用到全部") {
                    let applied = document.applyUniformTransition(seconds: 0.5)
                    if applied == 0 {
                        errorMessage = "时间线上没有可加转场的切点"
                    }
                }
            )),
            Item(id: "清除全部", view: AnyView(
                DockButton(icon: "xmark.circle", label: "清除全部") {
                    document.transitions = [:]
                }
            )),
        ]
    }

    // MARK: - 文本 (Text)

    private var textItems: [Item] {
        [
            Item(id: "新建文本", view: AnyView(
                DockButton(icon: "text.bubble", label: "新建文本") {
                    presentTextSheet = true
                }
            )),
            Item(id: "自由文字", view: AnyView(
                DockButton(icon: "character.textbox", label: "自由文字") {
                    let id = document.addTextOverlay()
                    editingOverlayID = id
                }
            )),
            Item(id: "智能字幕", view: AnyView(
                DockButton(icon: "character.bubble", label: "智能字幕") {
                    errorMessage = "请前往 AI 工具箱 → 智能字幕"
                }
            )),
            Item(id: "字幕编辑", view: AnyView(
                DockButton(icon: "text.cursor", label: "字幕编辑") {
                    presentTranscriptEditor = true
                }
            )),
            Item(id: "字幕样式", view: AnyView(
                DockButton(icon: "paintpalette", label: "字幕样式") {
                    presentTextStyleSheet = true
                }
            )),
            stub("text.redaction", "文字模板") {
                textTemplatesGroup = .init(group: .template)
            },
            stub("character", "花字") {
                textTemplatesGroup = .init(group: .fancy)
            },
        ]
    }

    private func stubItems(for p: Page) -> [Item] {
        if p == .ratio {
            return ProjectDocument.AspectRatio.allCases.map { ar in
                Item(id: ar.label, view: AnyView(
                    DockButton(
                        icon: icon(for: ar),
                        label: ar.label,
                        iconColor: document.aspectRatio == ar ? .pink : .white
                    ) {
                        document.aspectRatio = ar
                    }
                ))
            }
        }
        if p == .filter {
            let hasSelection = document.selectedSegmentID != nil
            return ProjectDocument.FilterPreset.allCases.map { preset in
                Item(id: preset.label, view: AnyView(
                    DockButton(
                        icon: icon(for: preset),
                        label: preset.label,
                        enabled: hasSelection
                    ) { document.applyFilterPreset(preset) }
                ))
            }
        }
        if p == .sticker {
            let popular = ["🔥","❤️","😂","✨","👍","🎉","💯","😎"]
            var items: [Item] = [
                Item(id: "添加贴纸", view: AnyView(
                    DockButton(icon: "face.smiling", label: "贴纸库", iconColor: .pink) {
                        presentStickerPicker = true
                    }
                ))
            ]
            items.append(contentsOf: popular.map { e in
                Item(id: e, view: AnyView(
                    EmojiQuickButton(emoji: e) {
                        _ = document.insertTextAtPlayhead(e, duration: 2.0)
                    }
                ))
            })
            return items
        }
        if p == .effect {
            let hasSelection = document.selectedSegmentID != nil
            let current: ProjectDocument.VisualEffectPreset = document.selectedSegmentID
                .flatMap { document.visualEffects[$0] } ?? .none
            return ProjectDocument.VisualEffectPreset.allCases.map { preset in
                Item(id: preset.rawValue, view: AnyView(
                    DockButton(
                        icon: preset.icon,
                        label: preset.label,
                        iconColor: current == preset ? .pink : .white,
                        enabled: hasSelection
                    ) { document.setSelectedVisualEffect(preset) }
                ))
            }
        }
        if p == .background {
            return [
                Item(id: "打开背景", view: AnyView(
                    DockButton(icon: "rectangle.portrait.and.arrow.forward", label: "背景", iconColor: .pink) {
                        presentBackgroundPicker = true
                    }
                )),
                Item(id: "模糊", view: AnyView(
                    DockButton(icon: "drop.fill", label: "模糊") {
                        document.background = .blur
                    }
                )),
                Item(id: "黑色", view: AnyView(
                    DockButton(icon: "square.fill", label: "黑色") {
                        document.background = .color(.init(red: 0, green: 0, blue: 0, alpha: 1))
                    }
                )),
                Item(id: "白色", view: AnyView(
                    DockButton(icon: "square", label: "白色") {
                        document.background = .color(.init(red: 1, green: 1, blue: 1, alpha: 1))
                    }
                )),
            ]
        }
        let labels: [String] = {
            switch p {
            case .pip: return []
            default: return []
            }
        }()
        if p == .pip {
            let hasPiP = document.selectedSegment?.pipLayout != nil
            let currentOpacity = document.selectedSegment?.freeTransform?.opacity ?? 1.0
            return [
                Item(id: "添加画中画", view: AnyView(
                    DockButton(icon: "rectangle.inset.filled.on.rectangle", label: "添加画中画", iconColor: .pink) {
                        NotificationCenter.default.post(name: .cuttiRequestPiPImport, object: nil)
                    }
                )),
                Item(id: "蒙版", view: AnyView(
                    DockButton(icon: maskIcon(for: document.selectedSegment?.pipLayout?.shape),
                               label: "蒙版",
                               enabled: hasPiP) {
                        if !document.cycleSelectedPiPShape() {
                            errorMessage = "请先在时间轴选中一个画中画片段"
                        }
                    }
                )),
                Item(id: "透明度", view: AnyView(
                    DockButton(icon: opacityIcon(for: currentOpacity),
                               label: "透明度",
                               enabled: hasPiP) {
                        if hasPiP {
                            presentPiPOpacity = true
                        } else {
                            errorMessage = "请先在时间轴选中一个画中画片段"
                        }
                    }
                )),
                Item(id: "自由变换", view: AnyView(
                    DockButton(icon: "selection.pin.in.out",
                               label: "自由变换",
                               enabled: document.firstOverlaySegment != nil) {
                        if document.firstOverlaySegment != nil {
                            presentFreeTransform = true
                        } else {
                            errorMessage = "请先添加一段画中画或叠加素材"
                        }
                    }
                )),
            ]
        }
        return labels.map { l in
            Item(id: l, view: AnyView(
                DockButton(icon: "circle.dashed", label: l) { }
            ))
        }
    }

    private func icon(for preset: ProjectDocument.FilterPreset) -> String {
        switch preset {
        case .original: return "circle"
        case .warm:     return "sun.max"
        case .cool:     return "snowflake"
        case .vivid:    return "paintpalette.fill"
        case .mono:     return "circle.lefthalf.filled"
        case .film:     return "film"
        case .vlog:     return "video.fill"
        }
    }

    private func icon(for ar: ProjectDocument.AspectRatio) -> String {
        switch ar {
        case .portrait9x16:   return "rectangle.portrait"
        case .landscape16x9:  return "rectangle"
        case .square:         return "square"
        case .landscape4x3:   return "rectangle"
        case .portrait3x4:    return "rectangle.portrait"
        case .widescreen21x9: return "rectangle.compress.vertical"
        }
    }

    private func stub(_ icon: String, _ label: String, action: @escaping () -> Void = {}) -> Item {
        Item(id: label, view: AnyView(
            DockButton(icon: icon, label: label, action: action)
        ))
    }

    private func maskIcon(for shape: PiPLayout.Shape?) -> String {
        switch shape {
        case .circle?:        return "circle"
        case .roundedSquare?: return "square.dashed"
        case .square?:        return "square"
        case nil:             return "square.dashed"
        }
    }

    private func opacityIcon(for opacity: Double) -> String {
        if opacity >= 0.99 { return "circle.fill" }
        if opacity <= 0.01 { return "circle" }
        return "circle.lefthalf.filled"
    }
}

extension Notification.Name {
    /// Posted by ToolDock's "添加画中画" button. The host editor layout
    /// observes this and presents its picker configured to import the
    /// chosen video as a PiP overlay (see `ProjectDocument.importPiPOverlay`).
    static let cuttiRequestPiPImport = Notification.Name("cuttiRequestPiPImport")
}

/// Single icon-over-label button used throughout the dock.
struct DockButton: View {
    let icon: String
    let label: String
    var iconColor: Color = .white
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 32, height: 28)
                    .foregroundStyle(enabled ? iconColor : Color.white.opacity(0.3))
                Text(L(label))
                    .font(.system(size: 10))
                    .foregroundStyle(enabled ? .white : Color.white.opacity(0.3))
                    .lineLimit(1)
            }
            .frame(minWidth: 48)
        }
        .disabled(!enabled)
    }
}

/// Emoji sized to match a DockButton icon — used by the sticker tab
/// quick-access row so popular emojis sit beside the "贴纸库" entry.
struct EmojiQuickButton: View {
    let emoji: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(emoji)
                    .font(.system(size: 22))
                    .frame(width: 32, height: 28)
                Text(" ")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .frame(minWidth: 48)
        }
    }
}
