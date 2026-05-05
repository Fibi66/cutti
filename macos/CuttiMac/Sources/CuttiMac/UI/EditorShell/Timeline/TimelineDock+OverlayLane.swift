// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Overlay (B-roll) lane

    /// Snap threshold used when dragging an overlay pill: candidate
    /// positions within this many seconds of a primary-segment boundary
    /// (or the timeline origin) get pulled to that boundary. 0.25s is
    /// tight enough that users can still free-place, but wide enough
    /// that "land exactly at the cut" is effortless.
    static let overlaySnapSeconds: Double = 0.25

    /// Interactive strip for one overlay track. Each segment is a pill
    /// that can be:
    ///   • Dragged horizontally — live snaps to primary segment
    ///     boundaries and to t=0 within `overlaySnapSeconds`.
    ///   • Tapped — opens a popover that lets the user type an exact
    ///     start time (seconds) instead of eyeballing it.
    func overlayLaneView(
        row: TimelineCreativeActions.OverlayRow,
        width: CGFloat,
        pps: CGFloat,
        totalDuration: Double
    ) -> some View {
        let visualOnly = isVisualOnlyOverlay(row)
        return VStack(spacing: trackSpacing) {
            // Filmstrip sub-row — hosts the draggable pills.
            overlayVideoRow(
                row: row,
                width: width,
                pps: pps,
                totalDuration: totalDuration
            )
            .frame(height: overlayVideoHeight)

            if !visualOnly {
                // Audio waveform sub-row — per-pill waveforms so the user
                // can see the audio shape of each B-roll clip, just like
                // on the primary track. Skipped for visual-only lanes
                // (still images and silent AI-rendered overlays — neither
                // has an audio track to draw).
                overlayAudioRow(
                    row: row,
                    width: width,
                    pps: pps
                )
                .frame(height: overlayAudioHeight)

                // Subtitle sub-row — mirrors S1's empty-lane appearance.
                // Overlay media has no attached caption track yet, so this
                // row is visually a placeholder; it keeps the layout in
                // lockstep with V1 so users know it's a real track stack.
                // Visual-only lanes skip this too — still images and
                // AI-rendered overlays have nothing to caption.
                if showSubtitles {
                    overlaySubtitleRow(width: width)
                        .frame(height: overlaySubtitleHeight)
                }
            }
        }
        .frame(width: width, height: heightForOverlayRow(row), alignment: .leading)
    }

    @ViewBuilder
    func overlayVideoRow(
        row: TimelineCreativeActions.OverlayRow,
        width: CGFloat,
        pps: CGFloat,
        totalDuration: Double
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(EditorShellStyle.panelInsetBackground.opacity(0.6))
                .frame(width: width, height: overlayVideoHeight)

            // Snap guide: thin vertical blue bar where the current drag
            // would commit. Shown only while dragging AND snapped.
            if let drag = overlayDrag, drag.didSnap {
                Rectangle()
                    .fill(EditorShellStyle.accentSolid)
                    .frame(width: 1.5, height: overlayVideoHeight)
                    .offset(x: CGFloat(drag.snappedComposedStart) * pps)
                    .allowsHitTesting(false)
            }

            ForEach(row.segments) { seg in
                overlayPill(
                    seg: seg,
                    pps: pps,
                    totalDuration: totalDuration
                )
            }

            // Trim handles live OUTSIDE each pill so they don't
            // compete with the pill's own tap/drag gestures. When a
            // segment is selected we render two handles positioned at
            // the pill's live leading/trailing edges in this same row.
            // They get their own independent DragGesture (see
            // `overlayTrimHandle`), which is reliable because no
            // ancestor view owns a conflicting gesture at their
            // location.
            if let selectedID = selectedOverlaySegmentID,
               let selSeg = row.segments.first(where: { $0.id == selectedID }) {
                overlayTrimHandleOverlays(seg: selSeg, pps: pps)
            }
        }
        .frame(width: width, height: overlayVideoHeight, alignment: .leading)
        // Accept MediaBrowser drags onto THIS overlay lane so the user
        // can drop new media into an existing V2+ track at the cursor's
        // time. Without this, the drop bubbled through and the library's
        // fallback handler always created a new overlay lane instead.
        .dropDestination(for: String.self) { items, location in
            guard let dragged = items.first,
                  dragged.hasPrefix("media:"),
                  let uuid = UUID(uuidString: String(dragged.dropFirst("media:".count)))
            else { return false }
            let composedStart = max(0, Double(location.x / max(pps, 1)))
            creativeActions.onInsertMediaIntoOverlayTrack(uuid, row.id, composedStart)
            return true
        } isTargeted: { _ in }
    }

    /// Render the leading + trailing trim handles for `seg` as
    /// siblings of the pill inside `overlayVideoRow`'s ZStack. Their
    /// x-offsets mirror the pill's live geometry so they stay glued
    /// to the edges while the user drags to resize.
    @ViewBuilder
    func overlayTrimHandleOverlays(
        seg: TimelineCreativeActions.OverlaySegmentHint,
        pps: CGFloat
    ) -> some View {
        let isTrimming = overlayTrim?.segmentID == seg.id
        let isDragging = overlayDrag?.segmentID == seg.id
        let liveStart: Double = {
            if isDragging { return overlayDrag?.snappedComposedStart ?? seg.startSeconds }
            if isTrimming { return overlayTrim?.liveComposedStart ?? seg.startSeconds }
            return seg.startSeconds
        }()
        let liveDuration: Double = isTrimming ? (overlayTrim?.liveDuration ?? seg.durationSeconds) : seg.durationSeconds
        let leadingX = CGFloat(liveStart) * pps
        let trailingX = CGFloat(liveStart + liveDuration) * pps - 8  // 8 = handle visible width
        // Handle frames are 24pt wide (8pt visible + 8pt hit slop on
        // each side), with the visible chrome centered. To place the
        // visible handle exactly at the pill edge we subtract the
        // slop from the raw edge coordinate.
        let handleSlop: CGFloat = 8

        overlayTrimHandle(edge: .leading, seg: seg, pps: pps)
            .offset(x: leadingX - handleSlop, y: 1)
        overlayTrimHandle(edge: .trailing, seg: seg, pps: pps)
            .offset(x: trailingX - handleSlop, y: 1)
    }

    @ViewBuilder
    func overlayAudioRow(
        row: TimelineCreativeActions.OverlayRow,
        width: CGFloat,
        pps: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(EditorShellStyle.panelInsetBackground.opacity(0.5))
                .frame(width: width, height: overlayAudioHeight)

            ForEach(row.segments) { seg in
                let isDragging = overlayDrag?.segmentID == seg.id
                let liveStart = isDragging
                    ? (overlayDrag?.snappedComposedStart ?? seg.startSeconds)
                    : seg.startSeconds
                let x = CGFloat(quantizedSeconds(liveStart)) * pps
                let w = max(16, CGFloat(quantizedSeconds(seg.durationSeconds)) * pps)
                let isImage = records.first(where: { $0.id == seg.sourceVideoID })?.kind == .image

                if !isImage, let proxy = proxyURL(forSourceID: seg.sourceVideoID) {
                    SegmentWaveform(
                        videoURL: proxy,
                        startSeconds: seg.sourceStartSeconds,
                        endSeconds: seg.sourceEndSeconds,
                        width: w,
                        height: overlayAudioHeight
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: w, height: overlayAudioHeight)
                    .offset(x: x)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, height: overlayAudioHeight, alignment: .leading)
    }

    @ViewBuilder
    func overlaySubtitleRow(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(EditorShellStyle.panelInsetBackground.opacity(0.4))
            .frame(width: width, height: overlaySubtitleHeight)
    }

    func overlayPill(
        seg: TimelineCreativeActions.OverlaySegmentHint,
        pps: CGFloat,
        totalDuration: Double
    ) -> some View {
        let isDragging = overlayDrag?.segmentID == seg.id
        let isTrimming = overlayTrim?.segmentID == seg.id
        let liveStart: Double = {
            if isDragging { return overlayDrag?.snappedComposedStart ?? seg.startSeconds }
            if isTrimming { return overlayTrim?.liveComposedStart ?? seg.startSeconds }
            return seg.startSeconds
        }()
        let liveDuration: Double = isTrimming ? (overlayTrim?.liveDuration ?? seg.durationSeconds) : seg.durationSeconds
        let x = CGFloat(liveStart) * pps
        let w = max(16, CGFloat(liveDuration) * pps)
        // Reserve an FCP-style gap on the trailing edge so
        // adjacent overlay clips read as separate pills.
        let gap = EditorShellStyle.timelineClipGap
        let visualW = max(8, w - gap)
        let didSnap = isDragging && (overlayDrag?.didSnap ?? false)
        let isSelected = selectedOverlaySegmentID == seg.id
        let proxy = proxyURL(forSourceID: seg.sourceVideoID)
        let record = records.first { $0.id == seg.sourceVideoID }
        let isImage = record?.kind == .image

        return ZStack {
            if isImage {
                // Image overlay: render the actual still as a filled
                // thumbnail so the user sees what they dropped, not an
                // icon + filename. Falls back to the photo chip while
                // the NSImage is still loading or if decoding failed.
                if let record {
                    ImageAssetThumbnail(record: record, projectRoot: projectRoot)
                        .frame(width: visualW, height: overlayVideoHeight - 2)
                        .clipShape(RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius))
                        .opacity(seg.isVideoHidden ? 0.28 : 1)
                        // The thumbnail is purely visual; it must not
                        // absorb pointer events or — due to .scaledToFill
                        // overflowing its frame — it skews the pill's
                        // effective hit region once .offset moves it to
                        // a new x. Video filmstrips are internally
                        // clipped so they didn't exhibit this; image
                        // thumbnails need an explicit opt-out here.
                        .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                        .fill(EditorShellStyle.timelineClipTint)
                        .frame(width: visualW)
                }
            } else if let proxy {
                SegmentFilmstrip(
                    videoURL: proxy,
                    startSeconds: seg.sourceStartSeconds,
                    endSeconds: seg.sourceEndSeconds,
                    width: visualW,
                    height: overlayVideoHeight - 2
                )
                .clipShape(RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius))
                .opacity(seg.isVideoHidden ? 0.28 : 1)
            } else {
                RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                    .fill(EditorShellStyle.timelineClipTint)
                    .frame(width: visualW)
            }

            // Hidden-video ("cut") hatch for overlay: mirrors V1 with
            // red diagonals + dashed red border.
            if seg.isVideoHidden {
                RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: visualW)
                DiagonalHatch()
                    .stroke(EditorShellStyle.obRed.opacity(0.55), lineWidth: 1)
                    .clipShape(RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius))
                    .frame(width: visualW)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                    .strokeBorder(
                        EditorShellStyle.obRed,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: visualW)
                    .allowsHitTesting(false)
            }

            // Obsidian-style dim for overlay (V2+) filmstrips.
            RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                .fill(Color.black.opacity(0.5))
                .frame(width: visualW)
                .allowsHitTesting(false)

            // V2 lane wash — teal-green at 20%.
            RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                .fill(EditorShellStyle.obV2.opacity(0.2))
                .frame(width: visualW)
                .allowsHitTesting(false)

            // Selection / snap outline — V2 teal default, amber on select.
            RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                .strokeBorder(
                    didSnap
                        ? EditorShellStyle.accentSolid
                        : (isSelected
                            ? EditorShellStyle.timelineClipBorderSelected
                            : EditorShellStyle.obV2.opacity(0.55)),
                    lineWidth: (didSnap || isSelected)
                        ? EditorShellStyle.timelineClipBorderSelectedWidth
                        : 1
                )
                .frame(width: visualW)

            // FCP-style effects badge bar (only shown when the
            // overlay clip has hidden video or muted audio).
            clipTitleBar(
                hasFX: seg.isVideoHidden || seg.isAudioMuted,
                width: visualW
            )

            // AI-editable affordance: a small ✨ badge in the top-left
            // so users know they can double-click to edit the template
            // props (title / theme / accent color / …).
            if seg.isAIEditable {
                HStack(spacing: 0) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(3)
                        .background(Color.black.opacity(0.35), in: Circle())
                        .padding(3)
                    Spacer(minLength: 0)
                }
                .frame(width: visualW, alignment: .leading)
                .allowsHitTesting(false)
            }

            // Re-render indicator: dim the pill + show a spinner so the
            // user knows the overlay they're seeing is still the old
            // render while the new one is cooking in the cloud.
            if seg.isRendering {
                ZStack {
                    RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                        .fill(Color.black.opacity(0.55))
                        .frame(width: visualW)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .scaleEffect(0.7)
                }
                .frame(width: visualW)
                .allowsHitTesting(false)
            }

            // Trim handles are rendered as siblings of the pill by
            // `overlayTrimHandleOverlays(...)` in `overlayVideoRow` so
            // they don't fight with the pill's own tap/drag gestures.
        }
        .frame(width: w, height: overlayVideoHeight - 2, alignment: .leading)
        .contentShape(Rectangle())
        // Position via layout (padding + maxWidth wrapper) instead of
        // .offset. On macOS, .offset does NOT translate the hit-test
        // region in this ZStack-in-ForEach structure: after a commit,
        // the pill was visually at x but its DragGesture hit region
        // stayed at the layout frame (0, 0, w, h), so clicks at the
        // new visual position fell through to the track background.
        // Using .padding/.frame drives layout, so hit testing follows.
        .padding(.leading, x)
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contextMenu {
            Button(seg.isVideoHidden ? "Show Image" : "Hide Image") {
                creativeActions.onToggleSegmentVideoHidden(seg.id)
            }
            if !isImage {
                Button(seg.isAudioMuted ? "Unmute Audio" : "Mute Audio") {
                    creativeActions.onToggleSegmentAudioMuted(seg.id)
                }
            }
            Divider()
            Menu {
                Button(seg.pipLayout == nil ? L("✓ Off") : L("Off")) {
                    creativeActions.onSetPiPLayout(seg.id, nil)
                }
                Divider()
                Button {
                    creativeActions.onAutoPiP(seg.id)
                } label: { T("✨ Auto Picture-in-Picture") }
                Divider()
                ForEach(PiPLayout.Corner.allCases, id: \.self) { corner in
                    Button(pipCornerMenuTitle(corner: corner, activeCorner: seg.pipLayout?.corner)) {
                        var base = seg.pipLayout ?? .default
                        base.corner = corner
                        creativeActions.onSetPiPLayout(seg.id, base)
                    }
                }
                Divider()
                Button(seg.pipLayout?.shape == .circle ? L("✓ Circle") : L("Circle")) {
                    var base = seg.pipLayout ?? .default
                    base.shape = .circle
                    creativeActions.onSetPiPLayout(seg.id, base)
                }
                Button(seg.pipLayout?.shape == .roundedSquare ? L("✓ Rounded Square") : L("Rounded Square")) {
                    var base = seg.pipLayout ?? .default
                    base.shape = .roundedSquare
                    creativeActions.onSetPiPLayout(seg.id, base)
                }
                Button(seg.pipLayout?.shape == .square ? L("✓ Square") : L("Square")) {
                    var base = seg.pipLayout ?? .default
                    base.shape = .square
                    creativeActions.onSetPiPLayout(seg.id, base)
                }
            } label: {
                T("Picture in Picture")
            }
            Divider()
            Button {
                // Selecting AND opening the popover here keeps Cmd+B
                // working on this segment after the user dismisses the
                // popover — selection is the persistent state that
                // routes shortcuts; the popover is a transient editor.
                selectedOverlaySegmentID = seg.id
                overlayStartTimePopoverSegmentID = seg.id
            } label: { T("Set Start Time…") }
            Divider()
            Button(role: .destructive) {
                if selectedOverlaySegmentID == seg.id {
                    selectedOverlaySegmentID = nil
                }
                creativeActions.onRemoveOverlaySegment(seg.id)
            } label: { T("Delete") }
        }
        // Unified gesture (see `overlayDragGesture`) handles BOTH
        // click-to-select and drag-to-move from a single DragGesture
        // recognizer. A separate double-click recognizer keeps the AI
        // inspector shortcut working. We no longer combine a
        // `.onTapGesture` with a `.highPriorityGesture(DragGesture)`
        // because on macOS that combination left the tap path stuck
        // after a drag cycle completed — subsequent clicks on the
        // moved pill never fired `.onTapGesture`.
        .onTapGesture(count: 2) {
            if seg.isAIEditable {
                creativeActions.onOpenOverlayInspector(seg.id)
            }
        }
        .gesture(overlayDragGesture(for: seg, pps: pps, totalDuration: totalDuration))
        .popover(
            isPresented: Binding(
                get: { overlayStartTimePopoverSegmentID == seg.id && overlayDrag == nil },
                set: { if !$0 { overlayStartTimePopoverSegmentID = nil } }
            ),
            arrowEdge: .top
        ) {
            OverlayStartTimePopover(
                initialSeconds: seg.startSeconds,
                totalDuration: totalDuration,
                onCommit: { newStart in
                    creativeActions.onMoveOverlaySegment(seg.id, newStart)
                    overlayStartTimePopoverSegmentID = nil
                },
                onCancel: {
                    overlayStartTimePopoverSegmentID = nil
                }
            )
        }
        .tooltip("\(seg.mediaName) · \(String(format: "%.2fs", liveStart))s → \(String(format: "%.2fs", liveStart + liveDuration))s")
    }

    /// Leading/trailing trim handle overlaid on a selected overlay
    /// pill. Updates `overlayTrim` continuously so the pill visually
    /// resizes during the drag, then commits a single undo revision
    /// through `onTrimOverlaySegment` on release.
    func overlayTrimHandle(
        edge: HorizontalEdge,
        seg: TimelineCreativeActions.OverlaySegmentHint,
        pps: CGFloat
    ) -> some View {
        TrimHandleView(
            edge: edge,
            height: overlayVideoHeight - 4,
            onDragChanged: { pxDelta in
                let deltaSec = Double(pxDelta) / Double(pps)
                let current = overlayTrim
                if current?.segmentID != seg.id || current?.edge != edge {
                    overlayTrim = OverlayTrimState(
                        segmentID: seg.id,
                        edge: edge,
                        originalComposedStart: seg.startSeconds,
                        originalDuration: seg.durationSeconds,
                        deltaSeconds: deltaSec
                    )
                } else {
                    overlayTrim?.deltaSeconds = deltaSec
                }
            },
            onDragEnded: { _ in
                guard let state = overlayTrim, state.segmentID == seg.id else {
                    overlayTrim = nil
                    return
                }
                let composedEdge: Double = {
                    switch edge {
                    case .leading: return state.liveComposedStart
                    case .trailing: return state.liveComposedStart + state.liveDuration
                    }
                }()
                overlayTrim = nil
                // Only commit if the pill actually changed size.
                if abs(state.liveDuration - state.originalDuration) > 0.005 ||
                   abs(state.liveComposedStart - state.originalComposedStart) > 0.005 {
                    creativeActions.onTrimOverlaySegment(seg.id, edge, composedEdge)
                }
            }
        )
    }

    func pipCornerMenuTitle(corner: PiPLayout.Corner, activeCorner: PiPLayout.Corner?) -> String {
        let label: String
        switch corner {
        case .topLeft: label = L("Top Left")
        case .topRight: label = L("Top Right")
        case .bottomLeft: label = L("Bottom Left")
        case .bottomRight: label = L("Bottom Right")
        }
        return activeCorner == corner ? "✓ \(label)" : label
    }

    func overlayDragGesture(
        for seg: TimelineCreativeActions.OverlaySegmentHint,
        pps: CGFloat,
        totalDuration: Double
    ) -> some Gesture {
        // Unified click-or-drag gesture. Using `minimumDistance: 0`
        // lets us handle both mouse-down-then-release (click → toggle
        // selection) and mouse-down-then-move-then-release (drag →
        // reposition) from a SINGLE recognizer, so macOS doesn't have
        // to arbitrate between a TapGesture and a DragGesture. That
        // arbitration is what was leaving selection broken after a
        // drag cycle: SwiftUI's tap path would stop firing once the
        // drag recognizer had completed a motion pass.
        //
        // Threshold: if final translation is under 3pt we treat the
        // interaction as a click; otherwise as a drag.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Only start tracking as a drag once motion actually
                // exceeds the threshold; a stationary mouse-down
                // should not create overlayDrag state or clear the
                // current selection.
                let moved = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
                guard moved || overlayDrag?.segmentID == seg.id else { return }

                let candidate = seg.startSeconds + Double(value.translation.width / pps)
                let (snapped, didSnap) = snapOverlayStart(
                    candidate: candidate,
                    overlayDuration: seg.durationSeconds,
                    totalDuration: totalDuration,
                    excludingSegmentID: seg.id
                )
                overlayDrag = OverlayDragState(
                    segmentID: seg.id,
                    originalComposedStart: seg.startSeconds,
                    translationX: value.translation.width,
                    snappedComposedStart: snapped,
                    didSnap: didSnap
                )
                // Close any open Set-Start-Time popover while dragging
                // (the popover and live drag would visually fight). We
                // intentionally do NOT clear `selectedOverlaySegmentID`
                // here — selection must persist across the drag so
                // Cmd+B / Delete keep targeting this segment.
                if overlayStartTimePopoverSegmentID == seg.id {
                    overlayStartTimePopoverSegmentID = nil
                }
            }
            .onEnded { value in
                // Classify the gesture at release time. Under the
                // 3pt threshold we treat it as a click and toggle
                // selection; otherwise we commit the drag as a move.
                let moved = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
                if !moved {
                    overlayDrag = nil
                    selectedOverlaySegmentID = (selectedOverlaySegmentID == seg.id) ? nil : seg.id
                    return
                }
                guard let drag = overlayDrag, drag.segmentID == seg.id else {
                    overlayDrag = nil
                    return
                }
                overlayDrag = nil
                if abs(drag.snappedComposedStart - drag.originalComposedStart) > 0.005 {
                    creativeActions.onMoveOverlaySegment(seg.id, drag.snappedComposedStart)
                }
            }
    }

    /// Compute a snap-aware composed-start for an overlay pill being
    /// dragged. Snap targets are: t=0, and every primary-segment
    /// boundary (start & end of each `segments` entry). The candidate
    /// is also clamped to ≥ 0. We do NOT clamp to `totalDuration`
    /// because overlay tracks are allowed to extend past the primary
    /// composition's end — the compositor pads in blank there.
    func snapOverlayStart(
        candidate: Double,
        overlayDuration: Double,
        totalDuration: Double,
        excludingSegmentID: UUID
    ) -> (Double, Bool) {
        let floor = max(0, candidate)
        var best = floor
        var bestDelta = Double.infinity
        var snapped = false

        var targets: [Double] = [0]
        var cursor = 0.0
        for s in segments {
            targets.append(cursor)
            cursor += quantizedSeconds(s.durationSeconds)
        }
        targets.append(cursor)

        for t in targets {
            let delta = abs(floor - t)
            if delta < Self.overlaySnapSeconds && delta < bestDelta {
                best = t
                bestDelta = delta
                snapped = true
            }
        }
        // No-op when the snapped value matches the value currently on
        // the pill — avoids spurious commits if the user click-drags
        // with <1px of movement.
        _ = overlayDuration
        _ = excludingSegmentID
        return (best, snapped)
    }

}
