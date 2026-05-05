// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Video track

    /// Payload string for the `.draggable` modifier on a primary segment
    /// pill. When the dragged segment is part of a multi-selection
    /// (cmd-/shift-click), we emit a single composite payload encoding
    /// every selected ID so that drop targets — in particular the AI
    /// chat composer — can attach ALL of them at once. Otherwise emit
    /// the bare UUID for backward compatibility with the existing
    /// reorder drop targets.
    ///
    /// Format (multi): `"multi:<uuid1>|<uuid2>|…"`. The `multi:` prefix
    /// is deliberately distinct from `media:` (MediaBrowser clip drop)
    /// so the reorder path ignores it instead of treating it as a
    /// malformed single-segment drag.
    func dragPayload(for segment: TimelineSegment) -> String {
        if selectedSegmentIDs.contains(segment.id) && selectedSegmentIDs.count > 1 {
            // Preserve timeline order so attach chips land in the same
            // order they appear on V1, independent of click order.
            let ordered = segments
                .map(\.id)
                .filter { selectedSegmentIDs.contains($0) }
            return "multi:" + ordered.map(\.uuidString).joined(separator: "|")
        }
        return segment.id.uuidString
    }

    func dragPreviewLabel(for segment: TimelineSegment, at index: Int) -> String {
        if selectedSegmentIDs.contains(segment.id) && selectedSegmentIDs.count > 1 {
            return "\(selectedSegmentIDs.count) segments"
        }
        return "Segment \(index + 1)"
    }

    /// Industry-standard vertical drop-insertion bar (à la Final Cut
    /// Pro / Premiere / Resolve). 3pt-wide accent line with a soft
    /// glow and an upward-pointing caret, revealed with a spring
    /// animation when a drag hovers the corresponding gap. Rendered
    /// as a leading-edge overlay on the target segment so its x
    /// position is exact without any coordinate math.
    @ViewBuilder
    func insertionIndicator(visible: Bool) -> some View {
        ZStack {
            // Soft glow
            Rectangle()
                .fill(EditorShellStyle.accentSolid)
                .frame(width: 10)
                .blur(radius: 6)
                .opacity(0.55)
            // Crisp core line
            Rectangle()
                .fill(EditorShellStyle.accentSolid)
                .frame(width: 3)
                .shadow(color: EditorShellStyle.accentSolid.opacity(0.9), radius: 3)
            // Caret cap at top so the eye locks onto the exact gap
            Triangle()
                .fill(EditorShellStyle.accentSolid)
                .frame(width: 10, height: 6)
                .offset(y: -(videoTrackHeight / 2) - 2)
        }
        .frame(width: 12, height: videoTrackHeight + 6)
        .offset(x: -6) // center the bar ON the gap, not inside segment
        .opacity(visible ? 1 : 0)
        .scaleEffect(y: visible ? 1 : 0.85, anchor: .center)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: visible)
        .allowsHitTesting(false)
    }

    // MARK: - FCP-style clip chrome

    /// Whether a segment has any user-applied adjustment worth
    /// surfacing as an "A" (auto-enhance) badge on its title bar,
    /// mirroring Final Cut's effect indicator.
    func segmentHasFX(_ segment: TimelineSegment) -> Bool {
        segment.effects.rotation != 0
            || segment.effects.flipHorizontal
            || segment.effects.flipVertical
            || abs(segment.normalizedSpeedRate - 1.0) > 0.001
            || segment.volumeLevel < 0.999
            || segment.isVideoHidden
    }

    /// Final Cut-style title bar: a thin dark-navy strip at the
    /// top of each clip holding an optional "A" effects badge.
    /// Sits above the filmstrip and below selection chrome. The
    /// whole bar is suppressed when the clip has no adjustments,
    /// so bare clips render clean without a dead strip on top.
    @ViewBuilder
    func clipTitleBar(hasFX: Bool, width: CGFloat) -> some View {
        if hasFX {
            HStack(spacing: 3) {
                Text("A")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(EditorShellStyle.accentSolid.opacity(0.85))
                    )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(width: max(0, width), height: EditorShellStyle.timelineClipTitleHeight)
            .background(EditorShellStyle.timelineClipTitleBar)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: EditorShellStyle.timelineClipRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: EditorShellStyle.timelineClipRadius
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }

    func videoTrack(width: CGFloat, pps: CGFloat) -> some View {        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(EditorShellStyle.panelInsetBackground)
                .frame(width: width)

            if !segments.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        // Layout width MUST be the true temporal width
                        // (duration × pps). If we clamp it up to a
                        // minimum pixel value, every subsequent pill —
                        // and, worse, the overlay/caption lanes and the
                        // playhead — stop agreeing about where that
                        // clip sits on the timeline. Short clips still
                        // get a minimum visible rectangle via
                        // `visualWidth`, which is painted inside the
                        // (possibly narrower) slot.
                        let segWidth = max(0, CGFloat(quantizedSeconds(segment.durationSeconds)) * pps)
                        let gap = EditorShellStyle.timelineClipGap
                        // Visual width must never exceed the layout slot —
                        // if we floor to an 8pt minimum for tiny clips, the
                        // thumbnail bleeds past the slot boundary into the
                        // neighboring pill's slot. That makes the playhead
                        // (which moves in layout coordinates) appear to
                        // enter the NEXT pill while the preview (driven by
                        // composition time, which matches the layout
                        // boundary) is still playing THIS pill. Show a
                        // short pill as it actually is — sub-pixel if need
                        // be — rather than inflating and desyncing.
                        let visualWidth = max(0, segWidth - gap)
                        let isSelected = selectedSegmentIDs.contains(segment.id)
                        let isPrimarySelected = primarySelectedSegmentID == segment.id
                        let segProxy = proxyURL(for: segment)
                        let segRecord = records.first { $0.id == segment.sourceVideoID }
                        let segIsImage = segRecord?.kind == .image

                        // Reference layout (OBTrack tone="video" thumb):
                        //   - translucent colour33 body fill
                        //   - colour88 1px border
                        //   - top 70% of the clip is the thumbstrip /
                        //     filmstrip
                        //   - bottom 30% shows the clip label (e.g.
                        //     "intro_A", "interview · quote 1") on the
                        //     panel background, font size 9, ellipsis
                        let laneColor = EditorShellStyle.obV1
                        // Filmstrip always fills the entire V1 row.
                        // Subtitle text belongs to the dedicated S1
                        // lane; V1 never paints cue text, regardless
                        // of whether S1 is currently visible.
                        let thumbHeight = videoTrackHeight

                        ZStack(alignment: .topLeading) {
                            // Body tint (ref: `${color}33` ≈ 20% alpha)
                            RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                                .fill(laneColor.opacity(0.20))
                                .frame(width: visualWidth, height: videoTrackHeight)

                            // Filmstrip occupies the TOP 70% so the
                            // bottom strip is reserved for the label,
                            // matching OBTrack's thumb-then-label stack.
                            VStack(spacing: 0) {
                                Group {
                                    if segIsImage, let segRecord {
                                        ImageAssetThumbnail(record: segRecord, projectRoot: projectRoot)
                                            .opacity(segment.isVideoHidden ? 0.28 : 1)
                                    } else if let segProxy {
                                        SegmentFilmstrip(
                                            videoURL: segProxy,
                                            startSeconds: segment.range.startSeconds,
                                            endSeconds: segment.range.endSeconds,
                                            width: visualWidth,
                                            height: thumbHeight
                                        )
                                        .opacity(segment.isVideoHidden ? 0.28 : 1)
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.25))
                                    }
                                }
                                .frame(width: visualWidth, height: thumbHeight)
                                .clipped()

                                Spacer(minLength: 0)
                            }
                            .frame(width: visualWidth, height: videoTrackHeight, alignment: .top)
                            .clipShape(RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius))

                            // Hidden-video ("cut") hatch: red diagonal
                            // stripes + dashed red border. Matches the
                            // Obsidian reference's `c.cut` state.
                            if segment.isVideoHidden {
                                RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                                    .fill(Color.black.opacity(0.45))
                                    .frame(width: visualWidth, height: videoTrackHeight)
                                DiagonalHatch()
                                    .stroke(EditorShellStyle.obRed.opacity(0.55), lineWidth: 1)
                                    .clipShape(RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius))
                                    .frame(width: visualWidth, height: videoTrackHeight)
                                    .allowsHitTesting(false)
                                RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                                    .strokeBorder(
                                        EditorShellStyle.obRed,
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                    )
                                    .frame(width: visualWidth, height: videoTrackHeight)
                                    .allowsHitTesting(false)
                            }

                            // Lane-colour border (ref: `${color}88`
                            // ≈ 53% alpha, 1px). Thickens + switches
                            // to accent on selection.
                            RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                                .strokeBorder(
                                    isSelected
                                        ? EditorShellStyle.timelineClipBorderSelected
                                        : laneColor.opacity(0.53),
                                    lineWidth: isPrimarySelected
                                        ? EditorShellStyle.timelineClipBorderSelectedWidth
                                        : (isSelected ? EditorShellStyle.timelineClipBorderSelectedWidth : 1)
                                )
                                .frame(width: visualWidth, height: videoTrackHeight)

                            // Clip text intentionally NOT rendered in
                            // V1. Subtitle cues live exclusively on the
                            // S1 lane; hiding S1 must not resurrect the
                            // text inside the video clip.

                            // Pending-proposal diff hint: dashed overlay
                            // colored by the kind of change Agent would
                            // apply. Matches OBTrack's `ai: true` styling
                            // (`1px dashed ${accent}`) in the reference.
                            if let tint = pendingDiffTint(for: segment.id) {
                                RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                                    .fill(tint.opacity(0.18))
                                    .frame(width: visualWidth, height: videoTrackHeight)
                                    .allowsHitTesting(false)
                                RoundedRectangle(cornerRadius: EditorShellStyle.timelineClipRadius)
                                    .strokeBorder(
                                        tint,
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                    )
                                    .frame(width: visualWidth, height: videoTrackHeight)
                                    .allowsHitTesting(false)
                            }

                            if abs(segment.normalizedSpeedRate - 1.0) > 0.001 {
                                Text("\(AIActionExecutor.formatRate(segment.normalizedSpeedRate))x")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.72))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                    .padding(4)
                            }

                            if !segment.alternatives.isEmpty {
                                AlternativeTakesBadge(
                                    segment: segment,
                                    isOpen: alternativesPopoverSegmentID == segment.id,
                                    onOpen: {
                                        alternativesPopoverSegmentID = segment.id
                                    },
                                    onDismiss: {
                                        if alternativesPopoverSegmentID == segment.id {
                                            alternativesPopoverSegmentID = nil
                                        }
                                    },
                                    onSelect: { takeID in
                                        creativeActions.onSwapAlternativeTake(segment.id, takeID)
                                        alternativesPopoverSegmentID = nil
                                    }
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(4)
                            }

                            // FCP-style effects badge bar (only
                            // shown when the clip has adjustments).
                            clipTitleBar(
                                hasFX: segmentHasFX(segment),
                                width: visualWidth
                            )

                            // Trim handles on selected segment. Handles
                            // hang OFF the clip edges (leading extends
                            // leftward past x=0, trailing extends rightward
                            // past the clip's rendered right edge) so the
                            // handle chrome doesn't overlap the clip's
                            // first/last frames — matches CapCut's trim UI
                            // and lets the playhead sit flush with the
                            // segment's true left edge without being
                            // obscured by the leading handle.
                            if isPrimarySelected && hasSingleSelection {
                                trimHandle(edge: .leading, index: index, height: videoTrackHeight, pps: pps)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .offset(x: -TrimHandleView.handleWidth)
                                trimHandle(edge: .trailing, index: index, height: videoTrackHeight, pps: pps)
                                    .frame(width: visualWidth, alignment: .trailing)
                                    .offset(x: TrimHandleView.handleWidth)
                            }
                        }
                        .frame(width: segWidth, height: videoTrackHeight, alignment: .leading)
                        .zIndex(isPrimarySelected ? 1 : 0)
                        .onTapGesture {
                            onSegmentTap(index, NSApp.currentEvent?.modifierFlags ?? [])
                        }
                        .contextMenu {
                            Button {
                                onSplitAtPlayhead(playheadSeconds)
                            } label: { T("Split at Playhead") }
                            Button(selectedSegmentCount > 1 && isSelected ? L("Delete Selected Segments") : L("Delete Segment"), role: .destructive) {
                                if selectedSegmentCount > 1 && isSelected {
                                    onDeleteSelectedSegments()
                                } else {
                                    onDeleteSegment(index)
                                }
                            }
                            Divider()
                            Button {
                                creativeActions.onSaveSegmentToHighlights(segment.id)
                            } label: { T("Save to Highlights") }
                            .disabled(!creativeActions.canSaveSegmentToHighlights(segment.id))
                            Divider()
                            Button(segment.isVideoHidden ? (segIsImage ? L("Show Image") : L("Show Video")) : (segIsImage ? L("Hide Image") : L("Hide Video"))) {
                                creativeActions.onToggleSegmentVideoHidden(segment.id)
                            }
                            if !segIsImage {
                                Button(segment.volumeLevel > 0.0001 ? L("Mute Audio") : L("Unmute Audio")) {
                                    creativeActions.onToggleSegmentAudioMuted(segment.id)
                                }
                                if segment.linkedSegmentID == nil {
                                    Button {
                                        creativeActions.onDetachAudio(segment.id)
                                    } label: { T("Detach Audio") }
                                } else {
                                    Button {
                                        creativeActions.onReattachAudio(segment.id)
                                    } label: { T("Reattach Audio") }
                                }
                            }
                            Divider()
                            if index + 1 < segments.count {
                                Button {
                                    creativeActions.onAddCrossfadeToNext(index, 0.5)
                                } label: { T("Add Crossfade to Next (0.5s)") }
                            }
                            if index > 0 {
                                Button {
                                    creativeActions.onAddCrossfadeFromPrevious(index, 0.5)
                                } label: { T("Add Crossfade from Previous (0.5s)") }
                            }
                            if let gapBefore = creativeActions.restorableGapBefore(index) {
                                Button(L("Restore %@s cut before this clip", formatRestoreGap(gapBefore))) {
                                    creativeActions.onRestoreCutBefore(index)
                                }
                            }
                            if let gapAfter = creativeActions.restorableGapAfter(index) {
                                Button(L("Restore %@s cut after this clip", formatRestoreGap(gapAfter))) {
                                    creativeActions.onRestoreCutAfter(index)
                                }
                            }
                            Divider()
                            Menu(L("Transform")) {
                                Button { onRotate(index) } label: { T("Rotate 90°") }
                                Button(segment.effects.flipHorizontal ? L("✓ Flip Horizontal") : L("Flip Horizontal")) { onFlipH(index) }
                                Button(segment.effects.flipVertical ? L("✓ Flip Vertical") : L("Flip Vertical")) { onFlipV(index) }
                            }
                            Menu(L("Speed")) {
                                let currentRate = segment.normalizedSpeedRate
                                let applyToMulti = selectedSegmentCount > 1 && isSelected
                                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { rate in
                                    let isCurrent = !applyToMulti && abs(currentRate - rate) < 0.001
                                    Button(isCurrent ? "✓ \(AIActionExecutor.formatRate(rate))×" : "\(AIActionExecutor.formatRate(rate))×") {
                                        if applyToMulti {
                                            onSetSelectedSpeed(rate)
                                        } else {
                                            onSetSegmentSpeed(index, rate)
                                        }
                                    }
                                }
                            }
                            if !segment.effects.isDefault {
                                Button { onResetEffects(index) } label: { T("Reset Effects") }
                            }
                        }
                        .draggable(dragPayload(for: segment)) {
                            Text(dragPreviewLabel(for: segment, at: index))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(EditorShellStyle.accentSolid.opacity(0.85))
                                .foregroundStyle(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            defer { primaryInsertionIndex = nil }
                            guard let dragged = items.first else { return false }
                            // Highlights panel drag → insert a slice of
                            // the source clip BEFORE the segment we
                            // dropped on. Use the dedicated
                            // `highlight:` namespace so the slice path
                            // stays distinct from the whole-clip
                            // `media:` path below.
                            if let parsed = AICopilotPresentation.parseHighlightPayload(dragged) {
                                creativeActions.onInsertSourceSliceAtPrimaryIndex(
                                    parsed.recordID,
                                    parsed.start,
                                    parsed.end,
                                    index
                                )
                                return true
                            }
                            // MediaBrowser drag payload → insert a new
                            // primary segment BEFORE the segment we
                            // dropped on. Prefix keeps media drops from
                            // colliding with the segment-reorder path
                            // below (which uses bare segment UUIDs).
                            if dragged.hasPrefix("media:"),
                               let uuid = UUID(uuidString: String(dragged.dropFirst("media:".count))) {
                                creativeActions.onInsertMediaAtPrimaryIndex(uuid, index)
                                return true
                            }
                            // Existing segment-reorder path.
                            guard let sourceIndex = segments.firstIndex(where: { $0.id.uuidString == dragged }) else {
                                return false
                            }
                            let destIndex = sourceIndex < index ? index + 1 : index
                            onMoveSegment(IndexSet(integer: sourceIndex), destIndex)
                            return true
                        } isTargeted: { hovering in
                            // Show the vertical "will-insert-here" bar at
                            // the leading edge of this segment (= gap
                            // between segment[index-1] and segment[index])
                            // while a drag hovers. Works for both media
                            // drops and intra-timeline reorders since both
                            // insert before the hovered segment.
                            if hovering {
                                primaryInsertionIndex = index
                            } else if primaryInsertionIndex == index {
                                primaryInsertionIndex = nil
                            }
                        }
                        .overlay(alignment: .leading) {
                            insertionIndicator(visible: primaryInsertionIndex == index)
                        }
                        .overlay(alignment: .trailing) {
                            // Append-at-end indicator lives on the
                            // trailing edge of the LAST segment so the
                            // user gets a clear "drop here to append"
                            // cue when their cursor is past the last
                            // clip but still over the V1 row.
                            if index == segments.count - 1 {
                                insertionIndicator(visible: primaryInsertionIndex == segments.count)
                            }
                        }

                        // No inter-segment separator: the 2pt visual
                        // gap between clips is already baked into
                        // `visualWidth = segWidth - timelineClipGap`,
                        // so adding another 2pt rectangle here would
                        // (a) double the apparent gap on V1, and
                        // (b) shift V1's cumulative x by 2pt per
                        // segment relative to A1, which has no
                        // separator — that's the source of the
                        // audio-drifts-forward bug.
                    }
                }
            } else if let proxyURL {
                FilmstripView(
                    videoURL: proxyURL,
                    duration: durationSeconds,
                    segments: [],
                    width: width,
                    height: videoTrackHeight,
                    pointsPerSecond: pps
                )
            }
        }
        .frame(width: width, height: videoTrackHeight, alignment: .leading)
    }

    /// Format a restorable-gap duration for the right-click menu
    /// label. Sub-10s gaps get one decimal ("2.4"), longer gaps
    /// round to whole seconds ("12") — the surrounding string
    /// supplies the unit suffix per locale.
    func formatRestoreGap(_ seconds: Double) -> String {
        if seconds < 10 {
            return String(format: "%.1f", seconds)
        }
        return String(Int(seconds.rounded()))
    }

}
