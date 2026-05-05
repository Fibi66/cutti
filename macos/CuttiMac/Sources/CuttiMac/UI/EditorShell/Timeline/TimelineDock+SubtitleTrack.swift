// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Subtitle track (per-sentence blocks aligned to timeline)

    /// Composed start time (seconds) of the segment at `index`, summing the
    /// speed-adjusted durations of all preceding segments. Used to jump the
    /// playhead to the cue a user just clicked in the subtitle track.
    func composedStartSeconds(forSegment index: Int) -> Double {
        var offset = 0.0
        for i in 0..<min(index, segments.count) {
            offset += quantizedSeconds(segments[i].durationSeconds)
        }
        return offset
    }

    @ViewBuilder
    func subtitleEditPopover(for subtitleID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            T("Edit subtitle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if editingSubtitleSecondaryLocale != nil {
                T("Primary")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("", text: $editingSubtitleDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .frame(width: 320)
                    .onSubmit { commitSubtitleEdit(id: subtitleID) }

                T("Translation")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("", text: $editingSubtitleSecondaryDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .frame(width: 320)
                    .onSubmit { commitSubtitleEdit(id: subtitleID) }
            } else {
                TextField("", text: $editingSubtitleDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                    .frame(width: 320)
                    .onSubmit { commitSubtitleEdit(id: subtitleID) }
            }

            HStack {
                Spacer()
                Button {
                    cancelSubtitleEdit()
                } label: { T("Cancel") }
                .keyboardShortcut(.cancelAction)

                Button {
                    commitSubtitleEdit(id: subtitleID)
                } label: { T("Save") }
                .keyboardShortcut(.defaultAction)
                .disabled(editingSubtitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    func commitSubtitleEdit(id: UUID) {
        let trimmedPrimary = editingSubtitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrimary.isEmpty else { return }
        if let locale = editingSubtitleSecondaryLocale,
           let onEditBilingual = onEditSubtitleBilingualText {
            onEditBilingual(
                id,
                trimmedPrimary,
                editingSubtitleSecondaryDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                locale
            )
        } else {
            onEditSubtitleText(id, trimmedPrimary)
        }
        clearSubtitleEditingState()
    }

    func cancelSubtitleEdit() {
        clearSubtitleEditingState()
    }

    func clearSubtitleEditingState() {
        editingSubtitleID = nil
        editingSubtitleDraft = ""
        editingSubtitleSecondaryDraft = ""
        editingSubtitleSecondaryLocale = nil
    }

    /// Seed the popover state for `sub`, picking up the active bilingual
    /// secondary line (if any) so the user can edit both halves of a
    /// bilingual cue. Routed through one helper so double-click and the
    /// "Edit Text…" context menu stay in sync.
    func beginSubtitleEditing(for sub: SubtitleEntry) {
        editingSubtitleID = sub.id
        editingSubtitleDraft = sub.text
        if let bilingual = subtitleStyle.bilingual {
            let normalized = BilingualDisplayOptions.normalizeLocale(bilingual.secondaryLocale)
            if !normalized.isEmpty && onEditSubtitleBilingualText != nil {
                editingSubtitleSecondaryLocale = normalized
                editingSubtitleSecondaryDraft = sub.translations[normalized] ?? ""
                return
            }
        }
        editingSubtitleSecondaryLocale = nil
        editingSubtitleSecondaryDraft = ""
    }

    /// One subtitle cue promoted to the flat S1 lane, with its position
    /// already resolved into composed (timeline) time and its duration
    /// visually clamped so adjacent cues never overlap. Computing this
    /// centrally — rather than per-segment — is what makes hit-testing
    /// reliable: every pill lives directly under the S1 lane ZStack
    /// (not inside a nested HStack cell with `.offset` + clipping), so
    /// SwiftUI's gesture resolution sees a flat hierarchy.
    struct ComposedPill: Identifiable {
        let id: UUID
        let sub: SubtitleEntry
        let segmentIndex: Int
        /// Composed start time in seconds (timeline origin).
        let composedStart: Double
        /// Composed end time in seconds, ALREADY CLAMPED so it does not
        /// extend past the next cue's start. Keeps the rendered pill
        /// visually contiguous with its neighbor even when the
        /// underlying data has overlapping ranges.
        let composedEnd: Double
    }

    /// Flatten every segment's subtitles into one timeline-space list,
    /// sorted by composed start, with each pill's visible end clamped
    /// to the next pill's start. The underlying `SubtitleEntry` data
    /// is not mutated — this is render-time only; resize/move
    /// operations still go through the VM's neighbor clamp.
    ///
    /// Memoized against a cheap signature over the inputs this function
    /// actually reads — segment id/duration/speed and each cue's id +
    /// relative range. Playhead-only body re-evals hit the cache.
    func composedSubtitlePills() -> [ComposedPill] {
        let sig = subtitlePillsSignature()
        if sig == subtitlePillsCache.signature, let cached = subtitlePillsCache.pills as? [ComposedPill] {
            return cached
        }

        var raw: [(cue: SubtitleEntry, segIndex: Int, start: Double, end: Double)] = []
        var offset: Double = 0
        for (idx, seg) in segments.enumerated() {
            let speed = max(0.0001, seg.normalizedSpeedRate)
            let segDur = quantizedSeconds(seg.durationSeconds)
            for cue in seg.subtitles {
                let cs = quantizedSeconds(offset + min(segDur, max(0, cue.relativeStart / speed)))
                let ce = quantizedSeconds(offset + min(segDur, max(0, (cue.relativeStart + cue.relativeDuration) / speed)))
                if ce > cs + 0.001 {
                    raw.append((cue, idx, cs, ce))
                }
            }
            offset = quantizedSeconds(offset + segDur)
        }

        raw.sort { $0.start < $1.start }

        var pills: [ComposedPill] = []
        pills.reserveCapacity(raw.count)
        for i in 0..<raw.count {
            let cs = raw[i].start
            var ce = raw[i].end
            if i + 1 < raw.count {
                // Clamp to next cue's start so adjacent pills never
                // paint on top of each other. Leave a 1px visual gap
                // at typical zoom so the seam is visible.
                ce = min(ce, raw[i + 1].start)
            }
            if ce <= cs + 0.001 { continue }
            pills.append(ComposedPill(
                id: raw[i].cue.id,
                sub: raw[i].cue,
                segmentIndex: raw[i].segIndex,
                composedStart: cs,
                composedEnd: ce
            ))
        }

        subtitlePillsCache.signature = sig
        subtitlePillsCache.pills = pills
        return pills
    }

    /// Cheap fingerprint of exactly the inputs `composedSubtitlePills()`
    /// reads. Kept as a `String` so equality is a single comparison;
    /// the hot path (playhead ticks) does a single build + compare and
    /// exits before the O(n log n) flatten/sort.
    func subtitlePillsSignature() -> String {
        var s = ""
        s.reserveCapacity(segments.count * 64)
        for seg in segments {
            s += seg.id.uuidString
            s += ":"
            s += String(format: "%.4f", seg.durationSeconds)
            s += "@"
            s += String(format: "%.3f", seg.normalizedSpeedRate)
            s += "["
            for cue in seg.subtitles {
                s += cue.id.uuidString
                s += ","
                s += String(format: "%.4f", cue.relativeStart)
                s += "+"
                s += String(format: "%.4f", cue.relativeDuration)
                s += ";"
            }
            s += "]|"
        }
        return s
    }

    func subtitleTrack(width: CGFloat, pps: CGFloat) -> some View {
        let pills = composedSubtitlePills()
        return ZStack(alignment: .leading) {
            // Lane background — also the right-click target for
            // "Add subtitle here". Hover tracking captures the cursor
            // x so the context-menu action knows where to insert.
            //
            // NOTE: plain .onTapGesture (NOT .highPriorityGesture).
            // Previously this used highPriorityGesture(TapGesture)
            // to clear cue selection on empty-lane click, which
            // competed with pills' own highPriorityGestures and — via
            // SwiftUI's ambiguous multi-high-priority resolution —
            // caused the background to win over pills sitting on top
            // of it. Pills render LATER in the ZStack so they're in
            // front and receive hits first; the background's plain
            // tap only fires when a click actually misses every pill.
            RoundedRectangle(cornerRadius: 3)
                .fill(EditorShellStyle.panelInsetBackground)
                .frame(width: width, height: subtitleTrackHeight)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        subtitleLaneHoverComposedTime = pps > 0 ? Double(location.x) / Double(pps) : nil
                    case .ended:
                        subtitleLaneHoverComposedTime = nil
                    }
                }
                .onTapGesture {
                    onSelectSubtitle(nil)
                }
                .contextMenu {
                    Button {
                        if let t = subtitleLaneHoverComposedTime {
                            onAddSubtitle(t)
                        }
                    } label: { T("Add Subtitle Here") }
                    .disabled(subtitleLaneHoverComposedTime == nil)
                }

            // Render every cue as a direct child of the lane ZStack.
            // Flat hierarchy => reliable hit-testing.
            ForEach(pills) { pill in
                subtitleCuePill(pill: pill, pps: pps)
            }
        }
        .frame(width: width, height: subtitleTrackHeight, alignment: .leading)
    }

    /// One subtitle cue pill, with tap-to-select, double-tap-to-edit,
    /// drag-to-move, edge-drag-to-resize, and right-click context menu.
    @ViewBuilder
    func subtitleCuePill(pill: ComposedPill, pps: CGFloat) -> some View {
        let sub = pill.sub
        let segmentIndex = pill.segmentIndex

        // Live drag preview — applied only to the cue being dragged.
        let dragState = (subtitleDrag?.cueID == sub.id) ? subtitleDrag : nil
        let dragDx = dragState?.translationX ?? 0
        let isMoving = dragState?.kind == .move
        let isResizingLeading = dragState?.kind == .resizeLeading
        let isResizingTrailing = dragState?.kind == .resizeTrailing

        let baseStartX = CGFloat(quantizedSeconds(pill.composedStart)) * pps
        let baseEndX = CGFloat(quantizedSeconds(pill.composedEnd)) * pps
        let startX = baseStartX + (isMoving ? dragDx : (isResizingLeading ? dragDx : 0))
        let endX = baseEndX + (isMoving ? dragDx : (isResizingTrailing ? dragDx : 0))
        let w = max(8, endX - startX - 1)

        let isSelected = selectedSubtitleID == sub.id

        ZStack(alignment: .leading) {
            Text(sub.text)
                .font(.system(size: 7))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 2)
                .frame(width: w, height: subtitleTrackHeight - 6, alignment: .leading)
                .background(EditorShellStyle.obSub.opacity(isSelected ? 0.28 : 0.18))
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(
                            isSelected ? EditorShellStyle.obSub : EditorShellStyle.obSub.opacity(0.45),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                )

            // Leading resize handle (shown only when selected).
            if isSelected {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 6, height: subtitleTrackHeight - 6)
                    .overlay(
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 2, height: subtitleTrackHeight - 10)
                    )
                    .contentShape(Rectangle())
                    .highPriorityGesture(subtitleEdgeDragGesture(sub: sub, segmentIndex: segmentIndex, leading: true, pps: pps))
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }

                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 6, height: subtitleTrackHeight - 6)
                    .overlay(
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 2, height: subtitleTrackHeight - 10)
                    )
                    .contentShape(Rectangle())
                    .offset(x: max(0, w - 6))
                    .highPriorityGesture(subtitleEdgeDragGesture(sub: sub, segmentIndex: segmentIndex, leading: false, pps: pps))
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
            }
        }
        .frame(width: w, height: subtitleTrackHeight - 6, alignment: .leading)
        .contentShape(Rectangle())
        // Popover and contextMenu attached BEFORE .position so they
        // anchor to the pill's actual w×h frame. If attached after,
        // .position makes the view report its parent's full size
        // and the popover anchors to the middle of the timeline.
        .popover(
            isPresented: Binding(
                get: { editingSubtitleID == sub.id },
                set: { newValue in
                    if !newValue && editingSubtitleID == sub.id {
                        clearSubtitleEditingState()
                    }
                }
            ),
            arrowEdge: .top
        ) {
            subtitleEditPopover(for: sub.id)
        }
        .contextMenu {
            Button {
                onSelectSubtitle(sub.id)
                beginSubtitleEditing(for: sub)
            } label: { T("Edit Text…") }
            if let onEmphasize = onEmphasizeSubtitle {
                Button {
                    onEmphasize(sub.id)
                } label: { T("Emphasize words…") }
            }
            Divider()
            Button(role: .destructive) {
                onDeleteSubtitle(sub.id)
            } label: { T("Delete") }
        }
        .position(x: startX + w / 2, y: (subtitleTrackHeight - 6) / 2)
        // NOTE: we use .position (not .offset) because .offset does
        // NOT translate the hit-test region in this ZStack context,
        // which makes pills completely unclickable.
        //
        // count:2 MUST be attached before count:1 so SwiftUI checks
        // the double-click handler first for each tap sequence.
        .onTapGesture(count: 2) {
            onSelectSubtitle(sub.id)
            beginSubtitleEditing(for: sub)
        }
        .onTapGesture {
            onSelectSubtitle(sub.id)
        }
        // Drag-to-move armed only while selected. .simultaneousGesture
        // is documented to run "with the same priority" alongside
        // other gestures, so taps continue to fire. DragGesture's
        // minimumDistance:5 means a pure click won't activate it.
        // .subviews mask disables this gesture on unselected pills.
        .simultaneousGesture(
            subtitleBodyDragGesture(sub: sub, segmentIndex: segmentIndex, pps: pps),
            including: isSelected ? .all : .subviews
        )
    }

    func subtitleBodyDragGesture(sub: SubtitleEntry, segmentIndex: Int, pps: CGFloat) -> some Gesture {
        // minimumDistance: 5 so a slightly-shaky click (1-3 pixel
        // wobble) still counts as a tap and never escalates into a
        // no-op move. NLE conventions (FCP/Premiere/Resolve) all use
        // similar thresholds for clip body drag.
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                // A resize started first (highPriorityGesture on the
                // edge handles) — stay out of the way, don't overwrite
                // the drag preview with a .move kind.
                if subtitleResizingInFlight { return }
                subtitleDrag = SubtitleDragState(
                    cueID: sub.id,
                    kind: .move,
                    translationX: value.translation.width
                )
                if selectedSubtitleID != sub.id { onSelectSubtitle(sub.id) }
            }
            .onEnded { value in
                // If a resize owned this drag, do NOT commit a move on
                // release — that was the bug where the cue snapped to
                // the cursor's end position instead of staying resized.
                if subtitleResizingInFlight {
                    return
                }
                let segStart = composedStartSeconds(forSegment: segmentIndex)
                let segSpeed = max(0.0001, segments[segmentIndex].normalizedSpeedRate)
                let oldComposedStart = segStart + (sub.relativeStart / segSpeed)
                let newComposedStart = oldComposedStart + Double(value.translation.width) / Double(pps)
                subtitleDrag = nil
                onMoveSubtitle(sub.id, newComposedStart)
            }
    }

    func subtitleEdgeDragGesture(sub: SubtitleEntry, segmentIndex: Int, leading: Bool, pps: CGFloat) -> some Gesture {
        // coordinateSpace: .global anchors translation to the window,
        // not the resizing view's local frame. Otherwise the handle
        // moves along with the pill as it grows during the drag,
        // which shifts the gesture's local origin each frame and
        // creates a feedback loop — visible as the "crazy jitter"
        // when the user drags the leading handle leftward.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                subtitleResizingInFlight = true
                subtitleDrag = SubtitleDragState(
                    cueID: sub.id,
                    kind: leading ? .resizeLeading : .resizeTrailing,
                    translationX: value.translation.width
                )
            }
            .onEnded { value in
                let segStart = composedStartSeconds(forSegment: segmentIndex)
                let segSpeed = max(0.0001, segments[segmentIndex].normalizedSpeedRate)
                let composedStart = segStart + (sub.relativeStart / segSpeed)
                let composedEnd = composedStart + (sub.relativeDuration / segSpeed)
                let deltaSec = Double(value.translation.width) / Double(pps)
                let newComposed = leading ? composedStart + deltaSec : composedEnd + deltaSec
                subtitleDrag = nil
                onResizeSubtitle(sub.id, leading, newComposed)
                // Clear AFTER the body-gesture's own onEnded has had a
                // chance to run (SwiftUI dispatches both in the same
                // frame). A next-runloop reset is enough; both have
                // already read the flag by then.
                DispatchQueue.main.async {
                    subtitleResizingInFlight = false
                }
            }
    }

}
