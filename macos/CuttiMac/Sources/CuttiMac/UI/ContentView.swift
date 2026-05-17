import AppKit
import AVFoundation
import SwiftUI
import CuttiKit

struct ContentView: View {
    @StateObject private var viewModel: MediaCoreViewModel
    @State private var searchQuery = ""
    @State private var playheadSeconds: Double = 0
    @State private var isTimelineScrubbing: Bool = false
    @State private var durationSeconds: Double = 0
    @State private var exportFormat: ExportFormat = .mp4
    @State private var internalShowExportSettings: Bool = false
    private var externalShowExportSettings: Binding<Bool>?
    private var showExportSettings: Binding<Bool> {
        externalShowExportSettings ?? $internalShowExportSettings
    }
    @State private var chatInputText = ""
    @State private var autosaveTickCounter: Int = 0
    @State private var bottomPaneTab: BottomPaneTab = .timeline
    @State private var showAgentTrace: Bool = false
    /// Viewer-focus mode. `.off` = normal editor. `.focus` hides the
    /// chat + inspector columns, BGM lane, and pane tab bar but keeps
    /// the timeline / transcript dock visible. `.fullscreen` does
    /// everything `.focus` does AND collapses the bottom pane so only
    /// the viewer (with subtitles + chapter overlays) remains. Both
    /// drive the NSWindow into macOS native fullscreen.
    enum ViewerFocusMode { case off, focus, fullscreen }
    @State private var viewerFocus: ViewerFocusMode = .off
    /// Convenience: any non-`off` mode hides side panels and runs in
    /// the native fullscreen space.
    private var immersiveMode: Bool { viewerFocus != .off }
    /// Only fullscreen hides the bottom pane (timeline + transcript).
    private var fullscreenMode: Bool { viewerFocus == .fullscreen }
    /// Catches Esc / ⌘. / ⌘W at the NSEvent layer while immersive mode is
    /// on so exit works even when focus sits inside AVPlayerView or the
    /// timeline. SwiftUI's `.onKeyPress(.escape)` only fires when the
    /// hosting view tree has keyboard focus, which isn't reliable here.
    @StateObject private var immersiveEscHandler = ImmersiveEscHandler()
    @State private var showSFXLibrary: Bool = false
    /// When non-nil, the emphasis sheet is presented for this cue. Set
    /// by the S-lane cue context menu; cleared by the sheet's Apply /
    /// Cancel / dismissal handlers.
    @State private var emphasisCueID: UUID? = nil
    @AppStorage("rightColumn.mediaHeight") private var savedMediaHeight: Double = 260
    @AppStorage("rightColumn.aiLogHeight") private var savedAILogHeight: Double = 240
    @AppStorage("rightColumn.highlightsHeight") private var savedHighlightsHeight: Double = 220
    @AppStorage("editor.aiEditorPanelWidth") private var savedAIEditorPanelWidth: Double = 240
    @AppStorage("editor.rightPanelWidth") private var savedRightPanelWidth: Double = 260
    @AppStorage("editor.timelinePaneHeight") private var savedTimelinePaneHeight: Double = 260
    // Live drag values for the side-panel widths. We mirror AppStorage
    // but only write back on drag end to avoid per-tick UserDefaults
    // writes that were making the whole window jitter while resizing.
    @State private var aiEditorPanelWidth: Double = 240
    @State private var rightPanelWidth: Double = 260
    @State private var timelinePaneHeight: Double = 260
    /// Live drag values — mirror AppStorage but avoid writing to
    /// UserDefaults on every drag tick (that was causing the History
    /// panel to judder while resizing).
    @State private var mediaHeight: Double = 260
    @State private var aiLogHeight: Double = 240
    @State private var highlightsHeight: Double = 220
    @State private var mediaExpanded: Bool = true
    @State private var historyExpanded: Bool = true
    @State private var highlightsExpanded: Bool = true
    @State private var aiLogExpanded: Bool = true

    /// Live-measured window content height. Drives a dynamic cap on the
    /// timeline-pane divider so dragging the divider up can't squash the
    /// upper area (chat / viewer / right rail) below `minTopAreaHeight` —
    /// previously dragging the divider near max on a small monitor
    /// pushed the chat panel's header off the top of the screen.
    @State private var measuredAvailableHeight: CGFloat = 0
    /// Minimum height reserved for the upper area (left chat panel +
    /// viewer + right rail). Chosen so the chat panel header, viewer
    /// transport bar, and right-rail section headers all stay visible
    /// at the smallest sensible window size.
    private let minTopAreaHeight: CGFloat = 320
    /// Resizer thickness in `VerticalResizer`. Kept in one place so the
    /// dynamic-cap math below matches the actual hit-area height.
    private let verticalResizerHeight: CGFloat = 6

    /// Largest value the timeline-pane divider is allowed to take given
    /// the currently-measured window height. Falls back to the static
    /// `720` cap until the first layout pass populates
    /// `measuredAvailableHeight`.
    private var dynamicMaxTimelineHeight: Double {
        guard measuredAvailableHeight > 0 else { return 720 }
        let cap = Double(measuredAvailableHeight - minTopAreaHeight - verticalResizerHeight)
        return Swift.max(160, Swift.min(720, cap))
    }

    /// `timelinePaneHeight` clamped to the current dynamic cap so the
    /// upper area never compresses below its minimum even if the user
    /// saved a tall divider value on a previously-larger window.
    private var clampedTimelinePaneHeight: Double {
        Swift.min(timelinePaneHeight, dynamicMaxTimelineHeight)
    }

    /// Which expanded section should soak up the remaining vertical
    /// space in the right column. Priority: History (middle) → Media
    /// (top) → Highlights → AI Log (bottom). Whoever is expanded and
    /// highest on that list becomes flex; the rest keep their fixed
    /// user-set heights. If all four are collapsed, the column only
    /// shows headers and a Spacer absorbs the rest.
    private enum FlexSection { case media, history, highlights, aiLog, none }
    private var flexSection: FlexSection {
        if historyExpanded { return .history }
        if mediaExpanded { return .media }
        if highlightsExpanded { return .highlights }
        if aiLogExpanded { return .aiLog }
        return .none
    }
    @ViewBuilder
    private var leftPanel: some View {
        ChatPanel(
            messages: viewModel.chatMessages,
            isProcessing: viewModel.isChatProcessing,
            inputText: $chatInputText,
            onSend: { text in
                Task { await viewModel.handleAIPrompt(text) }
            },
            onAutoSendPrompt: { prompt, displayLabel in
                Task { await viewModel.handleAIPrompt(prompt, displayAs: displayLabel) }
            },
            agentMode: viewModel.agentMode,
            onSetAgentMode: { viewModel.setAgentMode($0) },
            resolveProposal: { viewModel.proposal(id: $0) },
            onApplyProposal: { viewModel.applyProposal(id: $0) },
            onRejectProposal: { viewModel.rejectProposal(id: $0) },
            canStartAnalysis: canStartAnalysis,
            isAnalyzing: viewModel.isAnalyzing,
            onStartAnalysis: {
                Task { await viewModel.analyzeSelectedRecord() }
            },
            onRunTrimPauses: {
                Task { await viewModel.trimPausesOnSelectedRecord() }
            },
            onRunTranscriptCleanup: {
                Task { await viewModel.transcriptCleanupOnSelectedRecord() }
            },
            onRunSuggestBRoll: {
                Task { await viewModel.suggestBRollOnSelectedRecord() }
            },
            onGenerateChapters: {
                Task { await viewModel.regenerateChaptersWithAI() }
            },
            onRunAutoPiP: { viewModel.applyAutoPiPToAllOverlays() },
            onShowTrace: { showAgentTrace = true },
            attachments: viewModel.chatAttachments,
            liveSegmentIDs: Set(viewModel.timelineSegments.map(\.id)),
            attachmentRecords: viewModel.records,
            attachmentProjectRoot: viewModel.projectRoot,
            onAttachSegment: { viewModel.attachSegment(id: $0) },
            onRemoveAttachment: { viewModel.removeChatAttachment(id: $0) },
            onClearAttachments: { viewModel.clearChatAttachments() },
            onGenerateImage: { [weak viewModel] prompt in
                Task { await viewModel?.generateAIImageToLibrary(prompt: prompt) }
            }
        )
        .frame(width: CGFloat(aiEditorPanelWidth))
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(EditorShellStyle.backgroundPanel)
        .clipShape(RoundedRectangle(cornerRadius: EditorShellStyle.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: EditorShellStyle.radiusLarge)
                .strokeBorder(
                    viewModel.isChatProcessing
                        ? EditorShellStyle.accentSolid.opacity(0.55)
                        : EditorShellStyle.borderSubtle,
                    lineWidth: 1
                )
        }
        .shadow(
            color: viewModel.isChatProcessing
                ? EditorShellStyle.accentSolid.opacity(0.18)
                : EditorShellStyle.shadow1Color,
            radius: viewModel.isChatProcessing ? 14 : EditorShellStyle.shadow1Radius,
            y: viewModel.isChatProcessing ? 0 : EditorShellStyle.shadow1Y
        )
        .animation(.easeInOut(duration: EditorShellStyle.transitionMedium), value: viewModel.isChatProcessing)
    }

    private var freeTransformHandleTarget: FreeTransformHandle.Target? {
        guard let t = viewModel.freeTransformTarget else { return nil }
        return FreeTransformHandle.Target(
            segmentID: t.segmentID,
            freeTransform: t.freeTransform,
            sourceAspect: t.sourceAspect
        )
    }

    @ViewBuilder
    private var centerViewer: some View {
        ViewerStage(
            player: viewModel.player,
            selectedRecord: viewModel.selectedRecord,
            selectedRecordMessage: viewModel.selectedRecordMessage,
            playheadSeconds: $playheadSeconds,
            durationSeconds: $durationSeconds,
            playbackRate: $viewModel.playbackRate,
            isLooping: $viewModel.isLooping,
            subtitleText: viewModel.currentSubtitleText(at: playheadSeconds),
            subtitleRuns: viewModel.currentSubtitleRuns(at: playheadSeconds),
            subtitleSecondaryText: viewModel.currentSubtitleSecondaryText(at: playheadSeconds),
            showSubtitles: viewModel.showSubtitles && !viewModel.subtitlesPreviewHidden,
            subtitleStyle: viewModel.subtitleStyleEffectiveBinding,
            subtitleSelected: $viewModel.isSubtitleSelected,
            subtitleCueID: viewModel.currentSubtitleID(at: playheadSeconds),
            onSelectSubtitleCue: { cueID in
                viewModel.selectedSubtitleID = cueID
            },
            onCommitSubtitleText: { newText in
                if let id = viewModel.currentSubtitleID(at: playheadSeconds) {
                    viewModel.updateSubtitleText(id: id, newText: newText)
                }
            },
            onCommitSubtitleBilingualText: { primary, secondary, locale in
                if let id = viewModel.currentSubtitleID(at: playheadSeconds) {
                    viewModel.updateSubtitleBilingualText(
                        id: id,
                        primaryText: primary,
                        secondaryText: secondary,
                        secondaryLocale: locale
                    )
                }
            },
            onBeginSubtitleEdit: {
                if let id = viewModel.currentSubtitleID(at: playheadSeconds) {
                    viewModel.beginSubtitleEditing(cueID: id)
                }
            },
            onEndSubtitleEdit: {
                viewModel.endSubtitleEditing()
            },
            subtitleSpeakerColor: viewModel.currentSubtitleSpeaker(at: playheadSeconds)?.color,
            subtitleSpeakerLabel: viewModel.currentSubtitleSpeaker(at: playheadSeconds)?.displayName,
            subtitleSpeakerLabelSize: viewModel.currentSubtitleSpeaker(at: playheadSeconds)?.labelSize,
            chapters: viewModel.currentChapters ?? [],
            chapterBarStyle: viewModel.currentChapterBarStyle,
            onPreviewChapters: { _ in
                // Live-drag preview: no persistence — overlay already
                // renders the in-flight chapter list locally.
            },
            onCommitChapters: { edited in
                viewModel.updateChapters(edited)
            },
            onChangeChapterBarStyle: { newStyle in
                viewModel.updateChapterBarStyle(newStyle)
            },
            onRemoveChapters: {
                viewModel.updateChapters([], label: "Remove chapter bar")
            },
            onSetPlaybackRate: { viewModel.setPlaybackRate($0) },
            onToggleLoop: { viewModel.toggleLoop() },
            externallyScrubbing: isTimelineScrubbing,
            pipOverlays: viewModel.activePiPOverlays(atComposedTime: playheadSeconds)
                .map { PiPOverlayHandle.Item(id: $0.segmentID, layout: $0.layout) },
            selectedSegmentIDs: viewModel.selectedSegmentIDs,
            onSelectPiPOverlay: { segID in
                viewModel.selectSegment(id: segID)
            },
            onCommitPiPGeometry: { segID, corner, inset, size in
                viewModel.setPiPGeometry(
                    segmentID: segID,
                    corner: corner,
                    insetFraction: inset,
                    sizeFraction: size
                )
            },
            onSetPiPShape: { segID, shape in
                var base = viewModel.project.overlayTracks
                    .flatMap(\.segments)
                    .first(where: { $0.id == segID })?
                    .pipLayout ?? .default
                base.shape = shape
                viewModel.setPiPLayout(segmentID: segID, layout: base)
            },
            onSnapPiPCorner: { segID, corner in
                var base = viewModel.project.overlayTracks
                    .flatMap(\.segments)
                    .first(where: { $0.id == segID })?
                    .pipLayout ?? .default
                base.corner = corner
                viewModel.setPiPLayout(segmentID: segID, layout: base)
            },
            onClearPiP: { segID in
                viewModel.setPiPLayout(segmentID: segID, layout: nil)
            },
            freeTransformTarget: freeTransformHandleTarget,
            onUpdateFreeTransform: { id, ft, commit in
                viewModel.updateFreeTransform(segmentID: id, transform: ft, commit: commit)
            },
            immersiveMode: immersiveMode,
            fullscreenMode: fullscreenMode,
            onToggleImmersive: { toggleFocusMode() },
            onToggleFullscreen: { toggleFullscreenMode() }
        )
        .overlay(alignment: .topTrailing) {
            viewerInspectorsOverlay
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.isSubtitleSelected)
        .animation(.easeInOut(duration: 0.15), value: viewModel.inspectorOverlaySegmentID)
        .animation(.easeInOut(duration: 0.15), value: viewModel.selectedOverlaySegmentID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Top-trailing floating inspectors on the viewer — either the
    /// Subtitle panel or the AI-overlay panel. Extracted from the
    /// viewer body because the outer closure was close to tripping the
    /// Swift type-checker's complexity limit.
    @ViewBuilder
    private var viewerInspectorsOverlay: some View {
        if viewModel.isSubtitleSelected && viewModel.showSubtitles {
            SubtitleInspector(
                style: viewModel.subtitleStyleEffectiveBinding,
                onClose: {
                    viewModel.isSubtitleSelected = false
                    viewModel.selectedSubtitleID = nil
                },
                scopeLabel: viewModel.selectedSubtitleID != nil
                    ? L("Editing this cue")
                    : L("Editing all cues"),
                hasCueOverride: viewModel.selectedSubtitleID
                    .map { viewModel.cueHasStyleOverride($0) } ?? false,
                onApplyToAllCues: viewModel.selectedSubtitleID != nil
                    ? { _ = viewModel.applySelectedCueStyleToAllCues() }
                    : nil,
                onResetToDefault: viewModel.selectedSubtitleID != nil
                    ? { _ = viewModel.resetSelectedCueStyleOverride() }
                    : nil
            )
            .padding(12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let segID = viewModel.inspectorOverlaySegmentID,
                  let spec = viewModel.overlaySpec(forSegmentID: segID) {
            OverlayInspector(
                spec: spec,
                isRendering: viewModel.overlaysRendering.contains(segID),
                onPatch: { patch in
                    viewModel.scheduleOverlayPropsPatch(segmentID: segID, patch: patch)
                },
                onClose: { viewModel.closeOverlayInspector() }
            )
            .padding(12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let target = viewModel.freeTransformTarget {
            FreeTransformInspector(
                segmentID: target.segmentID,
                transform: target.freeTransform,
                sourceAspect: target.sourceAspect,
                canvasAspect: previewCanvasAspect,
                onUpdate: { id, ft, commit in
                    viewModel.updateFreeTransform(segmentID: id, transform: ft, commit: commit)
                },
                onClose: { viewModel.selectedOverlaySegmentID = nil }
            )
            .padding(12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Aspect ratio (w/h) of the composed preview. Read from the
    /// primary-source record — same source the viewer uses when
    /// letterboxing the rendered output.
    private var previewCanvasAspect: CGFloat? {
        guard let rec = viewModel.selectedRecord,
              let w = rec.analysis?.width,
              let h = rec.analysis?.height,
              w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    @ViewBuilder
    private var rightPanel: some View {
        VStack(spacing: 0) {
            mediaBrowserView
            mediaDividerView
            workflowPanelView
            highlightsDividerView
            highlightsPanelView
            aiLogDividerView
            inspectorSidebarView

            if flexSection == .none {
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .frame(width: CGFloat(rightPanelWidth))
    }

    @ViewBuilder
    private var mediaBrowserView: some View {
        let section = MediaBrowserSection(
            records: viewModel.records,
            projectRoot: viewModel.projectRoot,
            selectedRecordID: $viewModel.selectedRecordID,
            searchQuery: $searchQuery,
            isExpanded: $mediaExpanded,
            importingFiles: viewModel.importingFiles,
            onSelect: { id in
                playheadSeconds = 0
                durationSeconds = 0
                viewModel.select(recordID: id)
            },
            onDelete: { id in
                viewModel.deleteRecord(id: id)
            },
            onImportURLs: { urls in
                for url in urls {
                    viewModel.startImport(url: url)
                }
            },
            onCancelImport: { id in
                viewModel.cancelImport(id: id)
            }
        )

        if flexSection == .media {
            section.frame(maxHeight: .infinity).clipped()
        } else if mediaExpanded {
            section.frame(height: CGFloat(mediaHeight)).clipped()
        } else {
            section.clipped()
        }
    }

    @ViewBuilder
    private var mediaDividerView: some View {
        if mediaExpanded && historyExpanded && flexSection != .media {
            ResizableDivider(
                value: $mediaHeight,
                minValue: 44,
                maxValue: 600,
                onCommit: { savedMediaHeight = mediaHeight }
            )
        }
    }

    @ViewBuilder
    private var workflowPanelView: some View {
        let panel = WorkflowPanel(
            revisions: viewModel.revisions,
            currentRevisionIndex: viewModel.revisions.count - 1,
            isExpanded: $historyExpanded,
            onRestore: { id in
                viewModel.restoreRevision(id: id)
            }
        )
        if flexSection == .history {
            panel.frame(maxHeight: .infinity)
        } else {
            panel
        }
    }

    @ViewBuilder
    private var highlightsDividerView: some View {
        // Sits between History (top) and Highlights (bottom). The
        // resize handle drives `highlightsHeight` so the bottom-
        // anchored section grows/shrinks against whichever flex
        // section is above it. Hidden when Highlights is the flex
        // (its height is auto) or when nothing is expanded
        // (`.none` — Spacer absorbs and the divider would have no
        // anchor section to push against).
        if highlightsExpanded && flexSection != .highlights && flexSection != .none {
            ResizableDivider(
                value: $highlightsHeight,
                minValue: 44,
                maxValue: 600,
                inverted: true,
                onCommit: { savedHighlightsHeight = highlightsHeight }
            )
        }
    }

    @ViewBuilder
    private var highlightsPanelView: some View {
        let groups = AICopilotPresentation.highlightGroups(records: viewModel.records)
        let total = AICopilotPresentation.highlightCount(records: viewModel.records)
        let panel = HighlightsPanel(
            groups: groups,
            totalCount: total,
            records: viewModel.records,
            projectRoot: viewModel.projectRoot,
            isExpanded: $highlightsExpanded,
            onSelectRecord: { id in
                playheadSeconds = 0
                durationSeconds = 0
                viewModel.select(recordID: id)
            },
            onSaveSegmentsToHighlights: { [weak viewModel] segmentIDs in
                viewModel?.saveTimelineSegmentsToHighlights(segmentIDs)
            },
            onRemoveHighlight: { [weak viewModel] row in
                viewModel?.removeHighlight(
                    recordID: row.sourceVideoID,
                    markerIndex: row.markerIndex,
                    fingerprint: row.fingerprint
                )
            },
            onUseAsHook: { [weak viewModel] row in
                viewModel?.useHighlightAsHook(row)
            },
            canUseAsHook: { [weak viewModel] row in
                viewModel?.canUseHighlightAsHook(row) ?? false
            }
        )
        if flexSection == .highlights {
            panel.frame(maxHeight: .infinity).clipped()
        } else if highlightsExpanded {
            panel.frame(height: CGFloat(highlightsHeight)).clipped()
        } else {
            panel.clipped()
        }
    }

    @ViewBuilder
    private var aiLogDividerView: some View {
        // Bottom-most divider — resizes AI Log against whichever
        // section is currently flex above it. Hidden when AI Log is
        // itself the flex (its height is auto) or when nothing is
        // expanded (no anchor section to push against). Decoupled
        // from any specific neighbour-expanded flag so collapsing
        // Highlights doesn't accidentally lock the AI Log handle.
        if aiLogExpanded && flexSection != .aiLog && flexSection != .none {
            ResizableDivider(
                value: $aiLogHeight,
                minValue: 44,
                maxValue: 600,
                inverted: true,
                onCommit: { savedAILogHeight = aiLogHeight }
            )
        }
    }

    @ViewBuilder
    private var inspectorSidebarView: some View {
        let sidebar = InspectorSidebar(
            record: viewModel.selectedRecord,
            isExpanded: $aiLogExpanded,
            onRelink: showRelinkPanel
        )
        if flexSection == .aiLog {
            sidebar.frame(maxHeight: .infinity).clipped()
        } else if aiLogExpanded {
            sidebar.frame(height: CGFloat(aiLogHeight)).clipped()
        } else {
            sidebar.clipped()
        }
    }

    enum BottomPaneTab: Hashable { case timeline, transcript }
    /// 1 Hz tick used purely to refresh the "Xs ago" portion of the autosave
    /// status label — the underlying state doesn't change between ticks.
    private let autosaveTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var autosaveStatusIcon: String {
        switch viewModel.autosaveStatus {
        case .idle: return "circle.dashed"
        case .saving: return "arrow.clockwise"
        case .saved: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    enum LeftPanelTab { case chat, media }  // retained for EditorShellSmokeTests compat
    @AppStorage(CuttiSettings.qwenSetupDismissedKey) private var qwenSetupDismissedRaw: Bool = false
    @ObservedObject private var qwenManager: QwenAsrSidecarManager = .shared

    /// Build the `TimelineCreativeActions` value passed into
    /// `TimelineDock`'s environment. Extracted out of the parent view
    /// body so the Swift type-checker doesn't time out on the large
    /// nested closure + map expressions.
    private var timelineCreativeActionsBinding: TimelineCreativeActions {
        let brollOptions: [TimelineCreativeActions.BRollOption] = viewModel.records.map {
            TimelineCreativeActions.BRollOption(id: $0.id, name: MediaRecordPresentation.title(for: $0))
        }
        let overlayRows: [TimelineCreativeActions.OverlayRow] = viewModel.project.overlayTracks.map { track in
            let segs: [TimelineCreativeActions.OverlaySegmentHint] = track.segments.map { seg in
                let mediaName = viewModel.records.first(where: { $0.id == seg.sourceVideoID })
                    .map { MediaRecordPresentation.title(for: $0) } ?? "B-roll"
                return TimelineCreativeActions.OverlaySegmentHint(
                    id: seg.id,
                    startSeconds: seg.placementOffset ?? 0,
                    durationSeconds: seg.durationSeconds,
                    mediaName: mediaName,
                    sourceVideoID: seg.sourceVideoID,
                    sourceStartSeconds: seg.range.startSeconds,
                    sourceEndSeconds: seg.range.endSeconds,
                    isVideoHidden: seg.isVideoHidden,
                    isAudioMuted: seg.volumeLevel <= 0.0001,
                    pipLayout: seg.pipLayout,
                    isAIEditable: seg.overlaySpec != nil,
                    isRendering: viewModel.overlaysRendering.contains(seg.id)
                )
            }
            return TimelineCreativeActions.OverlayRow(
                id: track.id,
                name: track.name,
                segments: segs,
                isMuted: track.isMuted,
                isLocked: track.isLocked
            )
        }
        let detachedAudioRows: [TimelineCreativeActions.DetachedAudioRow] = viewModel.project.audioTracks
            .filter { $0.name == MediaCoreViewModel.detachedAudioTrackName }
            .map { track in
                let segs: [TimelineCreativeActions.DetachedAudioSegmentHint] = track.segments.map { seg in
                    let mediaName = viewModel.records.first(where: { $0.id == seg.sourceVideoID })
                        .map { MediaRecordPresentation.title(for: $0) } ?? "Audio"
                    return TimelineCreativeActions.DetachedAudioSegmentHint(
                        id: seg.id,
                        startSeconds: seg.placementOffset ?? 0,
                        durationSeconds: seg.durationSeconds,
                        mediaName: mediaName,
                        sourceVideoID: seg.sourceVideoID,
                        sourceStartSeconds: seg.range.startSeconds,
                        sourceEndSeconds: seg.range.endSeconds,
                        linkedV1ID: seg.linkedSegmentID
                    )
                }
                return TimelineCreativeActions.DetachedAudioRow(
                    id: track.id,
                    name: track.name,
                    segments: segs,
                    isMuted: track.isMuted,
                    isLocked: track.isLocked
                )
            }
        let markers: [TimelineCreativeActions.MarkerHint] = viewModel.visualMarkers.map {
            TimelineCreativeActions.MarkerHint(
                composedStart: $0.composedStart,
                composedEnd: $0.composedEnd,
                kind: $0.kind
            )
        }
        return TimelineCreativeActions(
            onAddCrossfadeToNext: { [weak viewModel] idx, dur in
                viewModel?.addCrossfade(fromIndex: idx, duration: dur)
            },
            onAddCrossfadeFromPrevious: { [weak viewModel] idx, dur in
                viewModel?.addCrossfade(fromIndex: idx - 1, duration: dur)
            },
            onInsertBRoll: { [weak viewModel] mediaID, composedTime, duration in
                viewModel?.insertBRollOverlay(mediaID: mediaID, at: composedTime, duration: duration)
            },
            onInsertMediaAtPrimaryIndex: { [weak viewModel] mediaID, index in
                viewModel?.insertMediaAsPrimary(mediaID: mediaID, at: index)
            },
            onInsertSourceSliceAtPrimaryIndex: { [weak viewModel] mediaID, start, end, index in
                viewModel?.insertSourceSlice(
                    mediaID: mediaID,
                    sourceStart: start,
                    sourceEnd: end,
                    at: index
                )
            },
            onSaveSegmentToHighlights: { [weak viewModel] segmentID in
                viewModel?.saveTimelineSegmentsToHighlights([segmentID])
            },
            canSaveSegmentToHighlights: { [weak viewModel] segmentID in
                viewModel?.canSaveSegmentToHighlights(segmentID: segmentID) ?? false
            },
            onInsertMediaIntoOverlayTrack: { [weak viewModel] mediaID, trackID, composedStart in
                viewModel?.insertMediaIntoOverlayTrack(mediaID: mediaID, trackID: trackID, composedStart: composedStart)
            },
            onMoveOverlaySegment: { [weak viewModel] segmentID, composedStart in
                viewModel?.setOverlayPlacementOffset(segmentID: segmentID, composedStart: composedStart)
            },
            onTrimOverlaySegment: { [weak viewModel] segmentID, edge, composedEdgeTime in
                let vmEdge: MediaCoreViewModel.OverlayTrimEdge = (edge == .leading) ? .leading : .trailing
                viewModel?.trimOverlaySegment(segmentID: segmentID, edge: vmEdge, composedEdgeTime: composedEdgeTime)
            },
            onRemoveOverlaySegment: { [weak viewModel] segmentID in
                viewModel?.removeOverlaySegment(segmentID: segmentID)
            },
            onToggleSegmentVideoHidden: { [weak viewModel] segmentID in
                guard let viewModel else { return }
                // Flip based on current state — the hint struct's
                // `isVideoHidden` reflects the last composed project,
                // so look it up authoritatively on the view model.
                let currentlyHidden: Bool
                if let seg = viewModel.timelineSegments.first(where: { $0.id == segmentID }) {
                    currentlyHidden = seg.isVideoHidden
                } else {
                    currentlyHidden = viewModel.project.overlayTracks
                        .flatMap { $0.segments }
                        .first(where: { $0.id == segmentID })?.isVideoHidden ?? false
                }
                viewModel.setSegmentVideoHidden(segmentID: segmentID, hidden: !currentlyHidden)
            },
            onToggleSegmentAudioMuted: { [weak viewModel] segmentID in
                viewModel?.toggleSegmentAudioMuted(segmentID: segmentID)
            },
            onSwapAlternativeTake: { [weak viewModel] segmentID, takeID in
                viewModel?.swapAlternativeTake(segmentID: segmentID, takeID: takeID)
            },
            onRefreshVisualMarkers: { [weak viewModel] in
                viewModel?.refreshVisualMarkers()
            },
            onDismissBRollSuggestion: { [weak viewModel] id in
                viewModel?.dismissBRollSuggestion(id: id)
            },
            onGenerateBRollSuggestion: { [weak viewModel] hint, editedPrompt in
                viewModel?.generateOverlayFromSuggestion(hint, editedPrompt: editedPrompt)
            },
            onDetachAudio: { [weak viewModel] segmentID in
                viewModel?.detachAudio(segmentID: segmentID)
            },
            onReattachAudio: { [weak viewModel] segmentID in
                viewModel?.reattachAudio(segmentID: segmentID)
            },
            onDeleteDetachedAudio: { [weak viewModel] segmentID in
                viewModel?.deleteAuxAudioSegment(id: segmentID)
            },
            onSetPiPLayout: { [weak viewModel] segmentID, layout in
                viewModel?.setPiPLayout(segmentID: segmentID, layout: layout)
            },
            onAutoPiP: { [weak viewModel] segmentID in
                viewModel?.applyAutoPiP(segmentID: segmentID)
            },
            onOpenOverlayInspector: { [weak viewModel] segmentID in
                viewModel?.inspectorOverlaySegmentID = segmentID
            },
            onRestoreCutBefore: { [weak viewModel] index in
                guard let viewModel else { return }
                viewModel.restoreCutBetween(leftIndex: index - 1, rightIndex: index)
            },
            onRestoreCutAfter: { [weak viewModel] index in
                guard let viewModel else { return }
                viewModel.restoreCutBetween(leftIndex: index, rightIndex: index + 1)
            },
            restorableGapBefore: { [weak viewModel] index in
                viewModel?.gapBeforeSegment(at: index)
            },
            restorableGapAfter: { [weak viewModel] index in
                viewModel?.gapAfterSegment(at: index)
            },
            availableBRollMedia: brollOptions,
            overlayRows: overlayRows,
            detachedAudioRows: detachedAudioRows,
            markers: markers,
            bRollSuggestions: viewModel.bRollSuggestionHints.map {
                TimelineCreativeActions.BRollSuggestionHint(
                    id: $0.id,
                    composedSeconds: $0.composedSeconds,
                    anchorDurationSeconds: $0.anchorDurationSeconds,
                    kind: $0.kind,
                    prompt: $0.prompt,
                    rationale: $0.rationale,
                    userTitle: $0.userTitle,
                    agentHint: $0.agentHint,
                    sectionRole: $0.sectionRole
                )
            },
            isRefreshingMarkers: viewModel.isLoadingVisualMarkers,
            isEnabled: viewModel.canExport,
            primaryVideoTrackID: viewModel.project.tracks.first(where: { $0.kind == .video })?.id,
            primaryVideoMuted: viewModel.project.tracks.first(where: { $0.kind == .video })?.isMuted ?? false,
            primaryVideoLocked: viewModel.project.tracks.first(where: { $0.kind == .video })?.isLocked ?? false,
            subtitlesVisible: !viewModel.subtitlesPreviewHidden,
            onToggleTrackMute: { [weak viewModel] trackID in
                viewModel?.toggleTrackMute(id: trackID)
            },
            onToggleTrackLocked: { [weak viewModel] trackID in
                viewModel?.toggleTrackLocked(id: trackID)
            },
            onToggleSubtitlesVisibility: { [weak viewModel] in
                viewModel?.subtitlesPreviewHidden.toggle()
            }
        )
    }

    init(viewModel: MediaCoreViewModel? = nil, showExportSettings: Binding<Bool>? = nil) {
        if let viewModel {
            _viewModel = StateObject(wrappedValue: viewModel)
        } else {
            _viewModel = StateObject(
                wrappedValue: MediaCoreViewModel(
                    playbackCore: AVPlaybackCore(),
                    overlayRenderer: Self.makeDefaultOverlayRenderer()
                )
            )
        }
        self.externalShowExportSettings = showExportSettings
        // Seed the live drag heights from AppStorage so resize state
        // survives relaunch but drags don't touch UserDefaults per tick.
        let defaults = UserDefaults.standard
        let initialMedia = defaults.object(forKey: "rightColumn.mediaHeight") as? Double ?? 260
        let initialAILog = defaults.object(forKey: "rightColumn.aiLogHeight") as? Double ?? 240
        let initialHighlights = defaults.object(forKey: "rightColumn.highlightsHeight") as? Double ?? 220
        _mediaHeight = State(initialValue: initialMedia)
        _aiLogHeight = State(initialValue: initialAILog)
        _highlightsHeight = State(initialValue: initialHighlights)
    }

    /// Prefer the relay-backed `CloudRemotionRenderer` when we have
    /// credentials; otherwise use the local dev renderer. Returns `nil`
    /// for BYOK users (they opted out of all backend usage). Delegates
    /// to `AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer` so the
    /// dashboard-launched project path and this standalone initializer
    /// share the exact same provider-aware selection logic.
    private static func makeDefaultOverlayRenderer() -> (any RemotionOverlayRendering)? {
        AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Activity indicators are now surfaced inline with the
            // operation they describe: the Media section header shows
            // importing, the AI chat shows analysis progress, and the
            // bottom-right floating card shows export progress. We no
            // longer stack a global "Working…" strip at the top of the
            // shell.

            // Autosave status banner removed — everyday users don't need
            // to see "Not saved yet" / "Saved · Xs ago". The Cmd-S save
            // shortcut is preserved via a hidden stub button below.
            Button {
                viewModel.createManualCheckpoint()
            } label: { T("Save") }
            .keyboardShortcut("s", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)

            if let bannerMessage = viewModel.bannerMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(bannerMessage)
                    Spacer()
                }
                .padding(.horizontal, EditorShellStyle.panelPadding)
                .padding(.vertical, 10)
                .background(EditorShellStyle.warningBackground)
                .foregroundStyle(.white)
            }

            if let suggestion = viewModel.pipSuggestions.first {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                    T("Looks like a presenter cam — apply Picture-in-Picture?")
                        .font(.system(size: 12, weight: .medium))
                    Text("(\(Int(suggestion.confidence * 100))%)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Button {
                        viewModel.applyPiPSuggestion(id: suggestion.id)
                    } label: { T("Apply") }
                    .controlSize(.small)
                    Button {
                        viewModel.dismissPiPSuggestion(id: suggestion.id)
                    } label: { T("Dismiss") }
                    .controlSize(.small)
                }
                .padding(.horizontal, EditorShellStyle.panelPadding)
                .padding(.vertical, 8)
                .background(EditorShellStyle.accentSolid.opacity(0.9))
                .foregroundStyle(.white)
            }

            HStack(alignment: .top, spacing: 8) {
                if !immersiveMode {
                    leftPanel
                    PanelResizer(
                        width: $aiEditorPanelWidth,
                        min: 200,
                        max: 520,
                        onCommit: { savedAIEditorPanelWidth = $0 }
                    )
                }
                centerViewer
                if !immersiveMode {
                    PanelResizer(
                        width: $rightPanelWidth,
                        min: 220,
                        max: 560,
                        reversed: true,
                        onCommit: { savedRightPanelWidth = $0 }
                    )
                    rightPanel
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .onAppear {
                aiEditorPanelWidth = savedAIEditorPanelWidth
                rightPanelWidth = savedRightPanelWidth
                timelinePaneHeight = savedTimelinePaneHeight
            }

            if !immersiveMode {
                VerticalResizer(
                    height: $timelinePaneHeight,
                    min: 160,
                    max: dynamicMaxTimelineHeight,
                    onCommit: { savedTimelinePaneHeight = Swift.min($0, dynamicMaxTimelineHeight) }
                )
            }

            VStack(spacing: 0) {
                if !immersiveMode {
                    BGMLaneBar(
                        tracks: viewModel.project.audioTracks
                            .filter { $0.name != MediaCoreViewModel.detachedAudioTrackName },
                        onVolumeChange: { id, vol in viewModel.setAuxTrackVolume(id: id, volume: vol) },
                        onToggleMute: { id in viewModel.toggleTrackMute(id: id) },
                        onRemove: { id in viewModel.removeTrack(id: id) }
                    )

                    bottomPaneTabBar
                }

            if !fullscreenMode {
            if bottomPaneTab == .transcript {
                TranscriptView(
                    cues: viewModel.composedSubtitles,
                    tombstones: viewModel.subtitleTombstones,
                    speakers: viewModel.speakers,
                    playheadSeconds: playheadSeconds,
                    onSeek: { seconds in
                        viewModel.player?.seek(
                            to: CMTime(seconds: seconds, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    },
                    onEditCue: { id, newText in
                        viewModel.updateSubtitleText(id: id, newText: newText)
                    },
                    onDeleteCues: { ids in
                        viewModel.deleteSubtitleCues(ids: ids)
                    },
                    onRestoreTombstone: { id in
                        viewModel.restoreSubtitleTombstone(id: id)
                    },
                    onReplace: { find, replace, caseSensitive in
                        viewModel.replaceSubtitleText(find: find, replace: replace, caseSensitive: caseSensitive)
                    },
                    onRenameSpeaker: { id, newName in
                        viewModel.renameSpeaker(id: id, to: newName)
                    },
                    onRecolorSpeaker: { id, hex in
                        viewModel.recolorSpeaker(id: id, to: hex)
                    },
                    onResizeSpeakerLabel: { id, size in
                        viewModel.resizeSpeakerLabel(id: id, to: size)
                    },
                    onAssignSpeaker: { ids, speakerID in
                        viewModel.setSpeakerForCues(ids: ids, speakerID: speakerID)
                    },
                    onAssignNewSpeaker: { ids in
                        viewModel.assignNewSpeakerToCues(ids: ids)
                    },
                    onSplitCueAtOffset: { id, offset in
                        viewModel.splitSubtitleCue(id: id, atUTF16Offset: offset)
                    },
                    onMergeCues: { ids in
                        viewModel.mergeSubtitleCues(ids: ids)
                    }
                )
                .frame(minHeight: 180)
            } else {
                TimelineDock(
                records: viewModel.records,
                selectedRecordID: viewModel.selectedRecordID,
                projectRoot: viewModel.projectRoot,
                playheadSeconds: $playheadSeconds,
                durationSeconds: durationSeconds,
                segments: viewModel.timelineSegments,
                player: viewModel.player,
                selectedSegmentIDs: viewModel.selectedSegmentIDs,
                primarySelectedSegmentID: viewModel.selectedSegmentID,
                selectedOverlaySegmentID: $viewModel.selectedOverlaySegmentID,
                showSubtitles: $viewModel.showSubtitles,
                subtitleStyle: $viewModel.subtitleStyle,
                onSeek: { seconds in
                    viewModel.player?.seek(
                        to: CMTime(seconds: seconds, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                },
                onScrubbingChange: { scrubbing in
                    isTimelineScrubbing = scrubbing
                },
                onSegmentTap: { index, modifiers in
                    viewModel.handleSegmentClick(index: index, modifiers: modifiers)
                    // Plain click on a clip pill snaps the preview
                    // playhead to that segment's composed start so the
                    // red line visibly jumps to the pill's left edge.
                    // Shift/cmd clicks extend a multi-selection and
                    // must NOT scrub.
                    //
                    // `isTimelineScrubbing` suppresses the 60Hz
                    // transport-bar timer that polls
                    // `player.currentTime()` — during the seek's
                    // in-flight window that poll returns the OLD
                    // position and would stomp our explicit
                    // `playheadSeconds = t`. The seek's completion
                    // handler clears the flag, re-enabling normal
                    // polling.
                    let isRangeOrToggle = modifiers.contains(.shift) || modifiers.contains(.command)
                    if !isRangeOrToggle,
                       let id = viewModel.selectedSegmentID,
                       let t = viewModel.composedStart(ofSegmentID: id) {
                        isTimelineScrubbing = true
                        playheadSeconds = t
                        let target = CMTime(seconds: t, preferredTimescale: 600)
                        if let player = viewModel.player {
                            player.seek(
                                to: target,
                                toleranceBefore: .zero,
                                toleranceAfter: .zero
                            ) { _ in
                                Task { @MainActor in
                                    playheadSeconds = t
                                    isTimelineScrubbing = false
                                }
                            }
                        } else {
                            isTimelineScrubbing = false
                        }
                    }
                },
                onClearSelection: {
                    viewModel.clearSegmentSelection()
                },
                onSelectAllSegments: {
                    viewModel.selectAllSegments()
                },
                onMoveSegment: { source, dest in
                    viewModel.moveSegment(from: source, to: dest)
                },
                onBeginTrim: { index in
                    viewModel.beginTrim(index: index)
                },
                onLiveTrim: { index, edge, deltaSeconds in
                    viewModel.liveTrim(index: index, edge: edge, deltaSeconds: deltaSeconds)
                },
                onEndTrim: { index in
                    viewModel.endTrim(index: index)
                },
                onSplitAtPlayhead: { seconds in
                    viewModel.splitAtPlayheadRespectingSelection(composedTime: seconds)
                },
                onMergeSelectedSegments: {
                    viewModel.mergeSelectedSegments()
                },
                onDeleteSelectedSegments: {
                    viewModel.deleteSelectedSegments()
                },
                onDeleteSegment: { index in
                    viewModel.deleteSegment(at: index)
                },
                onAddFullSource: {
                    viewModel.addFullSourceSegment()
                },
                onSetSelectedSpeed: { rate in
                    viewModel.setSelectedSegmentsSpeed(rate)
                },
                onSetSegmentSpeed: { index, rate in
                    viewModel.setSegmentSpeed(at: index, rate: rate)
                },
                onSetVolume: { index, volume in
                    viewModel.setSegmentVolume(at: index, volume: volume)
                },
                onRotate: { index in
                    viewModel.rotateSegment(at: index)
                },
                onFlipH: { index in
                    viewModel.flipSegmentHorizontal(at: index)
                },
                onFlipV: { index in
                    viewModel.flipSegmentVertical(at: index)
                },
                onSetColor: { index, b, c, s in
                    viewModel.setSegmentColor(at: index, brightness: b, contrast: c, saturation: s)
                },
                onSetAudioFade: { index, fadeIn, fadeOut in
                    viewModel.setSegmentAudioFade(at: index, fadeIn: fadeIn, fadeOut: fadeOut)
                },
                onResetEffects: { index in
                    viewModel.resetSegmentEffects(at: index)
                },
                onEditSubtitleText: { id, newText in
                    viewModel.updateSubtitleText(id: id, newText: newText)
                },
                onEditSubtitleBilingualText: { id, primary, secondary, locale in
                    viewModel.updateSubtitleBilingualText(
                        id: id,
                        primaryText: primary,
                        secondaryText: secondary,
                        secondaryLocale: locale
                    )
                },
                selectedSubtitleID: viewModel.selectedSubtitleID,
                onSelectSubtitle: { id in
                    viewModel.selectSubtitle(id: id)
                    // When a cue is selected, jump the playhead to its
                    // composed start so the preview shows the frame
                    // (+ audio + subtitle) under the cue the user just
                    // clicked.
                    if let id, let t = viewModel.composedStartOfSubtitle(id: id) {
                        playheadSeconds = t
                        viewModel.player?.seek(
                            to: CMTime(seconds: t, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    }
                },
                onMoveSubtitle: { id, newComposedStart in
                    viewModel.moveSubtitle(id: id, to: newComposedStart)
                },
                onResizeSubtitle: { id, leading, newComposed in
                    viewModel.resizeSubtitle(
                        id: id,
                        edge: leading ? .leading : .trailing,
                        toComposedTime: newComposed
                    )
                },
                onAddSubtitle: { composedTime in
                    viewModel.addSubtitle(atComposedTime: composedTime)
                },
                onDeleteSubtitle: { id in
                    viewModel.removeSubtitleEntry(id: id)
                },
                onEmphasizeSubtitle: { id in
                    emphasisCueID = id
                },
                onRunAIPrompt: { prompt in
                    Task { await viewModel.handleAIPrompt(prompt) }
                }
            )
            .environment(\.pendingTimelineDiff, PendingTimelineDiff(
                deletions: viewModel.pendingDeletionIDs,
                speedChanges: viewModel.pendingSpeedChangeIDs,
                volumeChanges: viewModel.pendingVolumeChangeIDs
            ))
            .environment(\.timelineAudioActions, TimelineAudioActions(
                onNormalizeLoudness: { Task { await viewModel.normalizeLoudness() } },
                onCompressSilences: { Task { await viewModel.compressSilences() } },
                onAutoDetectSpeakers: { Task { await viewModel.autoDetectSpeakers() } },
                onAddBGM: { showBGMImportPanel() },
                onAddSFX: { showSFXLibrary = true },
                isEnabled: viewModel.canExport
            ))
            .environment(\.timelineCreativeActions, timelineCreativeActionsBinding)
            }
            } // end if !fullscreenMode
            }
            // Shrink the timeline by ~25% in immersive mode so the viewer
            // gets the reclaimed pixels. The user-saved drag height is
            // preserved for when immersive is toggled off.
            .frame(height: fullscreenMode ? 0 : CGFloat(clampedTimelinePaneHeight) * (immersiveMode ? 0.75 : 1.0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(EditorShellStyle.appBackground.ignoresSafeArea())
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: AvailableHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(AvailableHeightPreferenceKey.self) { newValue in
            measuredAvailableHeight = newValue
        }
        .focusedObject(viewModel)
        .onAppear {
            ActiveEditor.shared.setActive(viewModel)
            UndoKeyMonitor.shared.install()
            TransportKeyMonitor.shared.install()
            ClickFocusResigner.shared.install()
        }
        .onDisappear {
            ActiveEditor.shared.clearIfActive(viewModel)
        }
        .task {
            await viewModel.loadRevisions()
            await viewModel.loadChatHistory()
            await viewModel.loadRecords(validateSources: true)
        }
        .sheet(isPresented: $showAgentTrace) {
            AgentTraceView(
                turns: viewModel.agentTurnsSummary(),
                messageLookup: { mid in
                    viewModel.chatMessages.first(where: { $0.id == mid })?.content
                },
                onUndoTurn: { mid in
                    viewModel.undoAgentTurn(userMessageID: mid)
                    showAgentTrace = false
                },
                onExportTurn: { mid in
                    viewModel.exportAgentTraceJSON(userMessageID: mid)
                }
            )
            .frame(minWidth: 460, minHeight: 360)
            .overlay(alignment: .topTrailing) {
                Button { showAgentTrace = false } label: { T("Done") }
                    .keyboardShortcut(.escape, modifiers: [])
                    .padding(10)
            }
        }
        .sheet(isPresented: $showSFXLibrary) { sfxLibrarySheetContent }
        .sheet(isPresented: Binding(
            get: { emphasisCueID != nil },
            set: { if !$0 { emphasisCueID = nil } }
        )) {
            if let cueID = emphasisCueID,
               let cue = viewModel.composedSubtitles.first(where: { $0.id == cueID }) {
                SubtitleEmphasisSheet(
                    cueID: cue.id,
                    text: cue.text,
                    existingRuns: cue.runs,
                    baseStyle: viewModel.subtitleStyle,
                    onApply: { ranges, patch in
                        viewModel.applyEmphasisToSubtitle(
                            cueID: cue.id,
                            utf16Ranges: ranges,
                            patch: patch
                        )
                        emphasisCueID = nil
                    },
                    onClearAll: {
                        viewModel.clearEmphasisOnSubtitle(cueID: cue.id)
                        emphasisCueID = nil
                    },
                    onCancel: { emphasisCueID = nil }
                )
            }
        }
        .sheet(isPresented: showExportSettings) {
            if let record = viewModel.selectedRecord {
                let composedDuration = viewModel.timelineSegments.reduce(0) { $0 + $1.durationSeconds }
                ExportSettingsSheet(
                    record: record,
                    segmentCount: viewModel.timelineSegments.count,
                    composedDuration: composedDuration,
                    hasSubtitles: !viewModel.composedSubtitles.isEmpty,
                    voiceEnhancerEnabled: viewModel.project.voiceEnhancer.enabled,
                    onExport: { format, resolution, subtitleOption, enhanceVoice in
                        showExportSettings.wrappedValue = false
                        var settings = viewModel.project.voiceEnhancer
                        settings.enabled = enhanceVoice
                        viewModel.project.voiceEnhancer = settings
                        showSavePanel(format: format, resolution: resolution, subtitleOption: subtitleOption)
                    },
                    onExportSubtitlesOnly: {
                        showExportSettings.wrappedValue = false
                        exportSRT()
                    },
                    onCancel: { showExportSettings.wrappedValue = false }
                )
            }
        }
        // Qwen3-ASR install overlay
        .overlay {
            if shouldShowQwenSetupOverlay {
                qwenSetupOverlay
            }
        }
        // Floating export progress card (bottom-trailing)
        .overlay(alignment: .bottomTrailing) {
            if viewModel.isExporting {
                ExportProgressCard(
                    progress: viewModel.exportProgress,
                    isCancelling: viewModel.isCancellingExport,
                    onCancel: { viewModel.cancelExport() }
                )
                .padding(.trailing, 18)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.isExporting)
        // Keyboard shortcuts — simple keys via onKeyPress, modifier combos via hidden buttons
        .onKeyPress(.delete) {
            // If a subtitle cue is selected on the timeline, Delete removes
            // just that cue rather than its video segment.
            if let cueID = viewModel.selectedSubtitleID {
                viewModel.removeSubtitleEntry(id: cueID)
                return .handled
            }
            // Use the plural path so Delete behaves the same as the
            // toolbar trash button — it handles both single and multi
            // selection, and avoids the "always deletes the wrong one"
            // perception that came from selection-primary drift when
            // multiple segments were selected but only the primary
            // got removed.
            viewModel.deleteSelectedSegments()
            return .handled
        }
        // Esc exit is handled by `ImmersiveEscHandler` (installed when
        // immersive mode turns on). `.onKeyPress` is unreliable here
        // because AVPlayerView steals focus on enter-fullscreen.
        // Space / J / K / L are handled by TransportKeyMonitor so they
        // defer to any focused text surface (IME-safe). See
        // App/CuttiMacApp.swift.
        // Modifier key shortcuts via menu-bar commands (EditCommands in App)
        // and overlay hidden button for split only
        .overlay {
            Button {
                viewModel.splitAtPlayheadRespectingSelection(composedTime: playheadSeconds)
            } label: { T("Split") }
            .keyboardShortcut("b", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.22), value: immersiveMode)
    }

    /// Switches the viewer focus mode and synchronises the NSWindow's
    /// native fullscreen state. We drive AppKit directly here (instead
    /// of in `.onChange(of: immersiveMode)`) so the state flag and the
    /// window animation start on the same runloop tick — otherwise
    /// AppKit's fullscreen transition races the SwiftUI layout change
    /// and the side panels collapse a beat before the window zooms.
    private func setViewerFocus(_ mode: ViewerFocusMode) {
        let wasImmersive = immersiveMode
        viewerFocus = mode
        let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first
        if let window {
            let wantFullscreen = immersiveMode
            let isFullscreen = window.styleMask.contains(.fullScreen)
            if wantFullscreen != isFullscreen {
                window.toggleFullScreen(nil)
            }
        }
        if immersiveMode {
            immersiveEscHandler.start { [self] in
                if immersiveMode { setViewerFocus(.off) }
            }
        } else if wasImmersive {
            immersiveEscHandler.stop()
        }
    }

    /// Toggle focus mode (panels hidden, timeline kept).
    private func toggleFocusMode() {
        setViewerFocus(viewerFocus == .focus ? .off : .focus)
    }

    /// Toggle fullscreen mode (panels AND timeline hidden, viewer-only).
    private func toggleFullscreenMode() {
        setViewerFocus(viewerFocus == .fullscreen ? .off : .fullscreen)
    }

    /// Tab strip between the BGM lane and the bottom pane — switches the
    /// bottom area between the multi-track timeline and the Descript-style
    /// transcript editor.
    private var bottomPaneTabBar: some View {
        HStack(spacing: 0) {
            ForEach([BottomPaneTab.timeline, .transcript], id: \.self) { tab in
                Button {
                    bottomPaneTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab == .timeline ? "rectangle.split.3x1" : "text.quote")
                            .font(.caption)
                        T(tab == .timeline ? "Timeline" : "Transcript")
                            .font(.caption.weight(bottomPaneTab == tab ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        bottomPaneTab == tab
                            ? Color.white.opacity(0.08)
                            : Color.clear
                    )
                    .foregroundStyle(bottomPaneTab == tab ? .primary : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    /// Whether the Start button should be enabled. Stays enabled even
    /// when the selected clip already has copilot data so the user can
    /// always re-run analysis (e.g. after interrupting a slow pass, or
    /// to overwrite a stale snapshot with a fresh one). The pipeline
    /// itself is idempotent — running it again on an analyzed clip
    /// replaces the previous snapshot in place.
    private var canStartAnalysis: Bool {
        guard !viewModel.isAnalyzing else { return false }
        // Any ready record qualifies. We used to require at least one
        // un-analyzed ready clip; that path left users stuck whenever
        // analysis got interrupted mid-flight (the partial snapshot
        // — or a previous complete one — would gray the button out
        // permanently). Allowing re-runs trades a small risk of
        // accidental overwrite for a clear escape hatch.
        return viewModel.records.contains { $0.status == .ready }
    }

    /// Compute agent status, incorporating real-time analysis/export progress.
    private var agentStatus: AICopilotPresentation.AgentStatus {
        if viewModel.isImporting {
            return AICopilotPresentation.AgentStatus(
                title: "Importing",
                detail: "Transcoding video to proxy…",
                tone: .working
            )
        }
        if viewModel.isExporting, let progress = viewModel.exportProgress {
            return AICopilotPresentation.AgentStatus(
                title: "Exporting",
                detail: progress.detail,
                tone: .working
            )
        }
        if viewModel.isAnalyzing, let progress = viewModel.analysisProgress {
            return AICopilotPresentation.AgentStatus(
                title: "AI is analyzing",
                detail: progress.detail,
                tone: .working
            )
        }
        return AICopilotPresentation.agentStatus(
            records: viewModel.records,
            selectedRecord: viewModel.selectedRecord
        )
    }

    // MARK: - (Tab button removed — left panel is now AI chat only.)

    private func showImportPanel() {
        ContentView.presentImportPanel(viewModel: viewModel)
    }

    static func presentImportPanel(viewModel: MediaCoreViewModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .movie, .video, .mpeg4Movie, .quickTimeMovie,
            .image, .png, .jpeg
        ]
        panel.message = L("Select a video or image file to import")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                viewModel.startImport(url: url)
            }
        }
    }

    private var sfxLibrarySheetContent: some View {
        SFXLibrarySheet(
            onInsert: { kind in
                let anchor = playheadSeconds
                Task { @MainActor in
                    await viewModel.addSFX(kind: kind, at: anchor)
                }
                showSFXLibrary = false
            },
            onCancel: { showSFXLibrary = false }
        )
    }

    private func showBGMImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .mp3, .wav, .mpeg4Audio, .movie, .video]
        panel.message = L("Select an audio or video file to add as BGM")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await viewModel.addBGMTrack(from: url)
            }
        }
    }

    private func showRelinkPanel() {
        guard let selectedRecordID = viewModel.selectedRecordID else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = L("Select the relocated video file")
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await viewModel.relinkOriginal(mediaId: selectedRecordID, newURL: url)
            }
        }
    }

    private func showSavePanel(
        format: ExportFormat,
        resolution: ExportResolution,
        subtitleOption: SubtitleExportOption
    ) {
        guard let record = viewModel.selectedRecord else { return }

        let panel = NSSavePanel()
        let baseName = URL(fileURLWithPath: record.sourcePath).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName)_edited.\(format.fileExtension)"
        panel.allowedContentTypes = format == .mp4 ? [.mpeg4Movie] : [.movie]
        panel.message = L("Choose where to save")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await viewModel.exportEditedVideo(
                    to: url,
                    format: format,
                    resolution: resolution,
                    subtitleOption: subtitleOption
                )
            }
        }
    }

    private func exportSRT() {
        guard !viewModel.composedSubtitles.isEmpty else { return }
        guard let record = viewModel.selectedRecord else { return }

        let panel = NSSavePanel()
        let baseName = URL(fileURLWithPath: record.sourcePath).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName).srt"
        panel.allowedContentTypes = [.init(filenameExtension: "srt")!]
        panel.message = L("Export subtitles as SRT")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let srt = viewModel.exportSRT()
            try? srt.write(to: url, atomically: true, encoding: .utf8)
            viewModel.bannerMessage = L("SRT exported to %@", url.lastPathComponent)
        }
    }

    // MARK: - Qwen3-ASR Setup Overlay

    /// True when the Qwen3-ASR sidecar appears at the front of the
    /// resolved speech-recognition chain. Direct distribution + Apple
    /// Silicon hosts qualify; MAS or Intel builds skip the overlay
    /// entirely (no install path on those hosts — they get Apple
    /// Speech).
    private var qwenIsSupported: Bool {
        // Mirror the gating used by `SpeechResolverCapabilities.current()`
        // so this view's visibility decision matches what
        // `resolvedSpeechProfile()` would actually pick.
        guard CuttiDistribution.current == .direct else { return false }
        guard qwenAsrHostIsAppleSilicon() else { return false }
        return true
    }

    private var shouldShowQwenSetupOverlay: Bool {
        guard qwenIsSupported else { return false }
        if qwenSetupDismissedRaw { return false }
        switch qwenManager.installState {
        case .installed, .unsupported:
            return false
        case .notInstalled, .installing, .failed:
            return true
        }
    }

    @ViewBuilder
    private var qwenSetupOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 48))
                    .foregroundStyle(EditorShellStyle.accentSolid)

                T("Speech Recognition Setup")
                    .font(.title2.bold())

                switch qwenManager.installState {
                case .notInstalled:
                    T("Cutti uses a local Qwen3-ASR model for accurate Chinese, Cantonese and English subtitles. The first install downloads ~6 GB and runs entirely on your Mac.\nYou can skip and continue with Apple Speech as a fallback.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)

                    HStack(spacing: 12) {
                        Button {
                            // Reset the dismissed flag so the overlay
                            // reappears if the user closes-then-reopens
                            // the editor mid-install.
                            qwenSetupDismissedRaw = false
                            qwenManager.install()
                        } label: { T("Download Speech Model") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            qwenSetupDismissedRaw = true
                        } label: { T("Skip for Now") }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                case .installing:
                    Text(qwenManager.installPhase.displayLabel)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)

                    ProgressView(value: max(qwenManager.overallProgress, 0), total: 1.0)
                        .frame(width: 320)

                    Text("\(Int(qwenManager.overallProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        // Skip just hides the overlay — we do NOT cancel
                        // the in-flight install, so the user can keep
                        // working while the model finishes downloading
                        // in the background.
                        qwenSetupDismissedRaw = true
                    } label: { T("Hide") }
                    .buttonStyle(.bordered)

                case .failed(let message):
                    T("Download failed")
                        .foregroundStyle(EditorShellStyle.destructiveSolid)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button {
                            qwenSetupDismissedRaw = false
                            qwenManager.install()
                        } label: { T("Retry") }
                        .buttonStyle(.borderedProminent)

                        Button {
                            qwenSetupDismissedRaw = true
                        } label: { T("Skip for Now") }
                        .buttonStyle(.bordered)
                    }

                case .installed, .unsupported:
                    EmptyView()
                }
            }
            .padding(40)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .onChange(of: qwenManager.installState) { _, newValue in
            // Reset the dismissed flag whenever the install transitions
            // to .installed so a future uninstall → reinstall round-trip
            // shows the overlay again. The flag stays sticky across
            // launches when the user explicitly opted out.
            if case .installed = newValue {
                qwenSetupDismissedRaw = false
            }
        }
    }
}

// MARK: - Collapsible Media Browser section (right column)

/// Wraps `MediaBrowserSidebar` in a clickable header so the user can collapse
/// it down to just the title strip, making room for the History panel below.
/// Extensions we'll accept via drag-and-drop import into the media bin.
/// Matches the NSOpenPanel allowedContentTypes used by the Import button.
private let mediaDropVideoExtensions: Set<String> = [
    "mov", "mp4", "m4v", "qt", "mpg", "mpeg", "mpg4", "avi", "mkv"
]

/// Still-image extensions accepted via Import button and drag-drop.
/// Scope deliberately narrow for phase A — PNG + JPEG only. HEIC (needs
/// orientation normalization), GIF/WebP (potentially animated) and
/// TIFF/BMP (larger surface area) are deferred.
let mediaDropImageExtensions: Set<String> = [
    "png", "jpg", "jpeg"
]

/// Thread-safe accumulator for drop results so we can mutate from the
/// provider callbacks without a data-race warning.
private final class DropURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

private struct MediaBrowserSection: View {
    let records: [MediaAssetRecord]
    let projectRoot: URL?
    @Binding var selectedRecordID: UUID?
    @Binding var searchQuery: String
    @Binding var isExpanded: Bool
    let importingFiles: [MediaCoreViewModel.ImportingFile]
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onImportURLs: ([URL]) -> Void
    let onCancelImport: (UUID) -> Void

    @State private var isSearchRevealed: Bool = false
    @State private var isDropTargeted: Bool = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(EditorShellStyle.textTertiary)
                        T("MEDIA")
                            .font(.system(size: 10, weight: .semibold, design: .default))
                            .tracking(0.8)
                            .foregroundStyle(EditorShellStyle.textSecondary)
                        Text("\(records.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(EditorShellStyle.textTertiary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(EditorShellStyle.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? L("Collapse media") : L("Expand media"))

                if isSearchRevealed && isExpanded {
                    TextField(L("Search"), text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .focused($isSearchFieldFocused)
                        .onSubmit {
                            if searchQuery.isEmpty {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isSearchRevealed = false
                                }
                            }
                        }
                } else {
                    Spacer()
                }

                if isExpanded {
                    Button {
                        if isSearchRevealed {
                            if searchQuery.isEmpty {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isSearchRevealed = false
                                }
                            } else {
                                searchQuery = ""
                                DispatchQueue.main.async { isSearchFieldFocused = true }
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isSearchRevealed = true
                            }
                            DispatchQueue.main.async { isSearchFieldFocused = true }
                        }
                    } label: {
                        Image(systemName: isSearchRevealed && !searchQuery.isEmpty ? "xmark.circle.fill" : "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isSearchRevealed && !searchQuery.isEmpty ? "Clear search" : "Search media")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if isExpanded {
                Divider()
                if !importingFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(importingFiles) { file in
                            ImportingPlaceholderRow(
                                file: file,
                                onCancel: { onCancelImport(file.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .transition(.opacity)
                }
                MediaBrowserSidebar(
                    records: records,
                    projectRoot: projectRoot,
                    selectedRecordID: $selectedRecordID,
                    searchQuery: $searchQuery,
                    onSelect: onSelect,
                    onDelete: onDelete
                )
            }
        }
        .background(EditorShellStyle.panelBackground)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(EditorShellStyle.accentSolid, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(EditorShellStyle.accentSolid.opacity(0.12))
                    )
                    .overlay(alignment: .center) {
                        Label { T("Drop videos to import") } icon: { Image(systemName: "square.and.arrow.down.on.square") }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(EditorShellStyle.accentSolid)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(EditorShellStyle.panelBackground.opacity(0.9))
                            )
                    }
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Self.handleDrop(providers: providers, onImportURLs: onImportURLs)
        }
    }

    /// Resolve fileURL providers on a background queue, filter to video
    /// extensions, and hand the batch back to the importer on MainActor.
    /// Returns true iff at least one provider looked like a video so the
    /// system shows the accept cursor rather than the "rejected" icon.
    private static func handleDrop(
        providers: [NSItemProvider],
        onImportURLs: @escaping ([URL]) -> Void
    ) -> Bool {
        var anyAccepted = false
        let group = DispatchGroup()
        let collector = DropURLCollector()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier("public.file-url") else { continue }
            anyAccepted = true
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let ext = url.pathExtension.lowercased()
                guard mediaDropVideoExtensions.contains(ext)
                        || mediaDropImageExtensions.contains(ext) else { return }
                collector.append(url)
            }
        }

        group.notify(queue: .main) {
            let resolved = collector.snapshot()
            guard !resolved.isEmpty else { return }
            onImportURLs(resolved)
        }

        return anyAccepted
    }
}

/// Placeholder row shown in the Media list for each file currently being
/// imported. Shows the filename, current import phase (analyzing /
/// queued / encoding %) and a Cancel button so users can interrupt a
/// runaway transcode without restarting the app.
private struct ImportingPlaceholderRow: View {
    let file: MediaCoreViewModel.ImportingFile
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 80, height: 45)
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(phaseLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if showsDeterminateBar {
                    ProgressView(value: file.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
            }
            Spacer(minLength: 4)
            if !showsDeterminateBar {
                ProgressView()
                    .controlSize(.small)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Cancel import"))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var showsDeterminateBar: Bool {
        file.phase == .transcoding && file.progress > 0
    }

    private var phaseLabel: String {
        switch file.phase {
        case .preparing:
            return L("Preparing…")
        case .analyzing:
            return L("Analyzing…")
        case .waiting:
            return L("Queued…")
        case .transcoding:
            if file.progress > 0 {
                return L("Encoding %d%%", Int((file.progress * 100).rounded()))
            }
            return L("Encoding…")
        }
    }
}

/// Captures the live height available to `ContentView` so the
/// timeline-pane divider can dynamically cap its max value and never
/// squash the upper area (chat / viewer / right rail) past readability.
private struct AvailableHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A 1pt hairline divider with a 6pt tall hit area. Hovering shows the
/// resize-up-down cursor; dragging changes `value` by the vertical
/// translation. Used between the stacked Media / History / AI Log panels
/// in the right column so users can resize each section.
private struct ResizableDivider: View {
    @Binding var value: Double
    let minValue: Double
    let maxValue: Double
    var inverted: Bool = false
    var onCommit: (() -> Void)? = nil

    @State private var startValue: Double?
    @State private var isHovering: Bool = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 8)
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color.secondary.opacity(isHovering ? 0.45 : 0.18))
                .frame(height: isHovering ? 2 : 1)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    if startValue == nil { startValue = value }
                    let delta = Double(drag.translation.height) * (inverted ? -1 : 1)
                    let proposed = (startValue ?? value) + delta
                    value = min(max(proposed, minValue), maxValue)
                }
                .onEnded { _ in
                    startValue = nil
                    onCommit?()
                }
        )
    }
}

/// Installs an NSEvent local monitor that catches Esc / ⌘. / ⌘W while
/// immersive mode is on. We hook at the AppKit layer instead of using
/// SwiftUI's `.onKeyPress(.escape)` because the AVPlayerView inside the
/// viewer steals keyboard focus, which prevents SwiftUI key presses
/// from ever reaching ContentView.
@MainActor
final class ImmersiveEscHandler: ObservableObject {
    private var monitor: Any?
    private var onExit: (() -> Void)?

    func start(exit: @escaping () -> Void) {
        onExit = exit
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isCmd = event.modifierFlags.contains(.command)
            let isEscape = event.keyCode == 53
            let isCmdExit = isCmd && (event.charactersIgnoringModifiers == "." ||
                                       event.charactersIgnoringModifiers == "w")
            if isEscape || isCmdExit {
                let exitNow = self.onExit
                DispatchQueue.main.async { exitNow?() }
                return nil
            }
            return event
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        onExit = nil
    }

}
