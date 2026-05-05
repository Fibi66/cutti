import SwiftUI
import AVFoundation
import CuttiKit

/// Descript-style transcript-first editor.
///
/// Renders `composedSubtitles` grouped into paragraphs by speaker runs.
/// Each cue is clickable (seeks the player), inline-editable, and can be
/// deleted — deletion calls through to `AIAction.deleteRange` on the
/// corresponding composed time range so the video clip is cut alongside
/// the text. A find/replace bar performs a global substring replace.
struct TranscriptView: View {
    let cues: [ComposedSubtitle]
    let tombstones: [SubtitleTombstone]
    let speakers: [Speaker]
    let playheadSeconds: Double

    /// Seek the player to a composed time. Called when the user clicks a cue.
    var onSeek: (Double) -> Void
    /// Commit an inline text edit for the cue.
    var onEditCue: (UUID, String) -> Void
    /// Delete one or more cues (and the video ranges they cover) in a
    /// single undoable step. Empty arrays are a no-op.
    var onDeleteCues: ([UUID]) -> Void
    /// Resurrect a tombstoned cue — re-inserts the original source clip
    /// onto the primary track and removes the strikethrough entry.
    var onRestoreTombstone: (UUID) -> Void
    /// Global find-and-replace. Returns count of changed cues.
    var onReplace: (String, String, Bool) -> Int
    /// Rename a speaker by ID. Empty string resets to the default
    /// "Speaker N" label. Persisted by the view model.
    var onRenameSpeaker: (Int, String) -> Void = { _, _ in }
    /// Recolor a speaker by ID. Hex string (`#RRGGBB`) or nil to reset
    /// to the palette default. Persisted by the view model.
    var onRecolorSpeaker: (Int, String?) -> Void = { _, _ in }
    /// Resize a speaker's on-video name label. Point size or nil to
    /// reset to the renderer default. Persisted by the view model.
    var onResizeSpeakerLabel: (Int, Double?) -> Void = { _, _ in }
    /// Reassign one or more cues to an existing speaker. Called from
    /// the cue right-click menu when diarization mislabeled the line.
    /// IDs are the cues to mutate; `speakerID` is the target.
    var onAssignSpeaker: ([UUID], Int) -> Void = { _, _ in }
    /// Reassign one or more cues to a brand-new speaker (next free
    /// "Speaker N+1") — for cues whose speaker isn't in the current
    /// registry yet.
    var onAssignNewSpeaker: ([UUID]) -> Void = { _ in }
    /// Split a cue into two pieces at a UTF-16 character offset within
    /// the cue's text. The offset comes from the "Split…" popover —
    /// each clickable boundary corresponds to a token gap. The view
    /// model uses the wordTimings-aware `SubtitleEntry.split` helper
    /// in CuttiKit to get the time boundary right.
    var onSplitCueAtOffset: (UUID, Int) -> Void = { _, _ in }
    /// Merge two or more cues into one. The view passes the cue ids in
    /// any order; the view model is responsible for sorting + adjacency
    /// validation (must be a contiguous run within one
    /// `TimelineSegment.subtitles[]` and share the same speaker).
    var onMergeCues: ([UUID]) -> Void = { _ in }

    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var findCaseSensitive: Bool = false
    @State private var showFindBar: Bool = false
    @State private var replaceStatus: String?
    /// Multi-selection of live cues. Tombstones are never selectable.
    @State private var selectedCueIDs: Set<UUID> = []
    /// Anchor cue for shift-click range extension. Tracks the most
    /// recent single-click so shift+click selects "from anchor to here".
    @State private var selectionAnchorID: UUID?
    @State private var editingCueID: UUID?
    @State private var editingDraft: String = ""
    /// Cue currently showing the "Split…" popover (set from the
    /// right-click menu). Nil while no popover is open. Anchors a
    /// SwiftUI `.popover` over the cue text and clears itself when
    /// the popover dismisses or the user picks an offset.
    @State private var splittingCueID: UUID?
    /// Speaker ID currently being renamed (popover anchor + TextField focus).
    @State private var renamingSpeakerID: Int?
    @State private var renameDraft: String = ""
    /// Forces the TextField inside the rename popover to grab keyboard
    /// focus when the popover opens. Without this the popover host
    /// window doesn't make the field first responder, and keystrokes
    /// fall through to the transcript view's `.onDeleteCommand` (and
    /// other ancestor key handlers), which in turn mutate the speakers
    /// array out from under the popover — collapsing it on every keypress.
    @FocusState private var renameFieldFocused: Bool

    /// Item rendered inline in a paragraph: either a live cue or a
    /// tombstoned (deleted but still-visible) cue. Drives the flowing
    /// layout so strikethroughs sit in their original reading position.
    fileprivate enum Item: Identifiable {
        case cue(ComposedSubtitle)
        case tomb(SubtitleTombstone)

        var id: UUID {
            switch self {
            case .cue(let c): return c.id
            case .tomb(let t): return t.id
            }
        }
        /// Source-video this cue/tombstone was transcribed from, when
        /// known. Nil only for legacy cues built without source
        /// metadata.
        var sourceVideoID: UUID? {
            switch self {
            case .cue(let c): return c.sourceVideoID
            case .tomb(let t): return t.sourceVideoID
            }
        }
        /// Pre-speed source-video start time. **Stable across timeline
        /// edits** — used as the primary reading-order key so a
        /// tombstone keeps sitting where the deleted words used to be,
        /// instead of drifting when surrounding live cues shift left
        /// as earlier ranges get deleted.
        var sourceStart: Double? {
            switch self {
            case .cue(let c): return c.sourceStart
            case .tomb(let t): return t.sourceStart
            }
        }
        /// Fallback ordering anchor in composed time, used only when
        /// source coordinates are unavailable (legacy cues / tests).
        var composedAnchor: Double {
            switch self {
            case .cue(let c): return c.startSeconds
            case .tomb(let t): return t.originalComposedStart
            }
        }
        var speakerID: Int? {
            switch self {
            case .cue(let c): return c.speakerID
            case .tomb(let t): return t.speakerID
            }
        }
        /// Composed-time start. For tombstones we use the original
        /// pre-deletion span so the paragraph timecode reads naturally
        /// even after the user has deleted some cues.
        var composedStart: Double {
            switch self {
            case .cue(let c): return c.startSeconds
            case .tomb(let t): return t.originalComposedStart
            }
        }
        var composedEnd: Double {
            switch self {
            case .cue(let c): return c.endSeconds
            case .tomb(let t): return t.originalComposedEnd
            }
        }
    }

    private struct Paragraph: Identifiable {
        /// Stable across `paragraphs` recomputations: derived from the
        /// first item's id (cue or tombstone id, both UUIDs that live
        /// on the underlying SubtitleEntry / SubtitleTombstone, not
        /// generated per-render). Without this, a fresh `UUID()` would
        /// be minted every time the body re-evaluates — and because
        /// `playheadSeconds` updates ~30× per second during playback,
        /// every render produced an all-new `[Paragraph]` array. The
        /// `ForEach(paragraphs)` diff then treated every paragraph as
        /// brand-new, the LazyVStack tore down and rebuilt every row,
        /// and the ScrollView's offset reset to the top — yanking the
        /// transcript away from the karaoke-highlighted cue.
        ///
        /// When a paragraph genuinely splits or merges (e.g. speaker
        /// diarization adds a label, or the user inserts a different
        /// speaker in the middle), the first-item id legitimately
        /// changes and the paragraph rebuilds — which is what we want.
        let id: UUID
        let speakerID: Int?
        var items: [Item]
    }

    /// Flat ordered list interleaving live cues and tombstones.
    ///
    /// **Ordering key is source-video time**, not composed time. A
    /// tombstone remembers the stable source-video range of the
    /// deleted cue (`sourceStart`), and every live cue is rebuilt with
    /// the same field in `MediaCoreViewModel.rebuildComposedSubtitles`.
    /// Using source time means a tombstone appears in the same reading
    /// position it occupied before the delete even after subsequent
    /// deletes shift all later live cues' composed-time positions
    /// left. Using composed time (the previous approach) mixed
    /// "current-timeline" live-cue positions with "moment-of-delete"
    /// tombstone positions — two different coordinate systems — and
    /// produced the "my deleted cues get randomly reinserted into
    /// other paragraphs" bug.
    ///
    /// For multi-source projects, sources are grouped in the order
    /// their first item currently appears (by composed time), and
    /// within a source items are ordered by source-video start. Items
    /// without source metadata (legacy data or test fixtures) fall
    /// back to composed-time ordering.
    private var orderedItems: [Item] {
        var items: [Item] = cues.map(Item.cue)
        items.append(contentsOf: tombstones.map(Item.tomb))

        // First-appearance composed time per source video, so multiple
        // imported clips stay grouped in the order the user sees them
        // on the primary track.
        var sourceOrder: [UUID: Double] = [:]
        for item in items {
            guard let sid = item.sourceVideoID else { continue }
            let c = item.composedAnchor
            if sourceOrder[sid] == nil || c < sourceOrder[sid]! {
                sourceOrder[sid] = c
            }
        }

        items.sort { a, b in
            switch (a.sourceVideoID, b.sourceVideoID) {
            case let (sa?, sb?) where sa == sb:
                let sAStart = a.sourceStart ?? a.composedAnchor
                let sBStart = b.sourceStart ?? b.composedAnchor
                return sAStart < sBStart
            case let (sa?, sb?):
                let oa = sourceOrder[sa] ?? .infinity
                let ob = sourceOrder[sb] ?? .infinity
                if oa != ob { return oa < ob }
                return (a.sourceStart ?? 0) < (b.sourceStart ?? 0)
            default:
                return a.composedAnchor < b.composedAnchor
            }
        }
        return items
    }

    /// Group adjacent items with the same `speakerID` into a paragraph so
    /// the reader sees Descript-style speaker blocks rather than a flat
    /// list. Consecutive `nil` speakers collapse into one unlabeled block.
    private var paragraphs: [Paragraph] {
        var result: [Paragraph] = []
        for item in orderedItems {
            let effective = effectiveSpeakerID(item.speakerID)
            if let last = result.last, last.speakerID == effective {
                result[result.count - 1].items.append(item)
            } else {
                result.append(Paragraph(id: item.id, speakerID: effective, items: [item]))
            }
        }
        return result
    }

    /// Coerce a possibly-nil speakerID into the registry default. When
    /// diarization hasn't run we still want every paragraph to render
    /// with a real avatar + editable name (synthesized as Speaker 1
    /// upstream in `MediaCoreViewModel`), instead of a "?" placeholder.
    private func effectiveSpeakerID(_ raw: Int?) -> Int? {
        if let raw { return raw }
        return speakers.first?.id
    }

    private func speaker(for id: Int?) -> Speaker? {
        let target = effectiveSpeakerID(id)
        guard let target else { return nil }
        return speakers.first(where: { $0.id == target })
    }

    private func isPlaying(_ cue: ComposedSubtitle) -> Bool {
        playheadSeconds >= cue.startSeconds && playheadSeconds < cue.endSeconds
    }

    /// Handle a click on a live cue with the standard macOS modifier
    /// conventions: plain click = single select + seek; cmd-click =
    /// toggle; shift-click = extend range from anchor (in reading
    /// order) across all live cues between the anchor and the clicked
    /// cue. Tombstones interleaved in the same paragraph are skipped
    /// for range expansion — they aren't selectable.
    private func handleCueClick(id: UUID, modifiers: EventModifiers) {
        if editingCueID == id { return }

        if modifiers.contains(.shift), let anchor = selectionAnchorID {
            let liveIDs = cues.map(\.id)
            if let a = liveIDs.firstIndex(of: anchor),
               let b = liveIDs.firstIndex(of: id) {
                let range = a <= b ? a...b : b...a
                selectedCueIDs = Set(liveIDs[range])
                if let cue = cues.first(where: { $0.id == id }) { onSeek(cue.startSeconds) }
                return
            }
        }
        if modifiers.contains(.command) {
            if selectedCueIDs.contains(id) {
                selectedCueIDs.remove(id)
            } else {
                selectedCueIDs.insert(id)
                selectionAnchorID = id
            }
            return
        }
        selectedCueIDs = [id]
        selectionAnchorID = id
        if let cue = cues.first(where: { $0.id == id }) {
            onSeek(cue.startSeconds)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if showFindBar { findReplaceBar }
            if !speakers.isEmpty && (!cues.isEmpty || !tombstones.isEmpty) {
                speakerBar
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if cues.isEmpty && tombstones.isEmpty {
                            emptyState
                        } else {
                            ForEach(paragraphs) { para in
                                paragraphBlock(para)
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: currentCueID) { _, newID in
                    if let id = newID {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(EditorShellStyle.panelBackground)
        .onDeleteCommand {
            // Don't hijack delete while the rename popover is open —
            // the popover's TextField needs the key to backspace.
            guard renamingSpeakerID == nil else { return }
            guard editingCueID == nil, !selectedCueIDs.isEmpty else { return }
            onDeleteCues(Array(selectedCueIDs))
            selectedCueIDs.removeAll()
            selectionAnchorID = nil
        }
    }

    private var currentCueID: UUID? {
        cues.first(where: isPlaying)?.id
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .foregroundStyle(.secondary)
            T("Transcript")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(String(format: L("%d cues"), cues.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showFindBar.toggle()
                if !showFindBar { replaceStatus = nil }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help(L("Find & Replace (⌘F)"))
            .keyboardShortcut("f", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var findReplaceBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(L("Find"), text: $findText)
                    .textFieldStyle(.roundedBorder)
                TextField(L("Replace"), text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("Aa"), isOn: $findCaseSensitive)
                    .toggleStyle(.button)
                    .help(L("Case-sensitive match"))
                Button {
                    let n = onReplace(findText, replaceText, findCaseSensitive)
                    replaceStatus = n > 0
                        ? String(format: L("Replaced in %d cue(s)"), n)
                        : L("No matches")
                } label: { T("Replace All") }
                .disabled(findText.isEmpty)
            }
            if let status = replaceStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("No subtitles yet")
                .font(.headline)
            T("Transcribe a video from the Inspector panel to see the transcript here. You can then click text to jump, delete cues to cut video, and use Find & Replace.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact horizontal bar listing every detected (or default)
    /// speaker as a tappable avatar + name chip. Clicking a chip opens
    /// the rename popover; the new name propagates instantly to every
    /// paragraph below since both render off the same `speakers`
    /// registry.
    private var speakerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                T("Speakers")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(speakers) { sp in
                    Button { beginRename(sp) } label: {
                        HStack(spacing: 6) {
                            ZStack {
                                Circle().fill(sp.color.opacity(0.85))
                                Text(speakerInitials(sp.displayName))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 22, height: 22)
                            Text(sp.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(sp.color.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(sp.color.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(L("Click to rename speaker"))
                    .popover(
                        isPresented: Binding(
                            get: { renamingSpeakerID == sp.id },
                            set: { if !$0 { renamingSpeakerID = nil } }
                        ),
                        arrowEdge: .bottom
                    ) {
                        renamePopover()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Composed-time span for a paragraph, from its first item's start
    /// to its last item's end. Returns nil for empty paragraphs.
    private func paragraphSpan(_ para: Paragraph) -> (start: Double, end: Double)? {
        guard let first = para.items.first, let last = para.items.last else { return nil }
        return (first.composedStart, last.composedEnd)
    }

    @ViewBuilder
    private func paragraphBlock(_ para: Paragraph) -> some View {
        let sp = speaker(for: para.speakerID)
        let accent = sp?.color ?? .secondary
        HStack(alignment: .top, spacing: 10) {
            // Speaker avatar — colored disc with initial(s). Clickable
            // to open the rename popover.
            Button {
                if let sp { beginRename(sp) }
            } label: {
                ZStack {
                    Circle().fill(accent.opacity(0.85))
                    Text(speakerInitials(sp?.displayName))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(sp == nil ? L("Unlabeled") : L("Click to rename speaker"))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let sp {
                        Button { beginRename(sp) } label: {
                            Text(sp.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                        .help(L("Click to rename speaker"))
                    }
                    if let span = paragraphSpan(para) {
                        Text("\(timecode(span.start)) – \(timecode(span.end))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                FlowingCues(
                    items: para.items,
                    isPlaying: isPlaying,
                    playheadSeconds: playheadSeconds,
                    selected: selectedCueIDs,
                    editing: editingCueID,
                    editingDraft: $editingDraft,
                    speakers: speakers,
                    onClickCue: { id, mods in
                        handleCueClick(id: id, modifiers: mods)
                    },
                    onBeginEdit: { id in
                        if let cue = cues.first(where: { $0.id == id }) {
                            editingCueID = id
                            editingDraft = cue.text
                        }
                    },
                    onCommit: { id in
                        let newText = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !newText.isEmpty { onEditCue(id, newText) }
                        editingCueID = nil
                    },
                    onContextDelete: { id in
                        // macOS convention: right-click on a member of the
                        // current selection acts on the whole selection;
                        // right-click on an outsider acts on just that cue
                        // (and snaps selection to it so the next keystroke
                        // is unambiguous).
                        if selectedCueIDs.contains(id) {
                            onDeleteCues(Array(selectedCueIDs))
                            selectedCueIDs.removeAll()
                        } else {
                            selectedCueIDs = [id]
                            onDeleteCues([id])
                            selectedCueIDs.removeAll()
                        }
                        selectionAnchorID = nil
                    },
                    onContextAssignSpeaker: { id, speakerID in
                        // Same selection-snap convention as Delete above —
                        // right-click on a member of the active selection
                        // reassigns every selected cue, otherwise just the
                        // right-clicked cue. Selection is preserved (the
                        // cues are still alive after a reassignment).
                        if selectedCueIDs.contains(id) {
                            onAssignSpeaker(Array(selectedCueIDs), speakerID)
                        } else {
                            selectedCueIDs = [id]
                            selectionAnchorID = id
                            onAssignSpeaker([id], speakerID)
                        }
                    },
                    onContextAssignNewSpeaker: { id in
                        if selectedCueIDs.contains(id) {
                            onAssignNewSpeaker(Array(selectedCueIDs))
                        } else {
                            selectedCueIDs = [id]
                            selectionAnchorID = id
                            onAssignNewSpeaker([id])
                        }
                    },
                    onContextMergeWithPrevious: { id in
                        // For convenience: this menu fires regardless
                        // of selection state — merge with previous is
                        // a single-cue operation. The view model
                        // resolves the predecessor in the same
                        // segment and no-ops if there isn't one.
                        onMergeCues(neighborMergeIDs(forCueID: id, direction: .previous))
                    },
                    onContextMergeWithNext: { id in
                        onMergeCues(neighborMergeIDs(forCueID: id, direction: .next))
                    },
                    onContextMergeSelected: {
                        // Multi-merge: only meaningful when 2+ cues
                        // are selected. The view model validates
                        // adjacency / same-segment / same-speaker;
                        // invalid selections become no-ops.
                        guard selectedCueIDs.count >= 2 else { return }
                        onMergeCues(Array(selectedCueIDs))
                    },
                    onRequestSplit: { id in
                        // Open the popover anchored to this cue.
                        splittingCueID = id
                    },
                    onDismissSplit: {
                        splittingCueID = nil
                    },
                    onPickSplitOffset: { id, offset in
                        splittingCueID = nil
                        onSplitCueAtOffset(id, offset)
                    },
                    splittingCueID: splittingCueID,
                    selectionCount: selectedCueIDs.count,
                    isSelected: { selectedCueIDs.contains($0) },
                    onRestoreTombstone: onRestoreTombstone
                )
                .padding(.leading, 2)
            }
            .padding(.leading, 6)
            .overlay(alignment: .leading) {
                // Vertical accent stripe in the speaker color — gives
                // the block a chat-bubble feel without an actual bubble.
                Rectangle()
                    .fill(accent.opacity(0.55))
                    .frame(width: 2)
            }
        }
    }

    private func beginRename(_ sp: Speaker) {
        renameDraft = sp.displayName
        renamingSpeakerID = sp.id
    }

    @ViewBuilder
    private func renamePopover() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Rename speaker"))
                .font(.caption.bold())
            TextField(L("Speaker name"), text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .focused($renameFieldFocused)
                .onSubmit { commitRename() }

            Text(L("Color"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(Speaker.palette.enumerated()), id: \.offset) { _, swatch in
                    let isSelected = currentSpeakerColor()?.toHex() == swatch.toHex()
                    Button {
                        if let id = renamingSpeakerID, let hex = swatch.toHex() {
                            onRecolorSpeaker(id, hex)
                        }
                    } label: {
                        ZStack {
                            Circle().fill(swatch)
                            if isSelected {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .padding(1)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker(
                    "",
                    selection: Binding(
                        get: { currentSpeakerColor() ?? .gray },
                        set: { newColor in
                            if let id = renamingSpeakerID, let hex = newColor.toHex() {
                                onRecolorSpeaker(id, hex)
                            }
                        }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
                .frame(width: 28, height: 22)
            }

            Text(L("Label size"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { currentSpeakerLabelSize() },
                        set: { newSize in
                            if let id = renamingSpeakerID {
                                onResizeSpeakerLabel(id, newSize)
                            }
                        }
                    ),
                    in: 10...40,
                    step: 1
                )
                .frame(minWidth: 160)
                Text("\(Int(currentSpeakerLabelSize())) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Button(L("Reset")) {
                    if let id = renamingSpeakerID {
                        onRenameSpeaker(id, "")
                        onRecolorSpeaker(id, nil)
                        onResizeSpeakerLabel(id, nil)
                    }
                    renamingSpeakerID = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) { renamingSpeakerID = nil }
                Button(L("Save")) { commitRename() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear {
            // Defer one runloop tick so SwiftUI has finished mounting
            // the field editor before we ask for first responder.
            DispatchQueue.main.async { renameFieldFocused = true }
        }
    }

    /// Lookup the live color for the speaker currently being edited.
    private func currentSpeakerColor() -> Color? {
        guard let id = renamingSpeakerID else { return nil }
        return speakers.first(where: { $0.id == id })?.color
    }

    /// Live label size for the speaker currently being edited. Falls
    /// back to the overlay default when the user hasn't set a custom
    /// size yet, so the slider starts at a sensible value instead of
    /// slamming to 10.
    private func currentSpeakerLabelSize() -> Double {
        guard let id = renamingSpeakerID,
              let sp = speakers.first(where: { $0.id == id })
        else { return 25 }
        return sp.labelSize ?? 25
    }

    private func commitRename() {
        guard let id = renamingSpeakerID else { return }
        onRenameSpeaker(id, renameDraft)
        renamingSpeakerID = nil
    }

    private enum NeighborDirection { case previous, next }

    /// For the "Merge with previous" / "Merge with next" cue menu items,
    /// build the `[UUID]` payload to hand to `onMergeCues` so the view
    /// model can apply its same-segment + adjacency validation. We
    /// approximate "neighbor in same segment" by picking the
    /// immediately-prior / immediately-next *live cue* in the
    /// transcript's reading order — the view model will silently no-op
    /// if that neighbor turns out to live in a different segment.
    private func neighborMergeIDs(forCueID id: UUID, direction: NeighborDirection) -> [UUID] {
        // `cues` is the source-of-truth ordered list (composed-time
        // order); tombstones are excluded from merge candidates.
        guard let idx = cues.firstIndex(where: { $0.id == id }) else { return [] }
        switch direction {
        case .previous:
            guard idx > 0 else { return [] }
            return [cues[idx - 1].id, id]
        case .next:
            guard idx + 1 < cues.count else { return [] }
            return [id, cues[idx + 1].id]
        }
    }

    private func speakerInitials(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "?" }
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        if parts.count >= 2 {
            let a = parts[0].first.map(String.init) ?? ""
            let b = parts[1].first.map(String.init) ?? ""
            return (a + b).uppercased()
        }
        // For "Speaker 1" style fall back to the trailing digit; for a
        // single-word custom name take the first character.
        if let last = name.split(whereSeparator: { !$0.isNumber }).last,
           name.lowercased().hasPrefix("speaker") {
            return String(last)
        }
        return String(name.prefix(1)).uppercased()
    }

    private func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Lays out cues inline (like flowing text) rather than as a vertical list
/// so a paragraph reads naturally. Uses a simple wrapping HStack built on
/// top of `Layout` via SwiftUI's native flow semantics (FlowLayout).
private struct FlowingCues: View {
    let items: [TranscriptView.Item]
    let isPlaying: (ComposedSubtitle) -> Bool
    /// Composed-timeline playhead in seconds. Used to derive the
    /// per-character karaoke highlight inside the active cue when
    /// `cue.wordTimings` is present.
    let playheadSeconds: Double
    let selected: Set<UUID>
    let editing: UUID?
    @Binding var editingDraft: String
    /// Current speaker registry — used to populate the "Speaker"
    /// submenu in a cue's right-click menu so users can reassign a
    /// mislabeled line.
    let speakers: [Speaker]
    var onClickCue: (UUID, EventModifiers) -> Void
    var onBeginEdit: (UUID) -> Void
    var onCommit: (UUID) -> Void
    var onContextDelete: (UUID) -> Void
    var onContextAssignSpeaker: (UUID, Int) -> Void
    var onContextAssignNewSpeaker: (UUID) -> Void
    var onContextMergeWithPrevious: (UUID) -> Void
    var onContextMergeWithNext: (UUID) -> Void
    var onContextMergeSelected: () -> Void
    /// Open the "Split…" popover anchored at this cue.
    var onRequestSplit: (UUID) -> Void
    /// Dismiss the popover without picking a split point.
    var onDismissSplit: () -> Void
    /// User picked a UTF-16 split offset inside this cue's text.
    var onPickSplitOffset: (UUID, Int) -> Void
    /// Cue currently showing the split popover (driven by parent state).
    let splittingCueID: UUID?
    /// Number of cues currently multi-selected. Used to decide whether
    /// "Merge selected" appears in the right-click menu and what label
    /// it carries.
    let selectionCount: Int
    /// Predicate used to ask whether a particular cue is part of the
    /// active multi-selection (so the right-click menu can short-circuit
    /// the per-cue merge variants when the selection-merge is the
    /// natural action instead).
    let isSelected: (UUID) -> Bool
    var onRestoreTombstone: (UUID) -> Void

    var body: some View {
        WrapHStack(spacing: 4, lineSpacing: 4) {
            ForEach(items) { item in
                itemView(item)
                    .id(item.id)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: TranscriptView.Item) -> some View {
        switch item {
        case .cue(let cue):
            cueView(cue)
        case .tomb(let tomb):
            tombView(tomb)
        }
    }

    @ViewBuilder
    private func cueView(_ cue: ComposedSubtitle) -> some View {
        if editing == cue.id {
            // Single-line TextField — Enter commits the edit. Splitting
            // is handled by the dedicated "Split…" right-click menu /
            // popover instead, which is more discoverable and uses the
            // wordTimings-aware data-layer split helper.
            TextField("", text: $editingDraft, onCommit: { onCommit(cue.id) })
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
        } else {
            let inSelection = isSelected(cue.id) && selectionCount > 1
            Text(karaokeText(for: cue))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(background(for: cue))
                .cornerRadius(3)
                .overlay(alignment: .topTrailing) {
                    if cue.styleOverride != nil {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 5, weight: .bold))
                            .foregroundStyle(EditorShellStyle.accentSolid)
                            .padding(2)
                            .help(L("Customized"))
                    }
                }
                .contentShape(Rectangle())
                .modifier(ClickWithModifiers { mods in onClickCue(cue.id, mods) })
                .onTapGesture(count: 2) { onBeginEdit(cue.id) }
                .popover(
                    isPresented: Binding(
                        get: { splittingCueID == cue.id },
                        set: { if !$0 { onDismissSplit() } }
                    ),
                    arrowEdge: .top
                ) {
                    SplitCuePopover(
                        cueText: cue.text,
                        onPick: { utf16Offset in
                            onPickSplitOffset(cue.id, utf16Offset)
                        },
                        onCancel: { onDismissSplit() }
                    )
                }
                .contextMenu {
                    Button { onBeginEdit(cue.id) } label: { T("Edit") }
                    Divider()
                    speakerMenu(for: cue)
                    Divider()
                    Button(L("Split…")) { onRequestSplit(cue.id) }
                    if inSelection {
                        Button(String(format: L("Merge %d selected cues"), selectionCount)) {
                            onContextMergeSelected()
                        }
                    } else {
                        Button(L("Merge with previous cue")) {
                            onContextMergeWithPrevious(cue.id)
                        }
                        Button(L("Merge with next cue")) {
                            onContextMergeWithNext(cue.id)
                        }
                    }
                    Divider()
                    Button(selected.contains(cue.id) && selected.count > 1
                           ? String(format: L("Delete %d cues"), selected.count)
                           : L("Delete"),
                           role: .destructive) {
                        onContextDelete(cue.id)
                    }
                }
        }
    }

    /// Build a per-character karaoke `AttributedString` for `cue`:
    ///
    /// - When the cue isn't currently playing → entire text in `.primary`
    ///   so paragraph rendering is unchanged from the pre-karaoke
    ///   behaviour for inactive cues.
    /// - When playing AND `cue.wordTimings` is empty → fall back to the
    ///   classic "whole cue lights up" behaviour (entire text painted in
    ///   the accent color), which is what every legacy / non-Qwen
    ///   transcript still does.
    /// - When playing AND timings are present → walk the timings using
    ///   the same matching logic as `SubtitleKaraokeComposer.activeWordRange`
    ///   (cursor-relative substring with a `range(of:)` fallback for
    ///   leading-space drift) and colour each char region by its karaoke
    ///   state: already-spoken → accent (slightly dim) so the user sees
    ///   reading progress; currently-active → accent + bold so the eye
    ///   tracks it; future → `.primary`.
    private func karaokeText(for cue: ComposedSubtitle) -> AttributedString {
        var attr = AttributedString(cue.text)

        guard isPlaying(cue) else {
            attr.foregroundColor = .primary
            return attr
        }

        guard let timings = cue.wordTimings, !timings.isEmpty else {
            // Whole-cue highlight (legacy behaviour for cues without
            // word timings — e.g., older transcripts or pre-karaoke
            // saved projects).
            attr.foregroundColor = EditorShellStyle.accentSolid
            return attr
        }

        let entryRel = playheadSeconds - cue.startSeconds
        let ns = cue.text as NSString
        let textLen = ns.length
        var cursor = 0
        var pastEndUTF16 = 0
        var activeRange: NSRange?

        for timing in timings {
            let slice = timing.text as NSString
            let sliceLen = slice.length
            guard sliceLen > 0 else { continue }

            var matchLoc = cursor
            if cursor + sliceLen <= textLen,
               ns.substring(with: NSRange(location: cursor, length: sliceLen)) == timing.text {
                matchLoc = cursor
            } else {
                let hit = ns.range(
                    of: timing.text,
                    options: [.literal],
                    range: NSRange(location: cursor, length: textLen - cursor)
                )
                if hit.location == NSNotFound { continue }
                matchLoc = hit.location
            }

            if entryRel >= timing.endSeconds {
                pastEndUTF16 = matchLoc + sliceLen
            } else if entryRel >= timing.startSeconds {
                activeRange = NSRange(location: matchLoc, length: sliceLen)
                break
            } else {
                break
            }

            cursor = matchLoc + sliceLen
        }

        attr.foregroundColor = .primary

        if pastEndUTF16 > 0,
           let pastRange = Range(NSRange(location: 0, length: pastEndUTF16), in: attr) {
            attr[pastRange].foregroundColor = EditorShellStyle.accentSolid.opacity(0.7)
        }

        if let active = activeRange,
           let r = Range(active, in: attr) {
            attr[r].foregroundColor = EditorShellStyle.accentSolid
            attr[r].font = .body.bold()
        }

        return attr
    }

    /// Right-click submenu listing every speaker in the current
    /// registry plus a "New speaker" escape hatch. Selecting an entry
    /// reassigns the right-clicked cue (or, if the cue is part of the
    /// active multi-selection, every selected cue) to that speaker.
    /// The current assignment is shown with a leading checkmark.
    @ViewBuilder
    private func speakerMenu(for cue: ComposedSubtitle) -> some View {
        Menu(L("Speaker")) {
            ForEach(speakers, id: \.id) { sp in
                Button {
                    onContextAssignSpeaker(cue.id, sp.id)
                } label: {
                    if cue.speakerID == sp.id {
                        Label(sp.displayName, systemImage: "checkmark")
                    } else {
                        Text(sp.displayName)
                    }
                }
            }
            if !speakers.isEmpty { Divider() }
            Button {
                onContextAssignNewSpeaker(cue.id)
            } label: {
                let nextID = (speakers.map(\.id).max() ?? -1) + 1
                Text(String(format: L("New speaker (Speaker %d)"), nextID + 1))
            }
        }
    }

    /// Strikethrough render for a tombstoned (soft-deleted) cue. Not
    /// selectable, not seekable — right-click offers "Restore" which
    /// re-inserts the original source range as a new segment.
    @ViewBuilder
    private func tombView(_ tomb: SubtitleTombstone) -> some View {
        Text(tomb.text)
            .strikethrough(true, color: .secondary)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .cornerRadius(3)
            .contentShape(Rectangle())
            .contextMenu {
                Button { onRestoreTombstone(tomb.id) } label: { T("Restore") }
            }
    }

    private func background(for cue: ComposedSubtitle) -> Color {
        if isPlaying(cue) { return EditorShellStyle.accentSolid.opacity(0.18) }
        if selected.contains(cue.id) { return Color.white.opacity(0.10) }
        return .clear
    }
}

/// Captures the current `EventModifiers` (shift/command/option) at the
/// moment of a click by layering `SwiftUI.onTapGesture` on top of a
/// keyboard-modifier observer. SwiftUI's plain `onTapGesture` drops
/// modifier info, and we need modifiers to tell plain-click apart from
/// cmd-click (toggle) and shift-click (range) in the transcript.
private struct ClickWithModifiers: ViewModifier {
    var action: (EventModifiers) -> Void
    @State private var currentModifiers: EventModifiers = []

    func body(content: Content) -> some View {
        content
            .onModifierKeysChanged(mask: [.shift, .command, .option]) { _, new in
                currentModifiers = new
            }
            .onTapGesture { action(currentModifiers) }
    }
}

private extension View {
    /// Thin shim over the macOS 14+ `onModifierKeysChanged`. Falls back
    /// to a no-op on older systems so the transcript still works (just
    /// without shift/cmd range support).
    @ViewBuilder
    func onModifierKeysChanged(mask: EventModifiers, perform: @escaping (EventModifiers, EventModifiers) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            self.onModifierKeysChanged(mask: mask, initial: false, perform)
        } else {
            self
        }
    }
}

/// Lightweight wrapping HStack — SwiftUI's built-in HStack doesn't wrap.
/// Uses `Layout` (macOS 13+) to place children left-to-right, wrapping
/// when a child would overflow the proposed width.
private struct WrapHStack: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, width: width)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, usedWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for idx in row.indices {
                let subview = subviews[idx]
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty
                ? size.width
                : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            if rows[rows.count - 1].indices.isEmpty {
                rows[rows.count - 1].width = size.width
            } else {
                rows[rows.count - 1].width += spacing + size.width
            }
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - SplitCuePopover

/// Popover that lets the user pick a split point inside a subtitle
/// cue's text. Tokenizes the text via `SubtitleWordTokenizer` (the
/// same tokenizer used by the emphasis UI, so the boundaries are
/// consistent), then renders each token as a static label with a
/// thin tappable split marker between adjacent tokens. The markers
/// stay visually quiet (a 2pt grey rule) so the sentence is still
/// readable as prose; on hover they light up in accent color and
/// expand slightly so the click target is obvious.
private struct SplitCuePopover: View {
    let cueText: String
    let onPick: (Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        let tokens = SubtitleWordTokenizer.tokenize(cueText)
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Split cue"))
                .font(.headline)
            Text(L("Click a marker between words to split the cue there. Timestamps are aligned automatically."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if tokens.isEmpty {
                Text(L("This cue has no splittable words."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    splitFlow(tokens: tokens)
                        .padding(.vertical, 4)
                }
                .frame(maxWidth: 420, maxHeight: 220)
            }

            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 320)
    }

    @ViewBuilder
    private func splitFlow(tokens: [SubtitleWordTokenizer.Token]) -> some View {
        // `spacing: 0` because each `SplitMarker` carries its own
        // horizontal padding for the hit target; an extra row gap
        // would push tokens apart and hurt readability.
        WrapHStack(spacing: 0, lineSpacing: 4) {
            ForEach(0..<tokens.count, id: \.self) { idx in
                let token = tokens[idx]
                // The marker BEFORE token[i] sits at
                // `token.utf16Range.location` — the boundary between
                // token[i-1] and token[i]. We skip the first boundary
                // (offset 0) and the last (cue end), since
                // `SubtitleEntry.split(atUTF16Offset:)` rejects those.
                if idx > 0 {
                    SplitMarker(offset: token.utf16Range.location, onPick: onPick)
                }
                Text(token.text)
                    .font(.body)
            }
        }
    }
}

/// Slim split marker — a 2pt rule that quietly lives between two
/// tokens. On hover it brightens to the editor accent color, widens
/// to 3pt, and surfaces a scissors tooltip so the meaning is still
/// obvious even though the resting state is subtle. The marker has
/// horizontal padding *outside* the visible rule so the hit target
/// is comfortable without visually pushing tokens apart.
private struct SplitMarker: View {
    let offset: Int
    let onPick: (Int) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onPick(offset)
        } label: {
            RoundedRectangle(cornerRadius: 1)
                .fill(isHovering
                      ? AnyShapeStyle(EditorShellStyle.accentSolid)
                      : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .frame(width: isHovering ? 3 : 2, height: 14)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(L("Split here"))
    }
}
