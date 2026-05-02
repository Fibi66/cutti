import SwiftUI
import CuttiKit

/// Interactive SwiftUI overlay that mirrors `ChapterBarBurnInRenderer`
/// for the in-app preview. Layout and style are read from
/// `ChapterBarStyle`; interactions call back to mutate the chapter list
/// (or the style) on the view model.
///
/// Interactions:
///   • Right-click the bar → context menu (toggle top/bottom, open
///     style panel).
///   • Drag any divider between two chapters → updates those two
///     chapter boundaries live; min chapter length 1s is enforced.
///   • Double-click a divider → popover with mm:ss.SSS time input.
///   • Double-click the current chapter title → inline rename.
struct ChapterBarOverlay: View {
    let chapters: [VideoChapter]
    /// Total composed-timeline duration in seconds.
    let totalSeconds: Double
    /// Current playhead, in composed-timeline seconds.
    let playheadSeconds: Double
    /// Video width / video height. When nil, the overlay covers the full
    /// container.
    let videoAspectRatio: CGFloat?
    /// Style snapshot (anchor + colors + font + opacity).
    let style: ChapterBarStyle

    // Mutation callbacks. Host decides whether to persist and push a
    // revision. Ephemeral drag updates should use `onPreviewChapters`;
    // `onCommitChapters` is called once on drag-end / form-submit /
    // rename-commit. Style toggles go through `onStyleChange`.
    /// Called with in-progress chapter edits during a divider drag.
    /// Hosts can use this for live preview without pushing a revision.
    var onPreviewChapters: ([VideoChapter]) -> Void = { _ in }
    /// Called once per user-initiated edit (drag-end, time-input save,
    /// rename commit). Hosts should persist + push a revision here.
    var onCommitChapters: ([VideoChapter]) -> Void = { _ in }
    /// Called when the user changes style (anchor toggle / style sheet).
    var onStyleChange: (ChapterBarStyle) -> Void = { _ in }
    /// Called when the user asks to delete the whole chapter bar via
    /// the context menu. Host should clear the persisted chapter list
    /// and push an undoable revision with a "Remove chapter bar" label.
    var onRemoveChapters: () -> Void = { }

    // Local interaction state.
    @State private var liveChapters: [VideoChapter]? = nil
    @State private var draggingDividerIndex: Int? = nil
    @State private var editingDividerIndex: Int? = nil
    @State private var dividerTimeInput: String = ""
    @State private var renamingChapterID: UUID? = nil
    @State private var renameText: String = ""
    @State private var showStyleSheet: Bool = false

    private var displayChapters: [VideoChapter] { liveChapters ?? chapters }

    var body: some View {
        GeometryReader { geo in
            let videoRect = videoDisplayRect(in: geo.size)
            ZStack {
                if !displayChapters.isEmpty, totalSeconds > 0, videoRect.width > 8 {
                    chapterBar(videoRect: videoRect, geoSize: geo.size)
                }
            }
        }
        .sheet(isPresented: $showStyleSheet) {
            ChapterBarStylePanel(
                initialStyle: style,
                onApply: { newStyle in
                    onStyleChange(newStyle)
                    showStyleSheet = false
                },
                onCancel: { showStyleSheet = false }
            )
        }
    }

    @ViewBuilder
    private func chapterBar(videoRect: CGRect, geoSize: CGSize) -> some View {
        // Layout proportions mirror ChapterBarBurnInRenderer (canonical 1080p).
        let scale = videoRect.height / 1080.0
        let barHeight = max(2, 6 * scale)
        let hInset = 64 * scale
        // Bar sits flush near the video edge. Small inset so the track
        // isn't clipped by the frame but it reads as bottom-anchored.
        let edgeInset = 8 * scale
        let segGap = max(1, 4 * scale)
        let corner = 3 * scale
        let titleGap = 18 * scale
        let titleFontSize = max(10, CGFloat(style.fontSize) * scale)
        let panelPadX = 32 * scale
        let panelPadY = 14 * scale
        let panelCorner = 10 * scale

        let barLeft = videoRect.minX + hInset
        let barWidth = max(1, videoRect.width - hInset * 2)
        // SwiftUI: (0,0) top-left.
        let barTop: CGFloat = {
            switch style.anchor {
            case .bottom: return videoRect.maxY - edgeInset - barHeight
            case .top:    return videoRect.minY + edgeInset
            }
        }()

        let active = activeChapter()
        // Title row height is driven by font size. We always reserve
        // space because every chapter draws its own title (not just the
        // active one).
        let titleHeight = titleFontSize * 1.2

        // Background panel rect (matches renderer).
        let panelWidth = barWidth + panelPadX * 2
        let panelHeight = barHeight + titleGap + titleHeight + panelPadY * 2
        let panelX = videoRect.midX - panelWidth / 2
        let panelY: CGFloat = {
            switch style.anchor {
            case .bottom: return barTop - titleGap - titleHeight - panelPadY
            case .top:    return barTop - panelPadY
            }
        }()

        let bgColor = Color(
            red: style.backgroundColor.red,
            green: style.backgroundColor.green,
            blue: style.backgroundColor.blue
        )
        let fontColor = Color(
            red: style.fontColor.red,
            green: style.fontColor.green,
            blue: style.fontColor.blue
        )
        let effectiveBgAlpha = max(0, min(1, style.backgroundColor.alpha * style.backgroundOpacity))

        // Title placement relative to the bar depends on anchor.
        let titleTop: CGFloat = {
            switch style.anchor {
            case .bottom: return barTop - titleGap - titleHeight
            case .top:    return barTop + barHeight + titleGap
            }
        }()

        ZStack(alignment: .topLeading) {
            // Background panel
            if effectiveBgAlpha > 0.001 {
                RoundedRectangle(cornerRadius: panelCorner)
                    .fill(bgColor.opacity(effectiveBgAlpha))
                    .frame(width: panelWidth, height: panelHeight)
                    .offset(x: panelX, y: panelY)
                    .allowsHitTesting(false)
            }

            // Transparent hit-shape covering the entire chapter-bar panel
            // region. Gives the user a generous target so right-click
            // anywhere on the bar or its title row opens the context
            // menu ("Chapter style…", "Move to top/bottom"). Without
            // this, only the 10pt-wide divider hit zones would accept
            // clicks, which is nearly impossible to discover.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: panelWidth, height: panelHeight)
                .offset(x: panelX, y: panelY)
                .contextMenu {
                    Button(style.anchor == .bottom ? L("Move to top") : L("Move to bottom")) {
                        var newStyle = style
                        newStyle.anchor = (style.anchor == .bottom ? .top : .bottom)
                        onStyleChange(newStyle)
                    }
                    Divider()
                    Button {
                        showStyleSheet = true
                    } label: { T("Chapter style…") }
                    Divider()
                    Button(role: .destructive) {
                        liveChapters = nil
                        onRemoveChapters()
                    } label: { T("Remove chapter bar") }
                }

            // Track background
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.white.opacity(0.30))
                .frame(width: barWidth, height: barHeight)
                .offset(x: barLeft, y: barTop)
                .allowsHitTesting(false)

            // Per-chapter segments (filled / progress / future).
            ForEach(Array(displayChapters.enumerated()), id: \.element.id) { (i, c) in
                let segRect = segmentRect(
                    index: i,
                    chapter: c,
                    barLeft: barLeft,
                    barTop: barTop,
                    barWidth: barWidth,
                    barHeight: barHeight,
                    segGap: segGap
                )
                if segRect.width > 0.5 {
                    if let active, i < active.index {
                        RoundedRectangle(cornerRadius: corner)
                            .fill(Color.white.opacity(0.85))
                            .frame(width: segRect.width, height: barHeight)
                            .offset(x: segRect.minX, y: segRect.minY)
                            .allowsHitTesting(false)
                    } else if let active, i == active.index {
                        let progress = active.chapter.durationSeconds > 0
                            ? max(0, min(1, (playheadSeconds - active.chapter.startSeconds) / active.chapter.durationSeconds))
                            : 1
                        let fillWidth = segRect.width * CGFloat(progress)
                        if fillWidth > 0.5 {
                            RoundedRectangle(cornerRadius: corner)
                                .fill(Color(red: 1.0, green: 0.30, blue: 0.30))
                                .frame(width: fillWidth, height: barHeight)
                                .offset(x: segRect.minX, y: segRect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }

            // Divider hit-zones between consecutive chapters (drag & double-click).
            ForEach(Array(displayChapters.dropLast().enumerated()), id: \.offset) { pair in
                let i = pair.offset
                let dividerTime = displayChapters[i].endSeconds
                let frac = dividerTime / totalSeconds
                let centerX = barLeft + barWidth * CGFloat(frac)
                let hitWidth: CGFloat = 10
                let hitHeight: CGFloat = max(barHeight + 14, 18)
                let hitX = centerX - hitWidth / 2
                let hitY = barTop - 7

                ZStack {
                    // Visual divider line (thin vertical).
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 1.5, height: hitHeight)
                    // Knob when hovering/dragging (simpler: always show
                    // when editing; otherwise invisible but still hit-testable).
                    if draggingDividerIndex == i || editingDividerIndex == i {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 1.5)
                            .background(Circle().fill(Color(red: 1.0, green: 0.30, blue: 0.30)))
                            .frame(width: 10, height: 10)
                            .offset(y: 0)
                    }
                }
                .frame(width: hitWidth, height: hitHeight)
                .contentShape(Rectangle())
                .offset(x: hitX, y: hitY)
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            draggingDividerIndex = i
                            applyDividerDragTranslation(
                                dividerIndex: i,
                                translation: g.translation,
                                barWidth: barWidth
                            )
                        }
                        .onEnded { _ in
                            handleDividerDragEnd()
                        }
                )
                .onTapGesture(count: 2) {
                    editingDividerIndex = i
                    dividerTimeInput = formatTime(dividerTime)
                }
                .popover(isPresented: Binding(
                    get: { editingDividerIndex == i },
                    set: { if !$0 { editingDividerIndex = nil } }
                )) {
                    DividerTimeInputPopover(
                        initialText: dividerTimeInput,
                        minSeconds: (i > 0 ? displayChapters[i - 1].startSeconds : 0) + 1.0,
                        maxSeconds: (i + 2 < displayChapters.count ? displayChapters[i + 2].startSeconds : totalSeconds) - 1.0,
                        onCancel: { editingDividerIndex = nil },
                        onSubmit: { seconds in
                            commitDividerTime(dividerIndex: i, seconds: seconds)
                            editingDividerIndex = nil
                        }
                    )
                }
            }

            // Per-chapter titles: one centered on each segment so viewers
            // see the full chapter list at a glance. Each title is clipped
            // to its own segment width. The active chapter's title gets
            // inline-rename via double-click; others are informational.
            ForEach(Array(displayChapters.enumerated()), id: \.element.id) { (i, c) in
                let segRect = segmentRect(
                    index: i,
                    chapter: c,
                    barLeft: barLeft,
                    barTop: barTop,
                    barWidth: barWidth,
                    barHeight: barHeight,
                    segGap: segGap
                )
                let segTitle = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !segTitle.isEmpty && segRect.width > 8 {
                    Group {
                        if renamingChapterID == c.id {
                            TextField(L("Chapter title"), text: $renameText, onCommit: {
                                commitRename(chapterID: c.id)
                            })
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: titleFontSize, weight: .semibold))
                        } else {
                            Text(segTitle)
                                .font(.system(size: titleFontSize, weight: .semibold))
                                .foregroundStyle(fontColor)
                                .shadow(color: .black.opacity(0.85), radius: 6, x: 0, y: 2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .onTapGesture(count: 2) {
                                    renamingChapterID = c.id
                                    renameText = c.title
                                }
                        }
                    }
                    .frame(width: segRect.width, height: titleHeight, alignment: .center)
                    .offset(x: segRect.minX, y: titleTop)
                }
            }

            // Right-click hit layer covering the full panel area. This
            // sits ABOVE the decorative bar but BELOW the dividers
            // (dividers are added later in ZStack so they win).
        }
        .frame(width: geoSize.width, height: geoSize.height, alignment: .topLeading)
    }

    // MARK: - Divider math

    private func segmentRect(
        index i: Int,
        chapter c: VideoChapter,
        barLeft: CGFloat,
        barTop: CGFloat,
        barWidth: CGFloat,
        barHeight: CGFloat,
        segGap: CGFloat
    ) -> CGRect {
        let startFrac = c.startSeconds / totalSeconds
        let endFrac = c.endSeconds / totalSeconds
        var segLeft = barLeft + barWidth * CGFloat(startFrac)
        var segRight = barLeft + barWidth * CGFloat(endFrac)
        if i > 0 { segLeft += segGap / 2 }
        if i < displayChapters.count - 1 { segRight -= segGap / 2 }
        let w = max(0, segRight - segLeft)
        return CGRect(x: segLeft, y: barTop, width: w, height: barHeight)
    }

    private func handleDividerDragEnd() {
        draggingDividerIndex = nil
        guard let edited = liveChapters else { return }
        liveChapters = nil
        onCommitChapters(edited)
    }

    // Actual drag handler used by the gesture above (takes translation
    // via a stateful accumulator). We swap to a translation-based
    // approach here because the hit-zone's own frame is tiny.
    private func applyDividerDragTranslation(
        dividerIndex i: Int,
        translation: CGSize,
        barWidth: CGFloat
    ) {
        let base = chapters
        guard i >= 0, i + 1 < base.count else { return }
        let deltaSeconds = Double(translation.width / max(1, barWidth)) * totalSeconds
        var edited = base
        let minGap: Double = 1.0
        var newBoundary = base[i].endSeconds + deltaSeconds
        // Clamp so neither side shrinks under 1s.
        let lowerBound = base[i].startSeconds + minGap
        let upperBound = base[i + 1].endSeconds - minGap
        newBoundary = max(lowerBound, min(upperBound, newBoundary))
        edited[i].endSeconds = newBoundary
        edited[i + 1].startSeconds = newBoundary
        liveChapters = edited
        onPreviewChapters(edited)
    }

    private func commitDividerTime(dividerIndex i: Int, seconds: Double) {
        var edited = chapters
        guard i >= 0, i + 1 < edited.count else { return }
        let minGap: Double = 1.0
        let lowerBound = edited[i].startSeconds + minGap
        let upperBound = edited[i + 1].endSeconds - minGap
        let clamped = max(lowerBound, min(upperBound, seconds))
        edited[i].endSeconds = clamped
        edited[i + 1].startSeconds = clamped
        onCommitChapters(edited)
    }

    private func commitRename(chapterID: UUID) {
        defer { renamingChapterID = nil }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var edited = chapters
        guard let idx = edited.firstIndex(where: { $0.id == chapterID }) else { return }
        guard edited[idx].title != trimmed else { return }
        edited[idx].title = trimmed
        onCommitChapters(edited)
    }

    private func activeChapter() -> (index: Int, chapter: VideoChapter)? {
        let list = displayChapters
        guard !list.isEmpty else { return nil }
        let clamped = max(0, min(playheadSeconds, totalSeconds))
        for (i, c) in list.enumerated() {
            if clamped < c.endSeconds { return (i, c) }
        }
        return (list.count - 1, list[list.count - 1])
    }

    /// Compute the displayed video rect inside the container, given
    /// the source aspect ratio. Mirrors AVPlayerView's aspect-fit
    /// behavior. When ratio is unknown, the rect fills the container.
    private func videoDisplayRect(in size: CGSize) -> CGRect {
        guard let ratio = videoAspectRatio, ratio > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let containerRatio = size.width / max(1, size.height)
        if containerRatio > ratio {
            let h = size.height
            let w = h * ratio
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
        } else {
            let w = size.width
            let h = w / ratio
            return CGRect(x: 0, y: (size.height - h) / 2, width: w, height: h)
        }
    }

    // MARK: - Time formatting (mm:ss.SSS)

    nonisolated static func formatTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = Int(total) % 60
        let millis = Int(((total - floor(total)) * 1000).rounded())
        // Carry when millis rounds up to 1000 (e.g. 1.9999).
        if millis >= 1000 {
            return String(format: "%02d:%02d.%03d", minutes, secs + 1, 0)
        }
        return String(format: "%02d:%02d.%03d", minutes, secs, millis)
    }

    nonisolated static func parseTime(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept mm:ss.SSS, mm:ss, ss, ss.SSS
        let parts = trimmed.split(separator: ":").map(String.init)
        if parts.count == 2 {
            guard let m = Int(parts[0]), let s = Double(parts[1]), m >= 0, s >= 0 else { return nil }
            return Double(m) * 60 + s
        } else if parts.count == 1 {
            return Double(parts[0])
        }
        return nil
    }

    private func formatTime(_ seconds: Double) -> String {
        Self.formatTime(seconds)
    }
}

// MARK: - Popover for divider time input

private struct DividerTimeInputPopover: View {
    @State private var text: String
    let minSeconds: Double
    let maxSeconds: Double
    let onCancel: () -> Void
    let onSubmit: (Double) -> Void
    @State private var errorText: String? = nil

    init(
        initialText: String,
        minSeconds: Double,
        maxSeconds: Double,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (Double) -> Void
    ) {
        self._text = State(initialValue: initialText)
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("Chapter boundary")
                .font(.headline)
            TextField(L("mm:ss.SSS"), text: $text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(String(format: L("Range: %@ – %@"), ChapterBarOverlay.formatTime(minSeconds), ChapterBarOverlay.formatTime(maxSeconds)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(action: onCancel) { T("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: commit) { T("Apply") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func commit() {
        guard let parsed = ChapterBarOverlay.parseTime(text) else {
            errorText = "Format: mm:ss.SSS"
            return
        }
        let clamped = max(minSeconds, min(maxSeconds, parsed))
        onSubmit(clamped)
    }
}
