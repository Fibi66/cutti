import AppKit
import SwiftUI
import AVFoundation
import CuttiKit


/// Snap a raw float duration to the exact 1/600-second grid produced by
/// `CMTime(seconds:, preferredTimescale: 600)`. `CMTime` truncates toward
/// zero here, so the timeline must use the same semantics as the composition
/// builder rather than `rounded()` or pill boundaries slowly drift apart.
@inline(__always)
func quantizedSeconds(_ s: Double) -> Double {
    CMTime(seconds: max(0, s), preferredTimescale: 600).seconds
}

/// Reference-type cache for `composedSubtitlePills()` so body evals that
/// don't touch segments/subtitles (e.g. playhead ticks at 60Hz) can skip
/// the O(n log n) flatten+sort+clamp pass. Pills are stored untyped via
/// `Any` because the element struct is fileprivate to TimelineDock; the
/// cache only needs to round-trip them.
@MainActor
final class ComposedSubtitlePillsCache {
    var signature: String = ""
    var pills: Any = [Int]() // placeholder; overwritten on first write
}


/// Multi-track timeline with video filmstrip, audio waveform, and subtitle tracks.
struct TimelineDock: View {
    let records: [MediaAssetRecord]
    let selectedRecordID: UUID?
    let projectRoot: URL?
    @Binding var playheadSeconds: Double
    let durationSeconds: Double
    let segments: [TimelineSegment]
    let player: AVPlayer?
    let selectedSegmentIDs: Set<UUID>
    let primarySelectedSegmentID: UUID?
    /// Selected overlay segment (for showing the start-time popover
    /// AND for the free-transform handles in the viewer).
    /// Owned by the parent so the viewer can react without requiring
    /// a second click/selection pathway.
    @Binding var selectedOverlaySegmentID: UUID?
    @Binding var showSubtitles: Bool
    @Binding var subtitleStyle: SubtitleStyle
    let onSeek: (Double) -> Void
    /// Fires `true` when the user starts dragging the timeline
    /// playhead and `false` on release. The shell uses this to
    /// suppress the transport bar's 60 Hz refresh timer so the
    /// playhead doesn't snap backwards to a still-seeking
    /// `player.currentTime()` mid-drag.
    var onScrubbingChange: ((Bool) -> Void)? = nil
    let onSegmentTap: (Int, NSEvent.ModifierFlags) -> Void
    let onClearSelection: () -> Void
    let onSelectAllSegments: () -> Void
    let onMoveSegment: (IndexSet, Int) -> Void
    let onBeginTrim: (Int) -> Void
    let onLiveTrim: (Int, HorizontalEdge, Double) -> Void
    let onEndTrim: (Int) -> Void
    let onSplitAtPlayhead: (Double) -> Void
    let onMergeSelectedSegments: () -> Void
    let onDeleteSelectedSegments: () -> Void
    let onDeleteSegment: (Int) -> Void
    let onAddFullSource: () -> Void
    let onSetSelectedSpeed: (Double) -> Void
    let onSetSegmentSpeed: (Int, Double) -> Void
    let onSetVolume: (Int, Double) -> Void
    let onRotate: (Int) -> Void
    let onFlipH: (Int) -> Void
    let onFlipV: (Int) -> Void
    let onSetColor: (Int, Double?, Double?, Double?) -> Void
    let onSetAudioFade: (Int, Double?, Double?) -> Void
    let onResetEffects: (Int) -> Void
    let onEditSubtitleText: (UUID, String) -> Void
    /// Bilingual variant of the text editor. When non-nil and the active
    /// `subtitleStyle.bilingual` had a usable secondary locale at the
    /// moment editing started, the inline popover renders two stacked
    /// TextFields (primary + secondary) and routes commits here instead
    /// of `onEditSubtitleText`. Optional + nil-default so previews and
    /// tests that constructed `TimelineDock` before the bilingual editor
    /// landed keep compiling.
    var onEditSubtitleBilingualText: ((UUID, String, String, String) -> Void)? = nil
    let selectedSubtitleID: UUID?
    let onSelectSubtitle: (UUID?) -> Void
    /// Move a subtitle cue's start to `newComposedStart` seconds.
    let onMoveSubtitle: (UUID, Double) -> Void
    /// Drag a subtitle cue's leading (`edgeLeading == true`) or trailing
    /// edge to `newComposedTime` seconds.
    let onResizeSubtitle: (UUID, Bool, Double) -> Void
    /// Insert a new subtitle cue at the given composed time.
    let onAddSubtitle: (Double) -> Void
    /// Delete only the subtitle cue (does not touch the video range).
    let onDeleteSubtitle: (UUID) -> Void
    /// Launch the "Emphasize words" sheet for a specific cue. Optional so
    /// previews / tests without the full editor shell can omit it; when
    /// nil the context-menu item is hidden.
    var onEmphasizeSubtitle: ((UUID) -> Void)? = nil
    /// Seed the chat agent with a canonical prompt and fire it
    /// immediately. Used by the Timeline's subtitle-lane context menu
    /// to expose bilingual / translate actions without forcing the
    /// user to dig through the AI workflow menu. Optional so test
    /// harnesses and previews that don't have a chat surface can omit
    /// it; nil silently disables the menu items.
    var onRunAIPrompt: ((String) -> Void)? = nil
    /// Fixed height of the timeline dock. Default preserves the legacy
    /// value; the shell binds this to a user-draggable `@AppStorage`
    /// so the vertical splitter between the viewer row and the
    /// timeline can resize the lower pane.
    var height: CGFloat = EditorShellStyle.timelineHeight
    /// Pending Agent proposal diff: segment IDs that the pending proposals would
    /// touch. Rendered as colored overlays on the timeline. Read from the
    /// environment to keep the (already-large) initializer type-checkable.
    @Environment(\.pendingTimelineDiff) var pendingDiff
    @Environment(\.timelineAudioActions) var audioActions
    @Environment(\.timelineCreativeActions) var creativeActions

    /// Track trim state for left-edge visual compensation
    @State var trimActiveIndex: Int?
    @State var trimActiveEdge: HorizontalEdge?
    @State var trimOriginalDuration: Double = 0

    /// Identifies which subtitle cue is currently being edited in the inline
    /// popover (triggered by double-click in the subtitle track).
    @State var editingSubtitleID: UUID?
    @State var editingSubtitleDraft: String = ""
    /// Draft for the secondary (translated) line. Used only when the edit
    /// was initiated while `subtitleStyle.bilingual` had a valid locale.
    @State var editingSubtitleSecondaryDraft: String = ""
    /// Locale snapshot taken at the moment editing started. Non-nil ⇒
    /// render the bilingual two-field popover and commit through
    /// `onEditSubtitleBilingualText` keyed by THIS locale, not by whatever
    /// `subtitleStyle.bilingual.secondaryLocale` happens to be at commit
    /// time (defends against the user toggling style mid-edit).
    @State var editingSubtitleSecondaryLocale: String?

    /// Live drag state for a subtitle cue. Translation is in points along
    /// x; committed on drag end via `onMoveSubtitle`. `edge` is set when
    /// dragging one of the side resize handles instead of the body.
    @State var subtitleDrag: SubtitleDragState?
    /// Set true as soon as either resize-handle gesture starts. The
    /// body-drag gesture is attached via .simultaneousGesture and will
    /// otherwise fire in parallel, overwriting the resize preview and
    /// — fatally — calling `onMoveSubtitle` in its own onEnded handler
    /// (which is why the cue was snapping to the cursor's release
    /// position instead of staying resized). Gated so the body-drag
    /// no-ops while a resize is in flight.
    @State var subtitleResizingInFlight = false

    struct SubtitleDragState: Equatable {
        enum Kind: Equatable { case move, resizeLeading, resizeTrailing }
        let cueID: UUID
        let kind: Kind
        /// Pointer translation along x, in points.
        var translationX: CGFloat
    }

    /// Composed time corresponding to the last known cursor x over the
    /// S1 subtitle lane. Used by the lane's right-click "Add subtitle
    /// here" menu, which otherwise has no access to the click location.
    @State var subtitleLaneHoverComposedTime: Double?

    /// Which segment (if any) has its alternate-takes popover open.
    @State var alternativesPopoverSegmentID: UUID?

    /// Which overlay segment (if any) is currently showing the
    /// "Set Start Time…" popover. Kept SEPARATE from
    /// `selectedOverlaySegmentID` so opening the popover doesn't
    /// hijack the broader selection state — the user must be able to
    /// select a V2 pill (so Cmd+B / toolbar Split target it) without
    /// the popover auto-appearing, stealing focus, and then clearing
    /// selection on dismiss when they click anywhere else. Only the
    /// explicit "Set Start Time…" context-menu item opens this popover.
    @State var overlayStartTimePopoverSegmentID: UUID?

    /// Drop-targeting flags driven by `.dropDestination(isTargeted:)` so
    /// the user sees where a MediaBrowser drag will land.
    @State var isMediaDropOnPrimary = false
    @State var isMediaDropOnNewTrack = false

    /// Selected detached-audio (A2+) segment. Independent of
    /// `selectedSegmentIDs` (which is V1-keyed) so clicking an
    /// aux-audio pill highlights just the pill, mirroring how
    /// Premiere / FCP / Resolve treat a detached audio clip as a
    /// first-class selectable object rather than a visual companion
    /// of its source video. Cleared whenever the V1 selection
    /// changes so the two selection models stay mutually exclusive.
    @State var selectedDetachedAudioID: UUID?

    // Playhead scrubbing state.
    //
    // AVPlayer.seek(toleranceBefore:.zero, toleranceAfter:.zero) is
    // a precise (keyframe-hunting) seek that can take tens of ms per
    // call. Calling it from every DragGesture.onChanged stacked
    // those seeks and produced visible lag as the playhead fell
    // behind the cursor. Standard AVPlayer scrubbing pattern (see
    // Apple QA1820):
    //
    // 1. During drag: coalesce seeks — only keep the latest pending
    //    target, and use permissive tolerances (cheap, reads the
    //    nearest cached sample).
    // 2. On drag end: do one final precise seek via onSeek so
    //    frame-accurate stop position still lands correctly.
    @State var isScrubbing = false
    @State var pendingScrubTime: Double?
    @State var scrubSeekInFlight = false
    /// Which primary-segment gap will receive an insertion if the
    /// currently-hovered drag is dropped. `nil` = no insertion
    /// indicator. 0..<segments.count means "insert BEFORE segment[i]";
    /// segments.count means "append at end". Mirrors the per-segment
    /// `.dropDestination(isTargeted:)` callbacks and the V1-background
    /// drop zone. Used to drive the industry-standard vertical blue
    /// insertion line (FCP / Premiere / Resolve all use this visual).
    @State var primaryInsertionIndex: Int?

    /// Live drag state for an overlay pill. While non-nil the pill
    /// renders with a translated x-offset and the snap guide is shown at
    /// `snappedComposedStart`.
    @State var overlayDrag: OverlayDragState?

    struct OverlayDragState: Equatable {
        let segmentID: UUID
        let originalComposedStart: Double
        /// Pointer translation along x, in points.
        var translationX: CGFloat
        /// Result after snap/clamping — the value that would be
        /// committed if the drag ended now. Also drives the snap guide.
        var snappedComposedStart: Double
        /// Was the current snappedComposedStart produced by an actual
        /// snap (vs free dragging)? Used to tint the guide and pill.
        var didSnap: Bool
    }

    /// Live trim state for an overlay pill. When non-nil the pill
    /// renders with its live width/offset derived from the drag and
    /// the actual revision is only written on release so undo
    /// captures the whole drag as a single step.
    @State var overlayTrim: OverlayTrimState?

    struct OverlayTrimState: Equatable {
        let segmentID: UUID
        let edge: HorizontalEdge
        let originalComposedStart: Double
        let originalDuration: Double
        /// Pointer translation in seconds since the drag began.
        var deltaSeconds: Double

        /// Live composed start applied while dragging — right edge is
        /// pinned on leading, left edge is pinned on trailing.
        var liveComposedStart: Double {
            switch edge {
            case .leading:
                let newStart = originalComposedStart + deltaSeconds
                let clamped = min(max(0, newStart), originalComposedStart + originalDuration - 0.1)
                return clamped
            case .trailing:
                return originalComposedStart
            }
        }
        /// Live pill duration applied while dragging.
        var liveDuration: Double {
            switch edge {
            case .leading:
                let newStart = originalComposedStart + deltaSeconds
                let clampedStart = min(max(0, newStart), originalComposedStart + originalDuration - 0.1)
                return max(0.1, originalDuration + (originalComposedStart - clampedStart))
            case .trailing:
                return max(0.1, originalDuration + deltaSeconds)
            }
        }
    }

    let videoTrackHeight: CGFloat = 46
    let audioTrackHeight: CGFloat = 28
    let subtitleTrackHeight: CGFloat = 22
    let rulerHeight: CGFloat = 22
    let trackSpacing: CGFloat = 0
    let gutterWidth: CGFloat = 70

    /// How many seconds of timeline the user wants visible in the viewport.
    /// This is the zoom model the UI drives: smaller = more zoomed in
    /// (see less time, more detail per second), larger = more zoomed out.
    /// Zoom is therefore *relative to the material*, not an absolute
    /// pts/s — pressing "+" always halves the visible duration, which
    /// feels the same whether the clip is 5 min or 1 h.
    ///
    /// A sentinel value of `0` means "fit-to-view": the effective viewport
    /// equals the full composed duration. This is the default on first
    /// launch and the target of the Fit action (double-click the
    /// magnifier). Persisted across launches.
    ///
    /// The effective viewport is clamped to
    /// `[minViewportSeconds, composedDuration]` at render time, so
    /// zooming out below fit has no visual effect but zooming in works
    /// down to 1 s across the viewport (~ms per pixel on a typical dock).
    @AppStorage("timeline.viewportSeconds") var viewportSeconds: Double = 0
    static let minViewportSeconds: Double = 1.0
    static let zoomStep: Double = 2.0
    // Overlay lanes mirror V1's layout (filmstrip + waveform + subtitle)
    // so a clip dropped on a new track reads the same way as the primary
    // track. Kept slightly shorter than V1 to visually distinguish
    // secondary tracks.
    let overlayVideoHeight: CGFloat = 30
    let overlayAudioHeight: CGFloat = 28
    let overlaySubtitleHeight: CGFloat = 20

    var overlayTrackHeight: CGFloat {
        var h = overlayVideoHeight + trackSpacing + overlayAudioHeight
        if showSubtitles {
            h += trackSpacing + overlaySubtitleHeight
        }
        return h
    }

    /// Rows whose every segment is "visual-only" — either a still image
    /// or an AI-generated Remotion overlay (transparent ProRes 4444 .mov,
    /// silent and uncaptioned). These rows have no meaningful audio and
    /// no caption track, so the lane collapses to just the filmstrip
    /// (no A/S sub-rows, no gutter labels for them). Mixed rows (e.g.
    /// a regular B-roll clip dragged onto the same track) fall through
    /// to the full A/V/S layout.
    func isVisualOnlyOverlay(_ row: TimelineCreativeActions.OverlayRow) -> Bool {
        !row.segments.isEmpty && row.segments.allSatisfy { seg in
            // AI-rendered overlays carry their own `overlaySpec` (surfaced
            // via `isAIEditable`); they're silent transparent renders, so
            // showing an empty waveform / placeholder caption row is just
            // visual noise.
            if seg.isAIEditable { return true }
            // Still images — no audio track, no captions.
            return records.first(where: { $0.id == seg.sourceVideoID })?.kind == .image
        }
    }

    func heightForOverlayRow(_ row: TimelineCreativeActions.OverlayRow) -> CGFloat {
        isVisualOnlyOverlay(row) ? overlayVideoHeight : overlayTrackHeight
    }

    var primarySelectedSegmentIndex: Int? {
        guard let primarySelectedSegmentID else { return nil }
        return segments.firstIndex(where: { $0.id == primarySelectedSegmentID })
    }

    var selectedSegmentCount: Int { selectedSegmentIDs.count }
    var hasSingleSelection: Bool { selectedSegmentCount == 1 }
    var selectedSegments: [TimelineSegment] {
        segments.filter { selectedSegmentIDs.contains($0.id) }
    }
    var uniformSelectedSpeedRate: Double? {
        guard let first = selectedSegments.first?.normalizedSpeedRate else { return nil }
        let allMatch = selectedSegments.dropFirst().allSatisfy { abs($0.normalizedSpeedRate - first) < 0.001 }
        return allMatch ? first : nil
    }
    var selectedSpeedLabel: String {
        if let uniformSelectedSpeedRate {
            return "\(AIActionExecutor.formatRate(uniformSelectedSpeedRate))x"
        }
        return selectedSegments.isEmpty ? L("Speed") : L("Mixed")
    }

    var effectiveAudioTrackHeight: CGFloat {
        // Kept for call sites that still reference the token even
        // though A1 is no longer rendered (audio travels with V1
        // by default; only detached audio gets its own lane).
        audioTrackHeight
    }

    var totalContentHeight: CGFloat {
        let overlayH = creativeActions.overlayRows.reduce(CGFloat(0)) { acc, row in
            acc + heightForOverlayRow(row) + trackSpacing
        }
        let detachedH = CGFloat(creativeActions.detachedAudioRows.count) * (audioTrackHeight + trackSpacing)
        // `newTrackZoneHeight` reserves a hit target BELOW the last
        // track so MediaBrowser drops there create a new overlay lane.
        // Collapses to a thin sliver when no drag is in flight to avoid
        // wasting vertical space.
        let base = rulerHeight + videoTrackHeight + trackSpacing + overlayH + detachedH + newTrackZoneHeight + trackSpacing
        return showSubtitles ? base + subtitleTrackHeight + trackSpacing : base
    }

    /// Memoized result of `composedSubtitlePills()`. SwiftUI re-evaluates
    /// body every playhead tick (60Hz); without this cache we'd
    /// flatten+sort every segment's subtitles ~60 times/second even when
    /// nothing about them has changed.
    @State var subtitlePillsCache = ComposedSubtitlePillsCache()

    /// Vertical height of the panel's GeometryReader, captured so the
    /// new-track drop zone expands to fill whatever empty space the
    /// user has allotted to the timeline pane via the vertical resizer
    /// above it. Users should be able to drop into the entire bottom
    /// region of the timeline, not just a thin sliver.
    @State var panelViewportHeight: CGFloat = 0

    /// Drop zone rendered below the last track so MediaBrowser drags
    /// can create a new overlay lane. Fills the remaining space in
    /// whatever height the pane has (driven by the vertical resizer),
    /// clamped to a 14pt sliver minimum so the timeline still hugs its
    /// content when the user shrinks the pane.
    var newTrackZoneHeight: CGFloat {
        let overlayH = creativeActions.overlayRows.reduce(CGFloat(0)) { acc, row in
            acc + heightForOverlayRow(row) + trackSpacing
        }
        let detachedH = CGFloat(creativeActions.detachedAudioRows.count) * (audioTrackHeight + trackSpacing)
        let brollH = creativeActions.bRollSuggestions.isEmpty ? 0 : BRollSuggestionStrip.stripHeight
        let subtitleH = showSubtitles ? (subtitleTrackHeight + trackSpacing) : 0
        let used = rulerHeight + brollH + overlayH + videoTrackHeight + detachedH + subtitleH
        let fill = Swift.max(14, panelViewportHeight - used - 8)
        return isMediaDropOnNewTrack ? Swift.max(fill, overlayTrackHeight + 6) : fill
    }

    var proxyURL: URL? {
        guard let record = records.first(where: { $0.id == selectedRecordID }),
              let proxyPath = record.derived.proxyRelativePath,
              let root = projectRoot else { return nil }
        return root.appending(path: proxyPath)
    }

    /// Resolve proxy URL for a specific segment's source video.
    func proxyURL(for segment: TimelineSegment) -> URL? {
        guard let record = records.first(where: { $0.id == segment.sourceVideoID }),
              let proxyPath = record.derived.proxyRelativePath,
              let root = projectRoot else { return nil }
        return root.appending(path: proxyPath)
    }

    /// Same as `proxyURL(for:)` but keyed by raw source ID — used by
    /// overlay pills which don't carry a full `TimelineSegment` in the
    /// hint struct, only the source UUID plus its sub-range.
    func proxyURL(forSourceID sourceID: UUID) -> URL? {
        guard let record = records.first(where: { $0.id == sourceID }),
              let proxyPath = record.derived.proxyRelativePath,
              let root = projectRoot else { return nil }
        return root.appending(path: proxyPath)
    }

    /// Color used to tint a segment when a pending Agent proposal
    /// would touch it. Precedence: delete > speed > volume. Returns
    /// nil when no pending proposal affects this segment.
    func pendingDiffTint(for id: UUID) -> Color? {
        if pendingDiff.deletions.contains(id) { return EditorShellStyle.destructiveSolid }
        if pendingDiff.speedChanges.contains(id) { return EditorShellStyle.accentSolid }
        if pendingDiff.volumeChanges.contains(id) { return EditorShellStyle.warningSolid }
        return nil
    }

    /// Total count of segments touched by a pending Agent proposal.
    /// Drives the Obsidian-style "✦ N AI edits pending review" badge
    /// in the timeline toolbar.
    var pendingProposalCount: Int {
        pendingDiff.deletions.count
            + pendingDiff.speedChanges.count
            + pendingDiff.volumeChanges.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorShellStyle.accentSolid)
                T("TIMELINE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(EditorShellStyle.textSecondary)

                if !segments.isEmpty {
                    Text("\(segments.count) seg · \(String(format: "%.1fs", durationSeconds))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(EditorShellStyle.textTertiary)
                }

                if selectedSegmentCount > 0 {
                    Text(String(format: L("%d selected"), selectedSegmentCount))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(EditorShellStyle.accentSolid)
                }

                Spacer()

                // "✦ N AI edits pending review" — shown whenever
                // there are pending diff tints on the timeline,
                // mirroring OBTimeline's pending-review badge.
                if pendingProposalCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                        Text(String(format: L("%d AI edits pending review"), pendingProposalCount))
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(EditorShellStyle.accentSolid)
                }

                // Editing actions
                Button { onSplitAtPlayhead(playheadSeconds) } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .tooltip(L("Split"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(segments.isEmpty)

                // Merge — inverse of Split. Collapses a contiguous
                // selection of same-source, abutting segments back
                // into one. Refuses mixed sources or gapped ranges.
                Button { onMergeSelectedSegments() } label: {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .tooltip(L("Merge selected"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSegmentCount >= 2 ? .primary : .secondary)
                .disabled(selectedSegmentCount < 2)

                Button {
                    onDeleteSelectedSegments()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .tooltip(L("Delete"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSegmentCount > 0 ? EditorShellStyle.destructiveSolid : EditorShellStyle.textTertiary)
                .disabled(selectedSegmentCount == 0)

                zoomSlider

                // Audio toolbox — dropdown of timeline-level audio operations
                // (normalize loudness, compress silences, auto-detect speakers,
                // add a BGM track). Disabled until there's media to act on.
                Menu {
                    Button(action: audioActions.onNormalizeLoudness) {
                        Label { T("Normalize loudness (-16 dB)") } icon: { Image(systemName: "waveform") }
                    }
                    Button(action: audioActions.onCompressSilences) {
                        Label { T("Compress silences (>1s, 4×)") } icon: { Image(systemName: "speaker.slash") }
                    }
                    Divider()
                    Button(action: audioActions.onAutoDetectSpeakers) {
                        Label { T("Auto-detect speakers") } icon: { Image(systemName: "person.2.wave.2") }
                    }
                    Divider()
                    Button(action: audioActions.onAddBGM) {
                        Label { T("Add BGM track…") } icon: { Image(systemName: "music.note") }
                    }
                    Button(action: audioActions.onAddSFX) {
                        Label { T("Add sound effect…") } icon: { Image(systemName: "waveform.badge.plus") }
                    }
                } label: {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .disabled(!audioActions.isEnabled)
                .tooltip(L("Audio"))

                // B-roll insertion — lists all imported assets and
                // inserts the chosen one as a new overlay track at the
                // current playhead. Disabled when the user hasn't imported
                // any media yet.
                Menu {
                    if creativeActions.availableBRollMedia.isEmpty {
                        T("Import a clip first")
                    } else {
                        ForEach(creativeActions.availableBRollMedia) { opt in
                            Button(opt.name) {
                                creativeActions.onInsertBRoll(opt.id, playheadSeconds, 3.0)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .disabled(!creativeActions.isEnabled || creativeActions.availableBRollMedia.isEmpty)
                .tooltip(L("B-roll"))

                // Visual issue finder — recomputes black/empty/scene-change
                // markers for the current timeline and shows them as dots
                // on the ruler.
                Button {
                    creativeActions.onRefreshVisualMarkers()
                } label: {
                    Image(systemName: creativeActions.isRefreshingMarkers ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .tooltip(L("Issues"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(creativeActions.markers.isEmpty ? EditorShellStyle.textTertiary : EditorShellStyle.warningSolid)
                .disabled(!creativeActions.isEnabled || creativeActions.isRefreshingMarkers)

                Divider().frame(height: 14)

                if selectedSegmentCount > 0 {
                    SegmentSpeedPopover(
                        label: selectedSpeedLabel,
                        selectionCount: selectedSegmentCount,
                        currentRate: uniformSelectedSpeedRate,
                        onApplyRate: onSetSelectedSpeed
                    )

                    Divider().frame(height: 14)
                }

                // Volume slider for selected segment
                if let idx = primarySelectedSegmentIndex, hasSingleSelection, idx < segments.count {
                    HStack(spacing: 4) {
                        Image(systemName: segments[idx].volumeLevel > 0 ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { segments[idx].volumeLevel },
                                set: { onSetVolume(idx, $0) }
                            ),
                            in: 0...1
                        )
                        .frame(width: 60)
                        Text("\(Int(segments[idx].volumeLevel * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                    }
                    .tooltip(L("Volume"))

                    Divider().frame(height: 14)

                    // Transform dropdown — rotation & flip consolidated into one
                    // button so the toolbar stays compact. Tint blue whenever
                    // the segment has any active transform.
                    let hasAnyTransform = segments[idx].effects.rotation != 0
                        || segments[idx].effects.flipHorizontal
                        || segments[idx].effects.flipVertical

                    Menu {
                        Button {
                            onRotate(idx)
                        } label: {
                            Label {
                                Text(
                                    segments[idx].effects.rotation != 0
                                        ? String(format: L("Rotate 90° (now %d°)"), segments[idx].effects.rotation)
                                        : L("Rotate 90°")
                                )
                            } icon: {
                                Image(systemName: "rotate.right")
                            }
                        }
                        Divider()
                        Button {
                            onFlipH(idx)
                        } label: {
                            Label {
                                T(segments[idx].effects.flipHorizontal ? "✓ Flip horizontally" : "Flip horizontally")
                            } icon: {
                                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            }
                        }
                        Button {
                            onFlipV(idx)
                        } label: {
                            Label {
                                T(segments[idx].effects.flipVertical ? "✓ Flip vertically" : "Flip vertically")
                            } icon: {
                                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                            }
                        }
                    } label: {
                        Image(systemName: "crop.rotate")
                            .font(.system(size: 12))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(hasAnyTransform ? EditorShellStyle.accentSolid : Color.secondary)
                    .tooltip(L("Transform"))

                    // Effects popover
                    SegmentEffectsPopover(
                        segment: segments[idx],
                        index: idx,
                        onSetColor: onSetColor,
                        onSetAudioFade: onSetAudioFade,
                        onResetEffects: onResetEffects
                    )

                    Divider().frame(height: 14)
                }

                // Subtitle toggle button
                Button {
                    showSubtitles.toggle()
                } label: {
                    Image(systemName: showSubtitles ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 12))
                        .foregroundStyle(showSubtitles ? EditorShellStyle.agentReady : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .tooltip(L(showSubtitles ? "Hide subtitles" : "Subtitles"))
                }
                .buttonStyle(.plain)

                // Subtitle style editing happens in the floating inspector that
                // appears when the user clicks a subtitle in the viewer.
                // SRT export has moved into the Export sheet (top-right
                // Export button → "Export SRT only…") — no longer a
                // standalone button on the timeline chrome.

                Text(TimecodeFormatter.string(seconds: playheadSeconds, fps: 30))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Multi-track area
            GeometryReader { geo in
                let viewWidth = geo.size.width - gutterWidth // minus track labels
                let panelHeight = geo.size.height
                let composedDuration = segments.isEmpty
                    ? durationSeconds
                    : segments.reduce(0) { $0 + quantizedSeconds($1.durationSeconds) }
                // Resolve the user's viewport-seconds intent against the
                // actual material: sentinel 0 = fit (see whole timeline),
                // otherwise clamp into [minViewport, composedDuration] so
                // "zoom out past fit" and "zoom in past 1 s" are no-ops.
                let fitViewport = max(Self.minViewportSeconds, composedDuration)
                let targetViewport = viewportSeconds <= 0 ? fitViewport : viewportSeconds
                let clampedViewport = max(Self.minViewportSeconds, min(fitViewport, targetViewport))
                let effectivePPS = viewWidth > 0 && clampedViewport > 0
                    ? viewWidth / CGFloat(clampedViewport)
                    : 1
                let contentWidth = max(viewWidth, CGFloat(composedDuration) * effectivePPS)

                let _ = {
                    if abs(panelViewportHeight - panelHeight) > 0.5 {
                        DispatchQueue.main.async { panelViewportHeight = panelHeight }
                    }
                }()

                // The HStack below grows to `totalContentHeight` when
                // there are many tracks (V1, overlay V2/V3..., detached
                // audio, S1, etc.). Without a vertical wrapper, anything
                // past `panelHeight` was clipped — there was no way to
                // reach a track that fell off the bottom edge. Wrap the
                // whole multi-track HStack in a vertical ScrollView so
                // overflow becomes scrollable. When content fits the
                // pane (most projects), the scroll bar is invisible and
                // `newTrackZoneHeight` still expands to absorb the
                // remaining space (so MediaBrowser drops anywhere in
                // the empty bottom region create a new lane).
                ScrollView(.vertical, showsIndicators: true) {
                HStack(spacing: 0) {
                    // Track labels
                    VStack(alignment: .trailing, spacing: trackSpacing) {
                        Color.clear
                            .frame(height: rulerHeight)
                            .overlay(
                                Rectangle()
                                    .fill(EditorShellStyle.obBorderSoft)
                                    .frame(height: 1),
                                alignment: .bottom
                            )
                            .overlay(
                                Rectangle()
                                    .fill(EditorShellStyle.obBorderSoft)
                                    .frame(width: 1),
                                alignment: .trailing
                            )
                        if !creativeActions.bRollSuggestions.isEmpty {
                            Color.clear.frame(height: BRollSuggestionStrip.stripHeight)
                        }
                        trackLabel(
                            "V1",
                            icon: "film",
                            height: videoTrackHeight,
                            isMuted: creativeActions.primaryVideoMuted,
                            isLocked: creativeActions.primaryVideoLocked,
                            onToggleEye: creativeActions.primaryVideoTrackID.map { id in
                                { creativeActions.onToggleTrackMute(id) }
                            },
                            onToggleLock: creativeActions.primaryVideoTrackID.map { id in
                                { creativeActions.onToggleTrackLocked(id) }
                            }
                        )
                        if !creativeActions.overlayRows.isEmpty {
                            ForEach(Array(creativeActions.overlayRows.enumerated()), id: \.element.id) { idx, row in
                                let trackNum = idx + 2
                                let trackID = row.id
                                let visualOnly = isVisualOnlyOverlay(row)
                                VStack(alignment: .trailing, spacing: trackSpacing) {
                                    trackLabel(
                                        "V\(trackNum)",
                                        icon: "film",
                                        height: overlayVideoHeight,
                                        isMuted: row.isMuted,
                                        isLocked: row.isLocked,
                                        onToggleEye: { creativeActions.onToggleTrackMute(trackID) },
                                        onToggleLock: { creativeActions.onToggleTrackLocked(trackID) }
                                    )
                                    if !visualOnly && showSubtitles {
                                        trackLabel(
                                            "S\(trackNum)",
                                            icon: "text.quote",
                                            height: overlaySubtitleHeight
                                        )
                                        .contextMenu { subtitleLaneContextMenu() }
                                    }
                                    if !visualOnly {
                                        trackLabel(
                                            "A\(trackNum)",
                                            icon: "waveform",
                                            height: overlayAudioHeight,
                                            isMuted: row.isMuted,
                                            isLocked: row.isLocked,
                                            onToggleEye: { creativeActions.onToggleTrackMute(trackID) },
                                            onToggleLock: { creativeActions.onToggleTrackLocked(trackID) }
                                        )
                                    }
                                }
                            }
                        }
                        if !creativeActions.detachedAudioRows.isEmpty {
                            ForEach(Array(creativeActions.detachedAudioRows.enumerated()), id: \.element.id) { idx, row in
                                let trackID = row.id
                                trackLabel(
                                    "A\(idx + 1)",
                                    icon: "waveform",
                                    height: audioTrackHeight,
                                    isMuted: row.isMuted,
                                    isLocked: row.isLocked,
                                    onToggleEye: { creativeActions.onToggleTrackMute(trackID) },
                                    onToggleLock: { creativeActions.onToggleTrackLocked(trackID) }
                                )
                            }
                        }
                        if showSubtitles {
                            trackLabel(
                                "S1",
                                icon: "text.quote",
                                height: subtitleTrackHeight,
                                isMuted: !creativeActions.subtitlesVisible,
                                onToggleEye: { creativeActions.onToggleSubtitlesVisibility() }
                            )
                            .contextMenu { subtitleLaneContextMenu() }
                        }
                        Color.clear.frame(height: newTrackZoneHeight)
                    }
                    .frame(width: gutterWidth)

                    // Scrollable tracks
                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: trackSpacing) {
                                // Ruler (based on composed duration)
                                ZStack(alignment: .bottomLeading) {
                                    rulerView(width: contentWidth, totalDuration: composedDuration)
                                        .frame(height: rulerHeight)
                                    if !creativeActions.markers.isEmpty {
                                        visualMarkersView(
                                            width: contentWidth,
                                            totalDuration: composedDuration
                                        )
                                        .frame(height: rulerHeight)
                                    }
                                }
                                .frame(height: rulerHeight)
                                .modifier(TrackRowSeparator())

                                // B-roll suggestion bubbles above V1.
                                // Hidden entirely when empty so we don't
                                // bake in vertical space for a feature
                                // the user hasn't triggered yet.
                                if !creativeActions.bRollSuggestions.isEmpty {
                                    BRollSuggestionStrip(
                                        suggestions: creativeActions.bRollSuggestions,
                                        width: contentWidth,
                                        totalDuration: composedDuration,
                                        onDismiss: creativeActions.onDismissBRollSuggestion,
                                        onGenerate: creativeActions.onGenerateBRollSuggestion,
                                        animationGenerationAvailable: CuttiSettings.aiProvider() != .custom
                                    )
                                    .frame(height: BRollSuggestionStrip.stripHeight)
                                }

                                // Video track (filmstrip per segment) —
                                // V1 sits at the TOP of the timeline so
                                // overlays (V2, V3, ...) stack below it
                                // in source-added order, matching the
                                // user's expectation that V1 is always
                                // the top lane.
                                videoTrack(width: contentWidth, pps: effectivePPS)
                                    .frame(height: videoTrackHeight)
                                    .modifier(TrackRowSeparator())
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(
                                                EditorShellStyle.accentSolid,
                                                style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                                            )
                                            .opacity(isMediaDropOnPrimary ? 1 : 0)
                                            .animation(.easeInOut(duration: 0.12), value: isMediaDropOnPrimary)
                                            .allowsHitTesting(false)
                                    )
                                    .dropDestination(for: String.self) { items, _ in
                                        defer { primaryInsertionIndex = nil }
                                        guard let dragged = items.first else { return false }
                                        // Highlights panel drop on the
                                        // V1 row background → append a
                                        // slice at the end of the
                                        // primary track.
                                        if let parsed = AICopilotPresentation.parseHighlightPayload(dragged) {
                                            creativeActions.onInsertSourceSliceAtPrimaryIndex(
                                                parsed.recordID,
                                                parsed.start,
                                                parsed.end,
                                                segments.count
                                            )
                                            return true
                                        }
                                        guard dragged.hasPrefix("media:"),
                                              let uuid = UUID(uuidString: String(dragged.dropFirst("media:".count)))
                                        else { return false }
                                        // Dropped on the V1 row background
                                        // (not on a specific segment) → append
                                        // to the end of the primary track.
                                        creativeActions.onInsertMediaAtPrimaryIndex(uuid, segments.count)
                                        return true
                                    } isTargeted: { hovering in
                                        isMediaDropOnPrimary = hovering
                                        // Drive the industry-standard
                                        // insertion bar: when the cursor
                                        // is over the V1 background but
                                        // NOT over a specific segment,
                                        // show the bar at the very end
                                        // of the track. Per-segment
                                        // hover (inside an actual clip)
                                        // wins because its isTargeted
                                        // fires after this one with its
                                        // own index.
                                        if hovering {
                                            if primaryInsertionIndex == nil {
                                                primaryInsertionIndex = segments.count
                                            }
                                        } else if primaryInsertionIndex == segments.count {
                                            primaryInsertionIndex = nil
                                        }
                                    }

                                // Overlay (V2+) lanes — rendered BELOW
                                // the primary track so V1 stays at the
                                // top of the timeline and additional
                                // overlays stack downward in the order
                                // they were created.
                                ForEach(creativeActions.overlayRows) { row in
                                    overlayLaneView(
                                        row: row,
                                        width: contentWidth,
                                        pps: effectivePPS,
                                        totalDuration: composedDuration
                                    )
                                    .frame(height: heightForOverlayRow(row))
                                    .modifier(TrackRowSeparator())
                                }

                                // Audio travels with V1 by default (no
                                // standalone A1 lane). Only clips the
                                // user explicitly detaches spawn their
                                // own aux-audio track below, matching
                                // standard NLE behaviour.

                                // Detached-audio (A1+) lanes. Only rendered
                                // when the user has actually detached a
                                // clip's audio, so projects that haven't
                                // touched the feature keep the compact
                                // V1/S1 layout.
                                ForEach(creativeActions.detachedAudioRows) { row in
                                    detachedAudioLaneView(
                                        row: row,
                                        width: contentWidth,
                                        pps: effectivePPS
                                    )
                                    .frame(height: audioTrackHeight)
                                    .modifier(TrackRowSeparator())
                                }

                                // Subtitle track — sits below all audio
                                // tracks so the user's video+audio block
                                // reads as one unit and subtitles act
                                // as the closing summary lane.
                                if showSubtitles {
                                    subtitleTrack(width: contentWidth, pps: effectivePPS)
                                        .frame(height: subtitleTrackHeight)
                                        .modifier(TrackRowSeparator())
                                }

                                // "New track" drop zone — invisible until a
                                // MediaBrowser drag hovers it, then animates
                                // into a dashed "+ New overlay track" lane.
                                // On drop, creates a new overlay track with
                                // the clip starting at composed t=0 (user can
                                // drag the resulting pill to reposition).
                                newTrackDropZone(width: contentWidth)
                                    .frame(height: newTrackZoneHeight)
                            }

                            // Playhead spans all tracks
                            playheadView(width: contentWidth, totalDuration: composedDuration)

                            // Invisible scroll anchor that tracks the
                            // playhead's X in content coordinates. On
                            // zoom (`viewportSeconds` change), the
                            // `.onChange` below runs
                            // `scrollProxy.scrollTo(...)` on the next
                            // runloop tick so the playhead stays put
                            // in the visible region instead of drifting
                            // off the right edge after zoom-in.
                            //
                            // We use an `HStack` with a leading
                            // `Spacer` of explicit width rather than
                            // `.position(x:y:)` because
                            // `ScrollViewReader.scrollTo` reads the
                            // anchor's frame in the scroll content's
                            // layout coordinate space — views placed
                            // via `.position` don't reliably land in
                            // that space on macOS 14 and scrollTo
                            // ends up jumping to x≈0, making the
                            // viewport "spin" and the playhead slide
                            // off screen.
                            HStack(spacing: 0) {
                                let targetX = max(
                                    0,
                                    min(
                                        max(0, contentWidth - 1),
                                        CGFloat(playheadSeconds) * effectivePPS
                                    )
                                )
                                Color.clear.frame(width: targetX, height: 1)
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .id("playhead-zoom-anchor")
                                Spacer(minLength: 0)
                            }
                            .frame(width: contentWidth, height: 1, alignment: .leading)
                            .allowsHitTesting(false)
                        }
                        .frame(width: contentWidth, height: totalContentHeight)
                        .offset(x: leftTrimScrollOffsetPx(pps: effectivePPS))
                        .animation(.easeOut(duration: 0.18), value: trimActiveIndex)
                        .contentShape(Rectangle())
                        .gesture(
                            // minimumDistance is intentionally generous
                            // (not the default 0/2pt): a real mouse
                            // click on a narrow clip pill almost always
                            // has a few sub-pixels of mouse wobble
                            // between mouseDown and mouseUp. If the
                            // outer scrub gesture captures those few
                            // pixels, it seeks the playhead to the
                            // click's X-inside-the-pill (i.e. somewhere
                            // near the middle of a small pill) BEFORE
                            // the pill's `.onTapGesture` ever gets to
                            // fire — so the caller's "jump-to-segment-
                            // start" logic never runs. A 10pt threshold
                            // keeps deliberate scrub drags snappy while
                            // ensuring ordinary clicks resolve to the
                            // child pill's tap.
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    if !isScrubbing {
                                        onScrubbingChange?(true)
                                    }
                                    let fraction = max(0, min(1, value.location.x / contentWidth))
                                    let seconds = Double(fraction) * composedDuration
                                    playheadSeconds = seconds
                                    scrubSeek(to: seconds)
                                }
                                .onEnded { value in
                                    let fraction = max(0, min(1, value.location.x / contentWidth))
                                    let seconds = Double(fraction) * composedDuration
                                    playheadSeconds = seconds
                                    isScrubbing = false
                                    pendingScrubTime = nil
                                    // Final precise seek so the
                                    // frame we stop on is the one
                                    // the user released on.
                                    onSeek(seconds)
                                    onScrubbingChange?(false)
                                }
                        )
                        .onTapGesture {
                            // Tap on empty area deselects
                            onClearSelection()
                        }
                    }
                    .onChange(of: viewportSeconds) { _, _ in
                        // Keep the playhead at the same visible position
                        // when the user zooms. Dispatched to the next
                        // runloop tick so SwiftUI has finished re-laying
                        // out the scroll content under the new
                        // `effectivePPS`/`contentWidth` before we ask
                        // scrollTo to center on the anchor — otherwise
                        // the proxy reads the stale (pre-zoom) anchor
                        // frame and the scroll lands at the wrong x.
                        //
                        // NOT wrapped in `withAnimation`: animating the
                        // scroll offset while `contentWidth` is also
                        // animating puts them on two unsynchronised
                        // timelines and the whole timeline visibly
                        // drifts left/right during the ~200 ms
                        // animation. Snapping in a single frame is the
                        // only reliable way to keep the playhead
                        // glued to its on-screen position.
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo("playhead-zoom-anchor", anchor: .center)
                        }
                    }
                    }
                }
                }   // ScrollView(.vertical)
            }
        }
        .overlay {
            Group {
                Button {
                    onSelectAllSegments()
                } label: {
                    T("Select All Segments")
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(segments.isEmpty)

                Button {
                    onClearSelection()
                } label: {
                    T("Clear Segment Selection")
                }
                .keyboardShortcut(.cancelAction)
                .disabled(selectedSegmentCount == 0)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, EditorShellStyle.panelPadding)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EditorShellStyle.panelBackground)
        .onChange(of: selectedSegmentIDs) { _, _ in
            // V1 and detached-audio selection are mutually exclusive —
            // touching the V1 selection (tap, marquee, Cmd-A, etc.)
            // drops the aux-audio highlight so the user never sees
            // two "selected" rings that belong to different tracks.
            selectedDetachedAudioID = nil
        }
    }

    // MARK: - Trim Handle

    @State var trimHasFiredStart = false
    /// The last delta (in pixels) we actually applied to the VM. We
    /// skip `onLiveTrim` calls whose delta changed by less than one
    /// whole pixel — those can't produce any visible difference but
    /// do trigger a full @Published re-render of the timeline and
    /// every downstream subtitle pill, which is what made the bar
    /// feel laggy and caused neighbouring subs to visibly shake as
    /// sub-pixel rounding drifted between code paths.
    @State var lastAppliedTrimPixelDelta: CGFloat = .infinity

}


