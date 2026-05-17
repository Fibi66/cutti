import AVKit
import AppKit
import SwiftUI
import CuttiKit

/// Holds a weak reference to the AVPlayerView created by `PlayerView`.
/// Both viewer-focus modes (focus / fullscreen) drive the host
/// NSWindow's native fullscreen rather than spawning a separate
/// player window — see `ContentView.setViewerFocus(_:)`.
@MainActor
final class PlayerViewHandle: ObservableObject {
    weak var playerView: AVPlayerView?
    weak var player: AVPlayer?
}

/// Wraps the AppKit `AVPlayerView` for use in SwiftUI.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let handle: PlayerViewHandle

    func makeNSView(context: Context) -> FlexiblePlayerView {
        let view = FlexiblePlayerView()
        view.controlsStyle = .none
        view.player = player
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        Task { @MainActor in
            handle.playerView = view
            handle.player = player
        }
        return view
    }

    func updateNSView(_ nsView: FlexiblePlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        if handle.playerView !== nsView || handle.player !== player {
            Task { @MainActor in
                handle.playerView = nsView
                handle.player = player
            }
        }
    }
}

final class FlexiblePlayerView: AVPlayerView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

struct ViewerStage: View {
    let player: AVPlayer?
    let selectedRecord: MediaAssetRecord?
    let selectedRecordMessage: String?
    @Binding var playheadSeconds: Double
    @Binding var durationSeconds: Double
    @Binding var playbackRate: Double
    @Binding var isLooping: Bool
    let subtitleText: String?
    /// Per-run rich-text overrides for the active cue. Nil = uniform
    /// render (same pixels as before Phase 2). Plumbed from
    /// `MediaCoreViewModel.currentSubtitleRuns`.
    var subtitleRuns: [SubtitleRun]? = nil
    /// Translation line for bilingual rendering. Nil when the active
    /// cue has no translation for the current `SubtitleStyle.bilingual.
    /// secondaryLocale`, or when the style is monolingual — either way
    /// the overlay falls back to single-line rendering.
    var subtitleSecondaryText: String? = nil
    let showSubtitles: Bool
    @Binding var subtitleStyle: SubtitleStyle
    @Binding var subtitleSelected: Bool
    /// ID of the cue currently rendered by the overlay. Plumbed
    /// through to `SubtitleOverlay` so single-tap selection can scope
    /// per-cue style edits to the clicked cue at the tap source
    /// (instead of inferring later from a Bool state).
    var subtitleCueID: UUID? = nil
    /// Called when the user single-taps the on-canvas subtitle to
    /// enter (or leave, with `nil`) per-cue scope. Owners route this
    /// to `MediaCoreViewModel.selectedSubtitleID` so the inspector
    /// and the style binding wrapper agree on which cue is active.
    var onSelectSubtitleCue: ((UUID?) -> Void)? = nil
    var onCommitSubtitleText: ((String) -> Void)? = nil
    /// Bilingual variant of the in-place subtitle editor commit.
    /// Receives `(primaryText, secondaryText, secondaryLocale)`. The
    /// locale is the one snapshotted when editing began. Optional so
    /// callers that don't need bilingual editing can omit it.
    var onCommitSubtitleBilingualText: ((String, String, String) -> Void)? = nil
    var onBeginSubtitleEdit: (() -> Void)? = nil
    var onEndSubtitleEdit: (() -> Void)? = nil
    var subtitleSpeakerColor: Color? = nil
    var subtitleSpeakerLabel: String? = nil
    /// Override point size for the speaker badge. Nil ⇒ SubtitleOverlay
    /// default.
    var subtitleSpeakerLabelSize: Double? = nil
    /// Chapter list for the current edited timeline. Empty array → no
    /// chapter bar is shown. Times are in composed-timeline seconds.
    var chapters: [VideoChapter] = []
    /// Visual style for the chapter bar. Driven by the VM.
    var chapterBarStyle: ChapterBarStyle = .default
    /// Called during a divider drag for live preview (no persistence).
    var onPreviewChapters: ([VideoChapter]) -> Void = { _ in }
    /// Called on drag-end / time-input apply / rename commit — host
    /// should persist + push a revision.
    var onCommitChapters: ([VideoChapter]) -> Void = { _ in }
    /// Called when the user toggles anchor or applies a new style from
    /// the style sheet.
    var onChangeChapterBarStyle: (ChapterBarStyle) -> Void = { _ in }
    /// Called when the user chooses "Remove chapter bar" from the
    /// context menu. Host clears the chapter list + pushes revision.
    var onRemoveChapters: () -> Void = { }
    let onSetPlaybackRate: (Double) -> Void
    let onToggleLoop: () -> Void
    var externallyScrubbing: Bool = false

    /// Interactive PiP overlays visible at the current playhead.
    /// Each item gets a dashed selection frame + drag / resize / right-
    /// click on top of the baked PiP pixels produced by the compositor.
    var pipOverlays: [PiPOverlayHandle.Item] = []
    var selectedSegmentIDs: Set<UUID> = []
    var onSelectPiPOverlay: (UUID) -> Void = { _ in }
    var onCommitPiPGeometry: (UUID, PiPLayout.Corner, Double, Double) -> Void = { _, _, _, _ in }
    var onSetPiPShape: (UUID, PiPLayout.Shape) -> Void = { _, _ in }
    var onSnapPiPCorner: (UUID, PiPLayout.Corner) -> Void = { _, _ in }
    var onClearPiP: (UUID) -> Void = { _ in }

    /// Currently-selected overlay segment's free-transform target, if
    /// any. Drives the FreeTransformHandle layer drawn on top of the
    /// video rect. Nil → no handles rendered.
    var freeTransformTarget: FreeTransformHandle.Target? = nil
    /// Called during drag with `commit: false`, once on gesture end
    /// with `commit: true` (matches PiP handle convention so undo
    /// captures a single manipulation).
    var onUpdateFreeTransform: (UUID, FreeTransform, Bool) -> Void = { _, _, _ in }

    /// True when the host is in any immersive mode (focus or fullscreen).
    /// Drives the subtle top-right Exit affordance painted over the viewer.
    var immersiveMode: Bool = false
    /// True when the host is specifically in `.fullscreen` mode (timeline
    /// hidden too). Used to switch the focus button's icon between the
    /// "in focus" and "in fullscreen" states.
    var fullscreenMode: Bool = false
    /// Toggles focus mode on the host (panels collapsed, timeline kept).
    var onToggleImmersive: () -> Void = {}
    /// Toggles fullscreen mode on the host (panels + timeline collapsed).
    var onToggleFullscreen: () -> Void = {}

    @StateObject private var playerHandle = PlayerViewHandle()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                EditorShellStyle.stageBackground
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if subtitleSelected { subtitleSelected = false }
                    }

                if let player {
                    PlayerView(player: player, handle: playerHandle)

                    // Subtitle overlay — uses the same SubtitleStyle as burn-in
                    // so the viewer is WYSIWYG with the final export. Click to
                    // select → drag to move → corner handle to resize.
                    if showSubtitles, let text = subtitleText, !text.isEmpty {
                        SubtitleOverlay(
                            text: text,
                            runs: subtitleRuns,
                            style: $subtitleStyle,
                            videoAspectRatio: videoAspectRatio,
                            containerInset: 0,
                            isSelected: $subtitleSelected,
                            cueID: subtitleCueID,
                            onSelect: onSelectSubtitleCue,
                            onCommitText: onCommitSubtitleText,
                            onBeginEditing: onBeginSubtitleEdit,
                            onEndEditing: onEndSubtitleEdit,
                            speakerColor: subtitleSpeakerColor,
                            speakerLabel: subtitleSpeakerLabel,
                            speakerLabelSize: subtitleSpeakerLabelSize,
                            secondaryText: subtitleSecondaryText,
                            onCommitBilingualText: onCommitSubtitleBilingualText
                        )
                    }

                    // Chapter progress bar — overlay positioned over the
                    // actual video rect so it lines up with the burned-in
                    // renderer used at export time. Supports right-click
                    // position/style, draggable dividers, and inline
                    // rename.
                    if !chapters.isEmpty, durationSeconds > 0 {
                        ChapterBarOverlay(
                            chapters: chapters,
                            totalSeconds: durationSeconds,
                            playheadSeconds: playheadSeconds,
                            videoAspectRatio: videoAspectRatio,
                            style: chapterBarStyle,
                            onPreviewChapters: onPreviewChapters,
                            onCommitChapters: onCommitChapters,
                            onStyleChange: onChangeChapterBarStyle,
                            onRemoveChapters: onRemoveChapters
                        )
                    }

                    // Interactive Picture-in-Picture handles. Sit above
                    // the baked PiP pixels so click / drag / right-click
                    // routes through SwiftUI, while the rendered output
                    // stays correct for export (same compositor feeds
                    // both preview and MP4 export).
                    if !pipOverlays.isEmpty {
                        PiPOverlayHandle(
                            items: pipOverlays,
                            selectedSegmentIDs: selectedSegmentIDs,
                            videoAspectRatio: videoAspectRatio,
                            onSelect: onSelectPiPOverlay,
                            onCommitGeometry: onCommitPiPGeometry,
                            onSetShape: onSetPiPShape,
                            onSnapCorner: onSnapPiPCorner,
                            onClearPiP: onClearPiP
                        )
                    }

                    // Free-transform handles (position / scale / rotate)
                    // for the currently-selected overlay segment.
                    if let target = freeTransformTarget {
                        FreeTransformHandle(
                            target: target,
                            videoAspectRatio: videoAspectRatio,
                            onUpdate: onUpdateFreeTransform
                        )
                    }

                    // Bottom-right corner fullscreen overlay was
                    // moved into ViewerTransportBar (see below).
                }

                // Immersive-mode exit affordance. Painted above the
                // player (inside the ZStack) so it stays visible in
                // fullscreen even when the transport bar is chromed
                // out. Matches the dashed PiP handle palette so it
                // doesn't dominate the frame.
                if immersiveMode {
                    Button(action: onToggleImmersive) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                            T("Exit")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
                }

                if player == nil {
                    VStack(spacing: 10) {
                        Image(systemName: selectedRecord == nil ? "film.stack" : "play.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)

                        Text(emptyTitle)
                            .font(.headline)

                        Text(emptySubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            ViewerTransportBar(
                player: player,
                fps: selectedRecord?.analysis?.nominalFPS ?? 30,
                currentTime: $playheadSeconds,
                durationSeconds: $durationSeconds,
                playbackRate: $playbackRate,
                isLooping: $isLooping,
                onSetPlaybackRate: onSetPlaybackRate,
                onToggleLoop: onToggleLoop,
                onToggleFullscreen: onToggleFullscreen,
                onToggleFocus: onToggleImmersive,
                isFocusActive: immersiveMode && !fullscreenMode,
                isFullscreenActive: fullscreenMode,
                externallyScrubbing: externallyScrubbing
            )

            programInfoStrip
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(EditorShellStyle.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: EditorShellStyle.panelRadius))
        .animation(.easeInOut(duration: 0.15), value: immersiveMode)
    }

    /// Thin uppercase strip above the viewer that echoes
    /// `Program · main_cut.v3` from `OBPreview`. Reads the selected
    /// clip's title as the "program name" (falls back to "main cut"
    /// when nothing is selected) so the strip stays informative even
    /// before the user picks a clip.
    private var programLabelStrip: some View {
        HStack(spacing: 6) {
            T("Program")
                .foregroundStyle(EditorShellStyle.obTextFaint)
            Text("·")
                .foregroundStyle(EditorShellStyle.obTextFaint)
            Text(programName)
                .foregroundStyle(EditorShellStyle.obTextDim)
        }
        .font(.system(size: 10, design: .monospaced))
        .tracking(0.6)
        .textCase(.uppercase)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(EditorShellStyle.obBorderSoft)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    /// Thin monospace strip below the transport mirroring OBPreview's
    /// `24 fps · 4K · 2h 04m` caption. All three values come from the
    /// selected record's analysis + composition duration; anything we
    /// don't know yet is rendered as an em-dash so the strip keeps a
    /// steady rhythm instead of collapsing.
    private var programInfoStrip: some View {
        HStack {
            Spacer()
            Text(programInfoLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorShellStyle.obTextFaint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(EditorShellStyle.obBorderSoft)
                .frame(height: 1),
            alignment: .top
        )
    }

    private var programName: String {
        if let record = selectedRecord {
            let title = MediaRecordPresentation.title(for: record)
            if !title.isEmpty { return title }
        }
        return "main cut"
    }

    private var programInfoLine: String {
        let fpsPart: String = {
            guard let fps = selectedRecord?.analysis?.nominalFPS, fps > 0 else { return "— fps" }
            return String(format: "%g fps", fps)
        }()

        let resolutionPart: String = {
            guard let w = selectedRecord?.analysis?.width,
                  let h = selectedRecord?.analysis?.height,
                  w > 0, h > 0 else { return "—" }
            let longSide = max(w, h)
            if longSide >= 3840 { return "4K" }
            if longSide >= 2560 { return "2K" }
            if longSide >= 1920 { return "1080p" }
            if longSide >= 1280 { return "720p" }
            return "\(w)×\(h)"
        }()

        let durationPart: String = {
            guard durationSeconds > 0 else { return "—" }
            let total = Int(durationSeconds)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            if h > 0 {
                return String(format: "%dh %02dm", h, m)
            } else if m > 0 {
                return String(format: "%dm %02ds", m, s)
            } else {
                return String(format: "%ds", s)
            }
        }()

        return "\(fpsPart) · \(resolutionPart) · \(durationPart)"
    }

    private var emptyTitle: String {
        selectedRecord == nil ? L("Import or select media") : L("Preview unavailable")
    }

    private var emptySubtitle: String {
        selectedRecordMessage ?? L("Choose a ready proxy clip to preview.")
    }

    /// Aspect ratio (w / h) of the currently selected clip, or nil if unknown.
    /// Used to size the subtitle overlay to the actual displayed video rect.
    private var videoAspectRatio: CGFloat? {
        guard let analysis = selectedRecord?.analysis,
              analysis.width > 0, analysis.height > 0 else { return nil }
        return CGFloat(analysis.width) / CGFloat(analysis.height)
    }

}
