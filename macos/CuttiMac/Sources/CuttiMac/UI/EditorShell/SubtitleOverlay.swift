import SwiftUI
import CuttiKit

/// Renders a styled subtitle cue over the player, optionally with direct
/// manipulation: click to select, drag to move, corner handle to resize,
/// double-click to edit the cue text in place.
///
/// Layout mirrors the burn-in renderer (`SubtitleBurnInRenderer`) so the
/// viewer is WYSIWYG with the final export.
struct SubtitleOverlay: View {
    let text: String
    /// Per-run style overrides for the cue. Nil renders the text as a
    /// single uniform line (pre-rich-text behavior). When present,
    /// `runs` MUST satisfy `runs.map(\.text).joined() == text` — the
    /// helper falls back to uniform rendering if they drift.
    var runs: [SubtitleRun]? = nil
    @Binding var style: SubtitleStyle
    /// Video width / video height. When nil, the overlay fills the container.
    let videoAspectRatio: CGFloat?
    /// Inset of the player view from the container edges.
    let containerInset: CGFloat
    /// Selection toggled by clicking the overlay. When false, interactions
    /// are disabled and the chrome is hidden.
    @Binding var isSelected: Bool
    /// ID of the cue currently rendered inside the overlay (resolved by
    /// the parent at the playhead). Plumbed in so single-tap can scope
    /// per-cue style edits to *this* cue. Optional because some
    /// non-cue overlay paths (e.g. preview without a backing
    /// SubtitleEntry) don't have a stable identity yet.
    var cueID: UUID? = nil
    /// Called when the user single-taps the overlay to select it. The
    /// payload is `cueID` so the parent can route per-cue selection
    /// (e.g. set `selectedSubtitleID`) at the tap source — instead of
    /// inferring from a Bool toggle later.
    var onSelect: ((UUID?) -> Void)? = nil
    /// Called when the user commits an edit via double-click → TextField.
    /// `nil` disables inline editing.
    var onCommitText: ((String) -> Void)? = nil
    /// Called the moment the user double-clicks to enter edit mode.
    /// Owner should pause playback and pin the current cue so the
    /// overlay stays mounted for the duration of the edit.
    var onBeginEditing: (() -> Void)? = nil
    /// Called when the user leaves edit mode (commit OR cancel). Owner
    /// should unpin the cue and let the overlay resume tracking the
    /// playhead.
    var onEndEditing: (() -> Void)? = nil
    /// Optional per-cue speaker color. When set, a small colored dot is
    /// shown leading the subtitle text so users can visually verify
    /// diarization without losing their custom text color.
    var speakerColor: Color? = nil
    /// Optional speaker label ("Speaker 1", "Host", …) shown next to the
    /// dot. When nil, only the dot is shown. When both are nil, no badge.
    var speakerLabel: String? = nil
    /// Point size for the speaker label at scale 1.0. Nil ⇒ default
    /// (`speakerBadgeDefaultSize`). Callers can override per-speaker.
    var speakerLabelSize: Double? = nil
    /// Optional translated line for bilingual rendering. When both
    /// `secondaryText` and `style.bilingual` are present, the overlay
    /// renders the translation on a second line per the style's
    /// placement / size-ratio config. Nil falls back to single-line
    /// rendering (monolingual path).
    var secondaryText: String? = nil
    /// Bilingual variant of the inline editor. When non-nil AND the
    /// active `style.bilingual` carries a usable secondary locale at
    /// the moment editing starts, the overlay renders TWO stacked
    /// `TextField`s (primary then secondary, regardless of
    /// `bilingual.placement` — edit-mode uses a fixed source-on-top
    /// layout) and routes the commit here. The locale captured at
    /// edit-start is forwarded so a mid-edit style change can't move
    /// the write to a different locale.
    var onCommitBilingualText: ((String, String, String) -> Void)? = nil

    @State private var dragStartStyle: SubtitleStyle?
    @State private var resizeStartMaxWidth: Double?
    @State private var resizeStartPadV: Double?
    @State private var isEditing: Bool = false
    // Bumped each time editing begins so the TextField gets a fresh
    // identity. Without this SwiftUI reuses the same TextField (and
    // its AppKit field editor) across cues, which deadlocks IMK on
    // the second focus attempt.
    @State private var editSession: Int = 0
    @State private var draftText: String = ""
    @State private var draftSecondaryText: String = ""
    /// Locale snapshot taken at `beginEditing()`. Non-nil ⇒ render the
    /// two-field bilingual editor; commit routes through
    /// `onCommitBilingualText` keyed by THIS locale, not by whatever
    /// the live style happens to be at commit time.
    @State private var editingSecondaryLocale: String?
    private enum EditorFocus: Hashable { case primary, secondary }
    @FocusState private var editorFocus: EditorFocus?

    private static let dragSpace = "SubtitleOverlayDragSpace"

    var body: some View {
        GeometryReader { geo in
            let videoRect = videoDisplayRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                // Transparent catch-layer: any click in the overlay area that
                // misses the subtitle box deselects. Sits BELOW the subtitle
                // so the subtitle's own gestures still win when it's hit.
                if isSelected {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isSelected = false
                            onSelect?(nil)
                        }
                }

                overlay(in: videoRect)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.dragSpace)
            .onChange(of: isSelected) { _, newValue in
                print("📝 SubtitleOverlay isSelected → \(newValue) (isEditing=\(isEditing))")
                // Clicking outside clears selection. If we were editing,
                // commit the draft so changes aren't lost on focus-out.
                if !newValue && isEditing {
                    commitEditing()
                }
            }
        }
    }

    // MARK: - Composition

    private func overlay(in videoRect: CGRect) -> some View {
        let scale = max(0.3, videoRect.height / 1080.0)
        let fontSize = max(10, CGFloat(style.fontSizePoints) * scale)
        let padH = CGFloat(style.backgroundPaddingHorizontal) * scale
        let padV = CGFloat(style.backgroundPaddingVertical) * scale
        let corner = CGFloat(style.cornerRadius) * scale
        let maxWidth = max(40, videoRect.width * CGFloat(style.maxWidthFraction))
        let hFrac = clamp(style.horizontalPositionFraction)
        let vFrac = clamp(style.verticalPositionFraction)
        let centerX = videoRect.minX + CGFloat(hFrac) * videoRect.width
        let centerY = videoRect.minY + CGFloat(vFrac) * videoRect.height

        return subtitleBox(fontSize: fontSize, padH: padH, padV: padV, corner: corner, maxWidth: maxWidth, scale: scale)
            .overlay(alignment: .topLeading) {
                if isSelected && !isEditing {
                    RoundedRectangle(cornerRadius: corner)
                        .strokeBorder(EditorShellStyle.accentSolid, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected && !isEditing {
                    resizeHandle(videoRect: videoRect)
                }
            }
            .contentShape(Rectangle())
            // Double-click first so SwiftUI prefers it over the single-click.
            .onTapGesture(count: 2) {
                if onCommitText != nil {
                    beginEditing()
                }
            }
            .onTapGesture(count: 1) {
                if !isEditing {
                    isSelected = true
                    onSelect?(cueID)
                }
            }
            // Parent uses a normal `.gesture` so the child resize handle's
            // `.highPriorityGesture` can preempt it. Reversing these (parent
            // highPriority + child highPriority) lets the parent win and
            // you can't grab the handle.
            .gesture(moveGesture(videoRect: videoRect), including: isEditing ? .subviews : .all)
            .position(x: centerX, y: centerY)
    }

    @ViewBuilder
    private func subtitleBox(fontSize: CGFloat, padH: CGFloat, padV: CGFloat,
                             corner: CGFloat, maxWidth: CGFloat, scale: CGFloat) -> some View {
        if isEditing {
            if let bilingual = style.bilingual, editingSecondaryLocale != nil {
                // Bilingual edit: two stacked TextFields. Primary on top
                // regardless of `bilingual.placement` — the user picked
                // a fixed source-on-top layout for the editor so the
                // labels don't visually swap mid-edit.
                let secondaryFontSize = max(10, fontSize * CGFloat(bilingual.clampedSecondarySizeRatio))
                let spacing = max(0, fontSize * CGFloat(bilingual.clampedLineSpacingFraction))
                VStack(spacing: spacing) {
                    TextField(L("Subtitle"), text: $draftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(color(style.textColor))
                        .multilineTextAlignment(textAlignment)
                        .lineLimit(1...3)
                        .focused($editorFocus, equals: .primary)
                        .onSubmit { commitEditing() }
                        .onExitCommand { cancelEditing() }
                    TextField(L("Translation"), text: $draftSecondaryText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: secondaryFontSize, weight: .semibold))
                        .foregroundStyle(color(style.textColor))
                        .multilineTextAlignment(textAlignment)
                        .lineLimit(1...3)
                        .focused($editorFocus, equals: .secondary)
                        .onSubmit { commitEditing() }
                        .onExitCommand { cancelEditing() }
                }
                .padding(.horizontal, padH)
                .padding(.vertical, padV)
                .background(color(style.backgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: corner)
                        .strokeBorder(EditorShellStyle.accentSolid, lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .frame(maxWidth: maxWidth)
                .id(editSession)
                .onAppear { print("📝 BilingualTextField onAppear session=\(editSession)") }
                .onDisappear { print("📝 BilingualTextField onDisappear session=\(editSession)") }
            } else {
                TextField(L("Subtitle"), text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(color(style.textColor))
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(1...4)
                    .focused($editorFocus, equals: .primary)
                    .onSubmit { commitEditing() }
                    .onExitCommand { cancelEditing() }
                    .padding(.horizontal, padH)
                    .padding(.vertical, padV)
                    .background(color(style.backgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner)
                            .strokeBorder(EditorShellStyle.accentSolid, lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                    .frame(maxWidth: maxWidth)
                    .id(editSession)
                    .onAppear { print("📝 TextField onAppear session=\(editSession)") }
                    .onDisappear { print("📝 TextField onDisappear session=\(editSession)") }
                    .onChange(of: editorFocus) { _, v in
                        print("📝 editorFocus changed → \(String(describing: v))")
                    }
            }
        } else if let secondary = resolvedSecondaryText,
                  let bilingual = style.bilingual {
            // Bilingual path: two stacked lines, primary at full style
            // and secondary scaled by `bilingual.clampedSecondarySizeRatio`.
            // Layout mirrors `SubtitleBurnInRenderer.renderBilingual` so
            // preview and burn-in match pixel-for-pixel.
            let secondaryFontSize = max(8, fontSize * CGFloat(bilingual.clampedSecondarySizeRatio))
            let spacing = max(0, fontSize * CGFloat(bilingual.clampedLineSpacingFraction))
            VStack(spacing: spacing) {
                let primaryLine = Text(primaryAttributedString(fontSize: fontSize))
                    .foregroundStyle(color(style.textColor))
                let secondaryLine = Text(secondary)
                    .font(.system(size: secondaryFontSize, weight: .semibold))
                    .foregroundStyle(color(style.textColor))
                switch bilingual.placement {
                case .below:
                    primaryLine
                    secondaryLine
                case .above:
                    secondaryLine
                    primaryLine
                }
            }
            .multilineTextAlignment(textAlignment)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(
                color: color(style.shadowColor),
                radius: max(0, CGFloat(style.shadowBlurRadius) * scale),
                x: 0,
                y: CGFloat(style.shadowOffsetY) * scale
            )
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .background(color(style.backgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .frame(maxWidth: maxWidth)
        } else {
            Text(primaryAttributedString(fontSize: fontSize))
                .foregroundStyle(color(style.textColor))
                .multilineTextAlignment(textAlignment)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(
                    color: color(style.shadowColor),
                    radius: max(0, CGFloat(style.shadowBlurRadius) * scale),
                    x: 0,
                    y: CGFloat(style.shadowOffsetY) * scale
                )
                .padding(.horizontal, padH)
                .padding(.vertical, padV)
                .background(color(style.backgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .frame(maxWidth: maxWidth)
        }
    }

    /// Trim whitespace and return nil for empty strings so the bilingual
    /// branch cleanly falls back to single-line rendering on cues that
    /// don't carry a translation yet.
    private var resolvedSecondaryText: String? {
        guard let s = secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        return s
    }

    // MARK: - Speaker badge

    /// Default label point size (at scale 1.0) when no per-speaker
    /// override is set. Bumped from the old 11 so first-time users
    /// see a legible name tag without having to tune anything.
    fileprivate static let speakerBadgeDefaultSize: CGFloat = 25

    @ViewBuilder
    private func speakerBadge(scale: CGFloat) -> some View {
        if let color = speakerColor {
            let base = CGFloat(speakerLabelSize ?? Double(Self.speakerBadgeDefaultSize))
            // Dot area and padding grow proportionally so the badge
            // keeps its pill shape regardless of label size.
            let dotSize = max(6, base * 8 / Self.speakerBadgeDefaultSize) * scale
            let hPad = max(4, base * 6 / Self.speakerBadgeDefaultSize) * scale
            let vPad = max(2, base * 2 / Self.speakerBadgeDefaultSize) * scale
            HStack(spacing: 4 * scale) {
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                if let label = speakerLabel, !label.isEmpty {
                    Text(label)
                        .font(.system(size: max(9, base * scale), weight: .semibold))
                        .foregroundStyle(color)
                }
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(
                Capsule().fill(Color.black.opacity(0.55))
            )
        } else {
            EmptyView()
        }
    }

    // MARK: - Handle

    private func resizeHandle(videoRect: CGRect) -> some View {
        ZStack {
            // Invisible larger hit target so the 14pt dot is easy to grab.
            Color.clear
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            Circle()
                .fill(EditorShellStyle.accentSolid)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .frame(width: 14, height: 14)
        }
        .offset(x: 10, y: 10)
        // highPriorityGesture wins over the parent's move gesture.
        .highPriorityGesture(resizeGesture(videoRect: videoRect))
        .help(L("Drag to resize width"))
    }

    // MARK: - Gestures

    private func moveGesture(videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                guard isSelected, !isEditing else { return }
                if dragStartStyle == nil { dragStartStyle = style }
                guard let start = dragStartStyle,
                      videoRect.width > 0, videoRect.height > 0 else { return }
                let dxFrac = value.translation.width / videoRect.width
                let dyFrac = value.translation.height / videoRect.height
                style.horizontalPositionFraction = clamp(start.horizontalPositionFraction + Double(dxFrac))
                style.verticalPositionFraction = clamp(start.verticalPositionFraction + Double(dyFrac))
                style.presetID = nil
            }
            .onEnded { _ in dragStartStyle = nil }
    }

    private func resizeGesture(videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                if resizeStartMaxWidth == nil { resizeStartMaxWidth = style.maxWidthFraction }
                if resizeStartPadV == nil { resizeStartPadV = style.backgroundPaddingVertical }
                guard let startWidth = resizeStartMaxWidth,
                      let startPad = resizeStartPadV,
                      videoRect.width > 0, videoRect.height > 0 else { return }
                // Horizontal → width fraction of the video.
                let widthFracDelta = Double(value.translation.width) / Double(videoRect.width)
                style.maxWidthFraction = max(0.1, min(1.0, startWidth + widthFracDelta))
                // Vertical → background vertical padding (box height). Font size
                // is intentionally not changed here; use the style panel for that.
                let scale = max(0.3, videoRect.height / 1080.0)
                let padDelta = Double(value.translation.height) / Double(scale) / 2.0
                style.backgroundPaddingVertical = max(0, min(200, startPad + padDelta))
                style.presetID = nil
            }
            .onEnded { _ in
                resizeStartMaxWidth = nil
                resizeStartPadV = nil
            }
    }

    // MARK: - Editing

    private func beginEditing() {
        print("📝 SubtitleOverlay.beginEditing start text=\"\(text.prefix(30))\"")
        draftText = text
        // Capture the bilingual locale at edit-start so a mid-edit
        // style toggle can't redirect the write to a different locale
        // (or drop it entirely).
        if onCommitBilingualText != nil, let bilingual = style.bilingual {
            let normalized = BilingualDisplayOptions.normalizeLocale(bilingual.secondaryLocale)
            if !normalized.isEmpty {
                editingSecondaryLocale = normalized
                draftSecondaryText = secondaryText ?? ""
            } else {
                editingSecondaryLocale = nil
                draftSecondaryText = ""
            }
        } else {
            editingSecondaryLocale = nil
            draftSecondaryText = ""
        }
        editSession &+= 1
        isEditing = true
        isSelected = true
        onSelect?(cueID)
        onBeginEditing?()
        print("📝 SubtitleOverlay.beginEditing isEditing=true session=\(editSession) bilingualLocale=\(editingSecondaryLocale ?? "<none>")")
        // Drop any lingering first responder so AppKit's field editor
        // is fully released before the new TextField asks for focus.
        if let window = NSApp.keyWindow, window.firstResponder !== window {
            print("📝 SubtitleOverlay.beginEditing about to resign firstResponder=\(type(of: window.firstResponder!))")
            window.makeFirstResponder(nil)
            print("📝 SubtitleOverlay.beginEditing resigned ok")
        } else {
            print("📝 SubtitleOverlay.beginEditing no firstResponder to resign")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            print("📝 SubtitleOverlay.beginEditing about to set editorFocus=.primary (current=\(String(describing: editorFocus)))")
            editorFocus = .primary
            print("📝 SubtitleOverlay.beginEditing assigned editorFocus=.primary")
        }
        print("📝 SubtitleOverlay.beginEditing done")
    }

    private func commitEditing() {
        print("📝 SubtitleOverlay.commitEditing start")
        let trimmedPrimary = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrimary.isEmpty {
            if let locale = editingSecondaryLocale,
               let onCommitBilingualText {
                let trimmedSecondary = draftSecondaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                onCommitBilingualText(trimmedPrimary, trimmedSecondary, locale)
            } else if let onCommitText {
                onCommitText(trimmedPrimary)
            }
        }
        isEditing = false
        editorFocus = nil
        editingSecondaryLocale = nil
        draftSecondaryText = ""
        onEndEditing?()
        print("📝 SubtitleOverlay.commitEditing done")
    }

    private func cancelEditing() {
        print("📝 SubtitleOverlay.cancelEditing")
        isEditing = false
        editorFocus = nil
        editingSecondaryLocale = nil
        draftSecondaryText = ""
        onEndEditing?()
    }

    // MARK: - Helpers

    private func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

    private func color(_ c: SubtitleStyle.RGBAColor) -> Color {
        Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    /// Builds the `AttributedString` used for the primary subtitle line.
    /// When `runs` is nil (or drifted) this is a uniform string that
    /// renders identically to the old `Text(text)` path — cue-level
    /// `.foregroundStyle(color(style.textColor))` is still applied on
    /// top, so color overrides on specific runs survive as long as they
    /// set `.foregroundColor` in the NSAttributedString (which wins
    /// over the outer foregroundStyle in SwiftUI for that range).
    private func primaryAttributedString(fontSize: CGFloat) -> AttributedString {
        let baseColor = NSColor(
            srgbRed: style.textColor.red,
            green: style.textColor.green,
            blue: style.textColor.blue,
            alpha: style.textColor.alpha
        )
        return makeSubtitleAttributedString(
            text: text,
            runs: runs,
            baseFontSize: fontSize,
            baseColor: baseColor,
            baseWeight: .bold
        )
    }

    private var textAlignment: TextAlignment {
        switch style.alignment {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    /// Compute the rect actually occupied by the video (aspect-fit) inside
    /// the container, after removing `containerInset` on each side.
    private func videoDisplayRect(in containerSize: CGSize) -> CGRect {
        let available = CGRect(
            x: containerInset,
            y: containerInset,
            width: max(0, containerSize.width - containerInset * 2),
            height: max(0, containerSize.height - containerInset * 2)
        )
        guard let aspect = videoAspectRatio, aspect > 0,
              available.width > 0, available.height > 0 else {
            return available
        }
        let containerAspect = available.width / available.height
        if aspect > containerAspect {
            let h = available.width / aspect
            let y = available.minY + (available.height - h) / 2
            return CGRect(x: available.minX, y: y, width: available.width, height: h)
        } else {
            let w = available.height * aspect
            let x = available.minX + (available.width - w) / 2
            return CGRect(x: x, y: available.minY, width: w, height: available.height)
        }
    }
}
