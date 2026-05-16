import AppKit
import Foundation
import AVFoundation
import SwiftUI
import CuttiKit

// MARK: - Protocol for MediaCore importing

protocol MediaCoreImporting: Sendable {
    func importLocalVideo(
        url: URL,
        progress: @Sendable @escaping (ImportPhase, Double) -> Void
    ) async throws -> UUID
    func importLocalImage(url: URL) async throws -> UUID
    func relinkOriginal(mediaId: UUID, newURL: URL) throws
    func validateSources() throws
}

extension MediaCoreImporting {
    /// No-progress convenience for callers that don't surface phase/percent.
    func importLocalVideo(url: URL) async throws -> UUID {
        try await importLocalVideo(url: url, progress: { _, _ in })
    }
}

extension MediaCore: MediaCoreImporting {}

// MARK: - View Model

/// View model for media core playback UI.
/// Manages proxy-only playback via injected playback core.
@MainActor
final class MediaCoreViewModel: ObservableObject {
    @Published var player: AVPlayer? {
        didSet {
            // Any time the player is swapped (new composition, record
            // switch, clear on import / delete / relink, etc.) we have
            // to stop the outgoing player. Dropping the last Swift
            // reference is not enough — the ViewerStage's AVPlayerLayer
            // and any in-flight playback timer can keep it alive, and
            // in that case an AI-driven rebuild leaves the old clip's
            // audio droning on underneath the newly-loaded video.
            //
            // Pausing here is cheap on a nil→nil or same-instance
            // transition, so it's safe to fire unconditionally.
            if oldValue !== player {
                oldValue?.pause()
                // The loop observer is tied to the OLD player's
                // currentItem. When the player is swapped out, the old
                // observation would either keep firing against a stale
                // AVPlayerItem or — worse — accumulate across rebuilds
                // every time the composition is regenerated. Tear it
                // down here and reinstall below if looping is active.
                removeLoopObserver()
                if isLooping, player != nil {
                    installLoopObserver()
                }
            }
        }
    }
    @Published var bannerMessage: String?
    @Published var records: [MediaAssetRecord] = []
    @Published var selectedRecordID: UUID?
    @Published var analysisProgress: AnalysisProgress?
    @Published var isAnalyzing: Bool = false
    @Published var isExporting: Bool = false
    @Published var isCancellingExport: Bool = false
    @Published var exportProgress: AIVideoExporter.ExportProgress?
    private var exportTask: Task<Void, Never>?
    @Published var isImporting: Bool = false
    /// Files currently being imported. Rendered as placeholder rows at the
    /// top of the media list so users see exactly which drops are in flight.
    @Published var importingFiles: [ImportingFile] = []
    /// Per-ticket Task handle so `cancelImport(id:)` can interrupt one
    /// specific import — including imports still queued behind the
    /// concurrency gate. Owned by the view model so external callers
    /// (drag-drop / open panel) don't have to manage the Task themselves.
    private var importTasks: [UUID: Task<Void, Never>] = [:]

    struct ImportingFile: Identifiable, Equatable {
        let id: UUID
        let name: String
        var phase: Phase
        /// Current transcode progress in `0.0...1.0`. Only meaningful
        /// when `phase == .transcoding`; reset on phase changes.
        var progress: Double

        enum Phase: Sendable, Equatable {
            case preparing
            case analyzing
            case waiting
            case transcoding
        }

        init(
            id: UUID = UUID(),
            name: String,
            phase: Phase = .preparing,
            progress: Double = 0
        ) {
            self.id = id
            self.name = name
            self.phase = phase
            self.progress = progress
        }
    }

    // MARK: - AI Chat
    @Published var chatMessages: [EditorChatMessage] = []
    @Published var isChatProcessing: Bool = false
    /// Pending `edit_timeline` proposals awaiting user Apply/Reject.
    /// Populated in `.manual` agent mode when the LLM issues a batch.
    /// Ordered most-recent first.
    @Published var pendingProposals: [ProposedBatch] = []
    /// Set by `generateOverlayFromSuggestion` before it kicks off the
    /// agent loop, consumed by the `generate_overlay` tool handler to
    /// reject responses whose `durationSeconds` ignores the speaker's
    /// anchor window (forcing a retry). Not @Published because no UI
    /// observes it directly.
    var pendingOverlayAnchor: PendingOverlayAnchor? = nil
    /// Whether Agent batches require user approval (`.manual`) or
    /// apply immediately (`.autoApply`). User-visible toggle in the
    /// chat header.
    @Published var agentMode: AgentMode = .manual
    /// Segment(s) the user has dragged onto the chat composer. When
    /// non-empty the AI is constrained to operate exclusively within
    /// their composed-timeline union, and user-facing times in prompts
    /// are interpreted as a concatenated virtual timeline. Ordered in
    /// attach order. Not persisted across sessions.
    @Published var chatAttachments: [ChatAttachment] = []
    private var chatStore: ChatStore?
    /// Whether an analysis flow is currently posting progress into the
    /// chat. Used to gate begin/finish bubble helpers and to only
    /// append a new "phase started" bubble the first time each phase
    /// appears during a single analysis run.
    private var analysisChatActive: Bool = false
    private var analysisChatSeenPhases: Set<AnalysisPhase> = []
    /// UUID of each phase's "in-progress" kickoff bubble so that the
    /// matching `isPhaseComplete` event can mutate it in place — text
    /// flips from `"Analyzing audio — Started"` to `"Analyzing audio
    /// — Done in 10.6s"` and the spinner flips to a checkmark.
    /// Multiple entries can coexist because transcribe/scene/audio
    /// run in parallel and each has its own live spinner until its
    /// own done event arrives.
    private var analysisChatPhaseBubbleIDs: [AnalysisPhase: UUID] = [:]
    /// Optional hook the chat's live-narration bubble wires into every
    /// analysis phase transition. `handleAIPrompt` sets this just
    /// before calling `analyzeRecord` / `analyzeAllRecords` so each
    /// phase-start routes into the same in-place chat bubble. `nil`
    /// when no chat-driven analysis is active (e.g. "One-click first
    /// cut" button path — that keeps its own multi-bubble log trail).
    private var liveNarrationCallback: (@MainActor (AnalysisPhase) -> Void)? = nil
    /// Heartbeat task driving periodic text updates on the live
    /// narration bubble during long-running phases that don't produce
    /// fine-grained progress signals (transcription, scene analysis,
    /// slow tool calls). Cancelled on phase change / lock / bubble
    /// removal. Only ever one alive at a time.
    private var liveNarrationHeartbeat: Task<Void, Never>? = nil
    /// Ordered segments for timeline display. Each segment is one AI-kept range.
    /// The multi-track project model. The primary video track
    /// (`project.primarySegments`) is what every pre-multitrack code path
    /// reads/writes via the `timelineSegments` compatibility shim below.
    @Published var project: Project = Project()

    /// Backward-compatible view of the primary video track. Getter and
    /// setter forward to `project.primarySegments` so adding BGM/overlay
    /// tracks doesn't force every existing consumer (VM helpers, tests,
    /// AI action executor, composition builder) to change shape at once.
    var timelineSegments: [TimelineSegment] {
        get { project.primarySegments }
        set { project.primarySegments = newValue }
    }
    /// Currently selected segment ID in the timeline (stable across mutations).
    @Published var selectedSegmentID: UUID?
    /// All selected segment IDs in the timeline (supports macOS-style multi-select).
    @Published private(set) var selectedSegmentIDs: Set<UUID> = []
    /// Selected overlay-track segment (V2+). Used to (1) display the
    /// start-time popover in TimelineDock and (2) drive the free-
    /// transform handles in the viewer. Nil when no overlay segment
    /// is active.
    ///
    /// Selection is mutually exclusive with V1's `selectedSegmentIDs`
    /// (didSet below clears V1 when an overlay becomes selected, and
    /// `handleSegmentClick` clears this when V1 is clicked). That
    /// invariant lets shortcut actions like Cmd+B (Split) and the
    /// toolbar split button route deterministically to the lane the
    /// user is currently editing — sticky cross-track selection used
    /// to make Cmd+B silently target a clip the user wasn't looking
    /// at anymore.
    @Published var selectedOverlaySegmentID: UUID? {
        didSet {
            if selectedOverlaySegmentID != nil, !selectedSegmentIDs.isEmpty {
                clearSegmentSelection()
            }
        }
    }
    /// Toggle subtitle display on the timeline.
    @Published var showSubtitles: Bool
    /// When true, subtitles still render on the S1 timeline lane (so
    /// the user can edit cues) but are NOT drawn in the viewer's
    /// preview. This is what the S1 gutter eye toggles — it's a
    /// preview-only mute, not a lane removal. Kept in-memory for now;
    /// not persisted in the session snapshot.
    @Published var subtitlesPreviewHidden: Bool = false
    /// Style used for viewer overlay and burn-in export. Persisted per-project
    /// once project packaging lands; currently kept in-memory. Changes are
    /// recorded onto a local undo stack (coalesced by `styleUndoCoalesceWindow`)
    /// so Cmd+Z can revert style edits while the subtitle is selected.
    @Published var subtitleStyle: SubtitleStyle = .default {
        willSet {
            recordSubtitleStyleChange(previous: subtitleStyle)
        }
    }
    /// Whether the user has currently selected the subtitle box in the viewer
    /// for direct manipulation (drag to move / handle to resize).
    @Published var isSubtitleSelected: Bool = false
    /// ID of the subtitle cue currently selected on the timeline's S1 lane.
    /// Mutually exclusive with segment selection: selecting a cue clears
    /// segment selection, and selecting a segment clears this. The Delete
    /// key and context menu prefer this selection over segment selection
    /// when non-nil.
    @Published var selectedSubtitleID: UUID?
    /// Composed subtitles for viewer overlay (absolute timing).
    @Published var composedSubtitles: [ComposedSubtitle] = []
    /// Soft-deleted subtitle cues: the user removed the video for
    /// these ranges via the transcript editor's Delete, but chose to
    /// keep the text visible (strikethrough) in the transcript. Lives
    /// in `EditorSessionState` on disk and in every `EditorRevision`
    /// so Cmd+Z round-trips.
    @Published var subtitleTombstones: [SubtitleTombstone] = []
    /// ID of the cue the user is currently inline-editing in the viewer.
    /// When non-nil, `currentSubtitleText` / `currentSubtitleID` / …
    /// return the pinned cue instead of whatever cue covers the playhead.
    /// This keeps the `SubtitleOverlay` TextField mounted — without it,
    /// the overlay disappears the instant playback advances past the cue,
    /// tearing down the in-flight editor and freezing the app in an AppKit
    /// first-responder handoff with `AVPlayerView`.
    @Published var editingSubtitleCueID: UUID?
    /// Speakers detected by diarization (or manually added). Drives
    /// per-speaker color in the overlay/burn-in. Empty until the user
    /// runs auto-detect.
    @Published var speakers: [Speaker] = []

    /// User-edited display names for diarized speakers, keyed by
    /// speaker ID. Persisted in `MediaManifest.speakerNames`. Layered
    /// on top of the default "Speaker N" labels whenever the speakers
    /// registry is rebuilt. Empty until the user renames anyone.
    @Published var speakerNames: [Int: String] = [:]

    /// User-picked accent colors per speaker, keyed by speaker ID and
    /// stored as `#RRGGBB` hex. Persisted in `MediaManifest.speakerColors`.
    /// Layered on top of the default palette whenever the registry is
    /// rebuilt. Empty until the user picks a custom color.
    @Published var speakerColors: [Int: String] = [:]

    /// User-picked label font sizes per speaker (points), keyed by
    /// speaker ID. Persisted in `MediaManifest.speakerLabelSizes`.
    /// Layered on top of the renderer default whenever the registry
    /// is rebuilt. Empty until the user picks a custom size.
    @Published var speakerLabelSizes: [Int: Double] = [:]

    // MARK: - Autosave

    enum AutosaveStatus: Equatable {
        case idle
        case saving
        case saved(Date)
        case error(String)
    }

    /// Last autosave outcome, surfaced by the UI status indicator.
    @Published private(set) var autosaveStatus: AutosaveStatus = .idle

    /// Last `project.tracks` snapshot that was persisted. Used so
    /// overlay-only mutations (e.g. moving an image overlay pill, which
    /// does not touch `primarySegments`) still mark autosave as dirty.
    private var lastAutosavedTracks: [Track] = []

    /// How often the autosave timer fires (Word defaults to 10 min;
    /// we use 30s because edits are continuous and file size is small).
    private let autosaveInterval: TimeInterval = 30
    private var autosaveTimer: Timer?
    /// Debounced save task triggered from `rebuildComposition`. Fires
    /// ~1s after the last mutation so quick bursts (drag to trim, typing
    /// in a subtitle) coalesce into a single disk write, but close+reopen
    /// never loses more than ~1s of edits.
    private var debouncedSaveTask: Task<Void, Never>?
    /// Snapshot of the last successfully persisted segments so we can
    /// cheaply detect dirtiness without a hash function.
    private var lastAutosavedSegments: [TimelineSegment] = []
    /// Snapshot of the last persisted session state (style + toggles).
    private var lastAutosavedSession: EditorSessionState = .default
    /// True once we've restored the persisted live timeline (or decided
    /// there wasn't one). Prevents `loadRecords` called post-edit (e.g.
    /// after analysis completes or an import) from clobbering in-memory
    /// edits with a stale on-disk snapshot.
    private var hasRestoredPersistedTimeline = false
    /// Composed timeline index for AI Agent time mapping.
    private(set) var composedIndex: ComposedTimelineIndex = .build(from: [])
    /// Playback speed rate.
    @Published var playbackRate: Double = 1.0
    /// In-point for range marking (composed timeline seconds).
    @Published var inPoint: Double?
    /// Out-point for range marking (composed timeline seconds).
    @Published var outPoint: Double?
    /// Loop playback toggle.
    @Published var isLooping: Bool = false

    // MARK: - Revision-based Undo / Redo

    /// Revision store for persistent checkpoint history.
    private var revisionStore: RevisionStore?
    /// In-memory revision history for undo/redo (synced from store).
    @Published var revisions: [EditorRevision] = []
    /// Index of the current revision in the revisions array.
    private var currentRevisionIndex: Int = -1
    /// Monotonic counter to discard stale async composition rebuilds.
    private var compositionGeneration: Int = 0
    /// Anchor used for Shift-click range selection.
    private var selectionAnchorSegmentID: UUID?

    var canUndo: Bool {
        (isSubtitleSelected && !subtitleStyleUndoStack.isEmpty) ||
        (currentRevisionIndex >= 0 && revisions.count > 0)
    }
    var canRedo: Bool {
        (isSubtitleSelected && !subtitleStyleRedoStack.isEmpty) ||
        (currentRevisionIndex < revisions.count - 1)
    }

    // MARK: - Subtitle style undo / redo (separate lightweight stack)

    /// In-memory undo stack for subtitle style edits. Separate from the
    /// revision store so slider/color-picker scrubs don't spam persistent
    /// history and so they undo independently from timeline cuts.
    private var subtitleStyleUndoStack: [SubtitleStyle] = []
    private var subtitleStyleRedoStack: [SubtitleStyle] = []
    private var lastSubtitleStyleChangeAt: Date?
    /// Collapse rapid successive style changes (slider drags, color scrubs)
    /// into one undo step by skipping push when the last change was within
    /// this window.
    private let styleUndoCoalesceWindow: TimeInterval = 0.5
    /// Guards re-entrance while `undoSubtitleStyle` / `redoSubtitleStyle`
    /// themselves mutate `subtitleStyle`.
    private var isApplyingStyleHistory = false

    /// Last per-cue style snapshot push timestamp + cue id. Used to
    /// coalesce rapid successive snapshot writes from the inspector
    /// (slider drags, color scrubs) so a single drag becomes one
    /// undoable revision rather than dozens. Mirrors the
    /// `styleUndoCoalesceWindow` strategy used for the global path.
    private var lastPerCueStyleSnapshotAt: Date?
    private var lastPerCueStyleSnapshotCueID: UUID?

    private func recordSubtitleStyleChange(previous: SubtitleStyle) {
        guard !isApplyingStyleHistory else { return }
        let now = Date()
        if let last = lastSubtitleStyleChangeAt,
           now.timeIntervalSince(last) < styleUndoCoalesceWindow {
            // Coalesce: keep the existing top-of-stack snapshot which already
            // represents the pre-edit baseline.
        } else {
            subtitleStyleUndoStack.append(previous)
            if subtitleStyleUndoStack.count > 50 {
                subtitleStyleUndoStack.removeFirst()
            }
            subtitleStyleRedoStack.removeAll()
        }
        lastSubtitleStyleChangeAt = now
    }

    private func undoSubtitleStyle() -> Bool {
        guard let prev = subtitleStyleUndoStack.popLast() else { return false }
        isApplyingStyleHistory = true
        subtitleStyleRedoStack.append(subtitleStyle)
        subtitleStyle = prev
        lastSubtitleStyleChangeAt = nil
        isApplyingStyleHistory = false
        return true
    }

    private func redoSubtitleStyle() -> Bool {
        guard let next = subtitleStyleRedoStack.popLast() else { return false }
        isApplyingStyleHistory = true
        subtitleStyleUndoStack.append(subtitleStyle)
        subtitleStyle = next
        lastSubtitleStyleChangeAt = nil
        isApplyingStyleHistory = false
        return true
    }

    /// Index of the currently selected segment (derived from ID for backward compat).
    var selectedSegmentIndex: Int? {
        get { timelineSegments.firstIndex(where: { $0.id == selectedSegmentID }) }
        set {
            if let idx = newValue, idx >= 0, idx < timelineSegments.count {
                setSingleSelectedSegment(id: timelineSegments[idx].id)
            } else {
                clearSegmentSelection()
            }
        }
    }

    var selectedSegmentCount: Int { selectedSegmentIDs.count }
    var hasSelectedSegments: Bool { !selectedSegmentIDs.isEmpty }
    var hasSingleSelectedSegment: Bool { selectedSegmentIDs.count == 1 }

    var selectedSegmentIndices: IndexSet {
        IndexSet(
            timelineSegments.enumerated().compactMap { index, segment in
                selectedSegmentIDs.contains(segment.id) ? index : nil
            }
        )
    }

    var singleSelectedSegmentIndex: Int? {
        hasSingleSelectedSegment ? selectedSegmentIndex : nil
    }

    /// Save current timeline state as a labeled revision.
    private func pushRevision(label: String, trigger: RevisionTrigger = .userEdit(description: "")) {
        let revision = EditorRevision(
            id: UUID(),
            timestamp: Date(),
            label: label,
            segments: timelineSegments.map { EditorRevision.PersistableSegment(from: $0) },
            selectedSegmentID: selectedSegmentID,
            playheadSeconds: 0,
            trigger: trigger,
            tracks: project.tracks.map { EditorRevision.PersistableTrack(from: $0) },
            subtitleTombstones: subtitleTombstones,
            subtitleStyle: subtitleStyle
        )
        revisions.append(revision)
        currentRevisionIndex = revisions.count - 1

        // Persist asynchronously
        if let revisionStore {
            Task {
                try? await revisionStore.push(revision)
            }
        }
    }

    /// Mutate the project inside an **automatic undo snapshot**. Every
    /// call first pushes a revision of the current state, then hands a
    /// mutable `Project` to `body`, then triggers a composition rebuild.
    /// Any ViewModel mutation that changes `project.tracks` (primary
    /// segments, aux tracks, overlays, mute/solo flags, etc.) must use
    /// this helper to guarantee Cmd+Z reverts the change — going
    /// through it is the single invariant that keeps the undo stack
    /// complete without callers having to remember `pushRevision` at
    /// each site.
    ///
    /// `bodyReturnsFalse` lets the body signal "nothing actually
    /// changed" so we can roll back the revision entry instead of
    /// leaving an empty checkpoint that would require two Cmd+Zs to
    /// step past.
    @discardableResult
    func mutateProject(
        label: String,
        trigger: RevisionTrigger = .userEdit(description: ""),
        _ body: (inout Project) -> Bool
    ) -> Bool {
        let snapshotIndex = revisions.count
        pushRevision(label: label, trigger: trigger)
        var next = project
        let changed = body(&next)
        guard changed else {
            // Roll back the speculative revision we just pushed so the
            // undo stack doesn't end up with no-op entries (common
            // cause of "Cmd+Z did nothing then something").
            if revisions.count == snapshotIndex + 1 {
                revisions.removeLast()
                currentRevisionIndex = revisions.count - 1
            }
            return false
        }
        project = next
        rebuildComposition()
        return true
    }

    private func setSingleSelectedSegment(id: UUID?) {
        if let id {
            selectedSegmentID = id
            selectedSegmentIDs = [id]
            selectionAnchorSegmentID = id
            selectedSubtitleID = nil
        } else {
            selectedSegmentID = nil
            selectedSegmentIDs = []
            selectionAnchorSegmentID = nil
        }
    }

    /// Public wrapper around the single-segment selection setter,
    /// used by the viewer's interactive PiP handle (and anything else
    /// that needs to select a segment by ID without routing through
    /// the `handleSegmentClick(index:)` path).
    func selectSegment(id: UUID?) {
        setSingleSelectedSegment(id: id)
    }

    private func firstSelectedSegmentID(in ids: Set<UUID>? = nil) -> UUID? {
        let ids = ids ?? selectedSegmentIDs
        return timelineSegments.first(where: { ids.contains($0.id) })?.id
    }

    private func reconcileSegmentSelection(
        preferredPrimaryID: UUID? = nil,
        preferredAnchorID: UUID? = nil
    ) {
        let validIDs = Set(timelineSegments.map(\.id))
        selectedSegmentIDs = selectedSegmentIDs.intersection(validIDs)

        if let preferredPrimaryID, validIDs.contains(preferredPrimaryID) {
            selectedSegmentID = preferredPrimaryID
            selectedSegmentIDs.insert(preferredPrimaryID)
        } else if let selectedSegmentID, selectedSegmentIDs.contains(selectedSegmentID) {
            // Keep current primary selection.
        } else {
            selectedSegmentID = firstSelectedSegmentID()
        }

        if selectedSegmentIDs.isEmpty {
            selectedSegmentID = nil
            selectionAnchorSegmentID = nil
            return
        }

        if let preferredAnchorID, validIDs.contains(preferredAnchorID) {
            selectionAnchorSegmentID = preferredAnchorID
        } else if let selectionAnchorSegmentID, validIDs.contains(selectionAnchorSegmentID) {
            // Keep current anchor.
        } else {
            selectionAnchorSegmentID = selectedSegmentID
        }
    }

    func clearSegmentSelection() {
        selectedSegmentID = nil
        selectedSegmentIDs = []
        selectionAnchorSegmentID = nil
    }

    func selectAllSegments() {
        guard !timelineSegments.isEmpty else {
            clearSegmentSelection()
            return
        }

        selectedSegmentIDs = Set(timelineSegments.map(\.id))
        if let selectedSegmentID, selectedSegmentIDs.contains(selectedSegmentID) {
            selectionAnchorSegmentID = selectedSegmentID
        } else if let firstID = timelineSegments.first?.id {
            selectedSegmentID = firstID
            selectionAnchorSegmentID = firstID
        }
    }

    func handleSegmentClick(index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard index >= 0, index < timelineSegments.count else { return }
        // Locked primary track blocks all V1 selection — otherwise a
        // locked clip could still be chosen and then be silently
        // rejected by every editing action, which is confusing.
        guard !isPrimaryTrackLocked() else { return }

        // V1 ↔ overlay selection is mutually exclusive — picking V1
        // takes editing focus away from any selected overlay so
        // Cmd+B / Delete / Inspector all route back to V1.
        selectedOverlaySegmentID = nil

        // Any click on a clip clears cue selection — subtitle selection is
        // mutually exclusive with segment selection.
        selectedSubtitleID = nil

        let clickedID = timelineSegments[index].id

        if modifiers.contains(.shift) {
            let anchorID = selectionAnchorSegmentID ?? selectedSegmentID ?? clickedID
            let anchorIndex = timelineSegments.firstIndex(where: { $0.id == anchorID }) ?? index
            let range = min(anchorIndex, index)...max(anchorIndex, index)
            selectedSegmentIDs = Set(range.map { timelineSegments[$0].id })
            selectedSegmentID = clickedID
            selectionAnchorSegmentID = anchorID
            return
        }

        if modifiers.contains(.command) {
            if selectedSegmentIDs.contains(clickedID) {
                selectedSegmentIDs.remove(clickedID)
                if selectedSegmentIDs.isEmpty {
                    clearSegmentSelection()
                } else {
                    if selectedSegmentID == clickedID {
                        selectedSegmentID = firstSelectedSegmentID(in: selectedSegmentIDs)
                    }
                    if selectionAnchorSegmentID == clickedID {
                        selectionAnchorSegmentID = selectedSegmentID
                    }
                }
            } else {
                selectedSegmentIDs.insert(clickedID)
                selectedSegmentID = clickedID
                selectionAnchorSegmentID = clickedID
            }
            return
        }

        setSingleSelectedSegment(id: clickedID)
    }

    /// Legacy pushUndo — now creates a revision.
    private func pushUndo() {
        // Called before mutations; label will be generic
        // Specific callers should use pushRevision(label:) directly
    }

    /// Recent restore checkpoints, newest first.
    func availableRestoreCheckpoints(limit: Int = 12) -> [EditorRevision] {
        Array(revisions.suffix(limit).reversed())
    }

    /// Restore a checkpoint from the recent restore history list.
    @discardableResult
    func restoreCheckpoint(historyIndex: Int, limit: Int = 12) -> EditorRevision? {
        let checkpoints = availableRestoreCheckpoints(limit: limit)
        guard historyIndex >= 0, historyIndex < checkpoints.count else { return nil }
        let checkpoint = checkpoints[historyIndex]
        restoreRevision(id: checkpoint.id)
        return checkpoint
    }

    private func restoreCheckpointContext(limit: Int = 12) -> String {
        let checkpoints = availableRestoreCheckpoints(limit: limit)
        guard !checkpoints.isEmpty else { return "No restore checkpoints available yet." }

        return checkpoints.enumerated().map { index, revision in
            let trigger = Self.restoreCheckpointTriggerLabel(for: revision.trigger)
            return "[\(index)] id=\(revision.id.uuidString) label=\"\(revision.label)\" trigger=\(trigger) segments=\(revision.segments.count)"
        }
        .joined(separator: "\n")
    }

    private static func restoreCheckpointTriggerLabel(for trigger: RevisionTrigger) -> String {
        switch trigger {
        case .analysis:
            return "analysis"
        case .aiAction:
            return "aiAction"
        case .userEdit:
            return "userEdit"
        case .restore:
            return "restore"
        case .importMedia:
            return "importMedia"
        case .autosave:
            return "autosave"
        case .manualSave:
            return "manualSave"
        }
    }

    func undo() {
        // When a subtitle is selected, Cmd+Z reverts the most recent style
        // edit first (users expect the shortcut to affect whatever they're
        // actively tweaking). Only fall through to timeline revisions when
        // no style history remains.
        if isSubtitleSelected, undoSubtitleStyle() { return }
        guard currentRevisionIndex >= 0 && revisions.count > 0 else { return }
        restoreFromRevisionIndex(currentRevisionIndex)
        if currentRevisionIndex > 0 {
            currentRevisionIndex -= 1
        }
    }

    func redo() {
        if isSubtitleSelected, redoSubtitleStyle() { return }
        guard currentRevisionIndex < revisions.count - 1 else { return }
        currentRevisionIndex += 1
        restoreFromRevisionIndex(currentRevisionIndex)
    }

    /// Restore the whole `Project` from a revision. Uses the new `tracks`
    /// snapshot when present (preserves BGM / overlay / aux tracks) and
    /// falls back to the legacy flat `segments` array for revisions
    /// written before multitrack shipped so old checkpoints still work.
    private func restoreProject(from revision: EditorRevision) {
        if let snapshot = revision.tracks, !snapshot.isEmpty {
            project = Project(tracks: snapshot.map { $0.toTrack() })
            // Defensive: every project needs at least one .video track
            // so the primarySegments shim is safe.
            if !project.tracks.contains(where: { $0.kind == .video }) {
                project.tracks.insert(Project.makePrimaryVideoTrack(), at: 0)
            }
        } else {
            timelineSegments = revision.segments.map { $0.toTimelineSegment() }
        }
        // Tombstones are optional on the revision (old revisions
        // predate the field); nil means "no tombstones at this
        // point", which is the correct pre-feature history.
        subtitleTombstones = revision.subtitleTombstones ?? []
        // Subtitle style is optional on the revision (pre-V1-per-cue
        // revisions don't carry it); nil means "leave the current
        // style alone" — that matches pre-feature undo behaviour for
        // revisions written before this field existed. When present,
        // restore via `isApplyingStyleHistory` so the assignment
        // doesn't double-record into the lightweight style undo
        // stack (which already maintains its own history for the
        // global slider).
        if let restoredStyle = revision.subtitleStyle, restoredStyle != subtitleStyle {
            isApplyingStyleHistory = true
            subtitleStyle = restoredStyle
            isApplyingStyleHistory = false
        }
    }

    /// Restore timeline to a specific revision by ID (non-destructive).
    /// Undo every revision produced by a single agent turn. Looks up all
    /// revisions whose trigger is `.aiAction(messageID: userMessageID)`,
    /// then restores project state to the revision that existed **right
    /// before** the first one. Recorded as a new `.restore` revision so
    /// the user can redo if needed.
    @discardableResult
    func undoAgentTurn(userMessageID: UUID) -> Bool {
        guard let firstIndex = revisions.firstIndex(where: { rev in
            if case .aiAction(let mid) = rev.trigger, mid == userMessageID { return true }
            return false
        }) else { return false }
        let targetIndex = firstIndex - 1
        guard targetIndex >= 0 else { return false }
        restoreRevision(id: revisions[targetIndex].id)
        return true
    }

    /// Serialize a single agent turn's revisions as a JSON trace. Useful
    /// for debugging, evaluation, and sharing reproduction cases.
    func exportAgentTraceJSON(userMessageID: UUID) -> String? {
        struct TraceEntry: Codable {
            let revisionID: UUID
            let label: String
            let timestamp: Date
            let trigger: String
        }
        let entries: [TraceEntry] = revisions.compactMap { rev -> TraceEntry? in
            guard case .aiAction(let mid) = rev.trigger, mid == userMessageID else { return nil }
            return TraceEntry(
                revisionID: rev.id,
                label: rev.label,
                timestamp: rev.timestamp,
                trigger: "aiAction"
            )
        }
        guard !entries.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Group revisions into agent turns — each turn is one user prompt and
    /// all the aiAction revisions produced by its plan. Ordered most-recent
    /// first for display. User-edit revisions between agent turns are
    /// skipped.
    func agentTurnsSummary() -> [(userMessageID: UUID, revisions: [EditorRevision])] {
        var grouped: [UUID: [EditorRevision]] = [:]
        var order: [UUID] = []
        for rev in revisions {
            if case .aiAction(let mid) = rev.trigger {
                if grouped[mid] == nil { order.append(mid) }
                grouped[mid, default: []].append(rev)
            }
        }
        return order.reversed().map { ($0, grouped[$0] ?? []) }
    }


    func restoreRevision(id: UUID) {
        guard let revision = revisions.first(where: { $0.id == id }) else { return }

        restoreProject(from: revision)
        setSingleSelectedSegment(id: revision.selectedSegmentID)

        // Create a NEW revision to record this restore action
        pushRevision(
            label: "Restored: \(revision.label)",
            trigger: .restore(fromRevisionID: revision.id)
        )

        rebuildComposedSubtitles()
        rebuildComposition()
    }

    private func restoreFromRevisionIndex(_ index: Int) {
        guard index >= 0, index < revisions.count else { return }
        let revision = revisions[index]
        restoreProject(from: revision)
        setSingleSelectedSegment(id: revision.selectedSegmentID)
        rebuildComposedSubtitles()
        rebuildComposition()
    }

    /// Load revision history from disk on startup.
    func loadRevisions() async {
        guard let projectRoot else { return }
        let store = RevisionStore(projectRoot: projectRoot)
        self.revisionStore = store
        do {
            try await store.load()
            self.revisions = await store.all()
            self.currentRevisionIndex = revisions.count - 1
        } catch {
            print("⚠️ Failed to load revisions: \(error)")
        }
    }

    private let playbackCore: PlaybackProviding
    // `internal` (default access) so MediaCoreViewModel+Animation.swift
    // can call `importLocalVideo` when landing a freshly-rendered
    // animation mov onto the overlay track.
    let mediaCore: (any MediaCoreImporting)?
    private let store: ProjectStore?
    private let analysisPipeline: (any AnalysisPipelineProtocol)?
    private var overlayRenderer: (any RemotionOverlayRendering)?
    /// Lazily-built content-addressable cache over `overlayRenderer`.
    /// Nil until `overlayRenderer`, `mediaCore`, and `projectRoot` are
    /// all wired — built on first use by `makeOverlayCache()`.
    private var _overlayRenderCache: OverlayRenderCache?
    /// Per-suggestion compose history. Keyed by suggestion id; tracks
    /// how many times the user has clicked "Generate animation" on
    /// THIS suggestion in THIS session, plus a compact summary of the
    /// last 3 takes so the server can deliberately produce something
    /// different on regeneration.
    ///
    /// Cleared on suggestion dismissal. NOT persisted — the goal is
    /// "if the user keeps clicking, keep varying" within one session;
    /// across launches we deliberately reset so a content-cached MOV
    /// from a previous session is reusable on the first click.
    private struct ComposeAttemptHistory {
        var count: Int = 0
        var summaries: [ComposeBrief.PreviousAttemptSummary] = []
    }
    private var composeAttemptHistory: [UUID: ComposeAttemptHistory] = [:]
    /// Segment IDs whose overlay render is currently in-flight (initial
    /// generation or Inspector-triggered re-render). Used by the UI to
    /// show a spinner on the overlay pill.
    @Published var overlaysRendering: Set<UUID> = []

    /// Which AI-generated overlay segment is currently open in the
    /// floating Inspector panel. Set by the TimelineDock's double-click
    /// gesture, cleared when the user closes the panel or the segment
    /// is deleted. Observed by `ContentView` to present the overlay.
    @Published var inspectorOverlaySegmentID: UUID?

    /// Per-segment debounce handles for `scheduleOverlayPropsPatch`.
    /// A new patch for the same segment cancels the previous pending
    /// task so rapid typing in a TextField only triggers one re-render.
    private var overlayPropsDebounceTasks: [UUID: Task<Void, Never>] = [:]
    let projectRoot: URL?

    var selectedRecord: MediaAssetRecord? {
        records.first { $0.id == selectedRecordID }
    }

    /// Returns the list of video records currently placed on the V1
    /// timeline, **deduplicated by source video ID and ordered by
    /// first occurrence on the timeline**. Image placements and
    /// orphaned slots (whose source no longer exists in the library)
    /// are skipped.
    ///
    /// This is the canonical "what does first-cut see?" set — the
    /// timeline drives the cut, never the media library. A clip that
    /// the user dragged off the timeline (or never dragged on) does
    /// not appear here even if it's still in the library.
    var videoRecordsOnTimeline: [MediaAssetRecord] {
        var seen: Set<UUID> = []
        var out: [MediaAssetRecord] = []
        for slot in timelineSegments {
            if !seen.insert(slot.sourceVideoID).inserted { continue }
            guard let record = records.first(where: { $0.id == slot.sourceVideoID }) else { continue }
            guard record.kind == .video else { continue }
            out.append(record)
        }
        return out
    }

    var selectedRecordMessage: String? {
        guard let record = selectedRecord else { return nil }
        guard record.status == .ready, record.derived.proxyRelativePath != nil else {
            return record.errorMessage ?? "Media is not ready for preview."
        }
        guard projectRoot != nil else {
            return "Project root not configured"
        }
        return nil
    }

    init(
        playbackCore: PlaybackProviding,
        mediaCore: (any MediaCoreImporting)? = nil,
        store: ProjectStore? = nil,
        projectRoot: URL? = nil,
        analysisPipeline: (any AnalysisPipelineProtocol)? = nil,
        overlayRenderer: (any RemotionOverlayRendering)? = nil
    ) {
        self.playbackCore = playbackCore
        self.mediaCore = mediaCore
        self.store = store
        self.projectRoot = projectRoot ?? store?.projectRoot
        self.analysisPipeline = analysisPipeline
        self.overlayRenderer = overlayRenderer
        self.showSubtitles = CuttiSettings.subtitlesVisibleByDefault()

        // Restore last-saved session state (subtitle prefs) before any UI
        // bindings latch their initial values.
        if let store {
            let session = store.loadSessionState()
            self.subtitleStyle = session.subtitleStyle
            self.showSubtitles = session.showSubtitles
            self.subtitleTombstones = session.subtitleTombstones
            self.lastAutosavedSession = session
            if let date = session.lastAutosaveAt {
                self.autosaveStatus = .saved(date)
            }
        }

        startAutosaveTimer()
    }

    deinit {
        // Timer owns its RunLoop registration; we just capture it for
        // invalidation. Grabbing a local value avoids the Sendable warning
        // on accessing the Timer property directly from a nonisolated deinit.
        MainActor.assumeIsolated {
            autosaveTimer?.invalidate()
            autosaveTimer = nil
            // Belt-and-suspenders: silence any still-running playback
            // before the VM is gone. The container's `.onDisappear` is
            // the primary stop point for the "leave the editor" flow,
            // but if the VM is ever torn down without first going
            // through onDisappear (programmatic swap, future
            // refactor, test harness, …) this prevents the AVPlayer's
            // audio pipeline from continuing to render the last clip
            // on its way to deallocation.
            player?.pause()
        }
    }

    // MARK: - Autosave Engine

    private func startAutosaveTimer() {
        autosaveTimer?.invalidate()
        let timer = Timer(timeInterval: autosaveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutosave()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    /// Save the current session state and push a revision snapshot if the
    /// timeline changed since the last persist. Safe to call from both the
    /// timer and menu/keyboard shortcut (Cmd+S).
    /// Explicit user-triggered save (⌘S). Flushes the autosave pipeline
    /// to disk **and** drops a distinct checkpoint into the revision
    /// history so the user can restore back to exactly this moment from
    /// the right-side history panel. Unlike `performAutosave`, this
    /// always pushes a revision — even when nothing on the timeline is
    /// dirty — because its contract is "give me a named point in
    /// history", not "persist pending edits".
    func createManualCheckpoint() {
        performAutosave()
        pushRevision(label: "Manual save", trigger: .manualSave)
        bannerMessage = L("Checkpoint saved")
    }

    func performAutosave() {
        guard let store else { return }
        let t0 = Date()

        let currentTracks = project.tracks.map(EditorRevision.PersistableTrack.init(from:))
        let currentSession = EditorSessionState(
            subtitleStyle: subtitleStyle,
            showSubtitles: showSubtitles,
            lastAutosaveAt: Date(),
            currentTracks: currentTracks,
            subtitleTombstones: subtitleTombstones
        )
        // Compare ignoring the timestamp so we don't churn on the clock alone.
        let sessionDirty = currentSession.subtitleStyle != lastAutosavedSession.subtitleStyle ||
            currentSession.showSubtitles != lastAutosavedSession.showSubtitles ||
            currentSession.subtitleTombstones != lastAutosavedSession.subtitleTombstones
        let segmentsDirty = timelineSegments != lastAutosavedSegments
        // Overlay-track edits (moving an image pill, trimming a V2 clip,
        // mute/solo, etc.) don't touch `primarySegments`, so they were
        // invisible to the dirty check above. Track `project.tracks`
        // separately so those changes are persisted too.
        let tracksDirty = project.tracks != lastAutosavedTracks

        guard sessionDirty || segmentsDirty || tracksDirty else {
            return
        }

        print("📝 performAutosave start segmentsDirty=\(segmentsDirty) sessionDirty=\(sessionDirty) tracksDirty=\(tracksDirty) tracks=\(currentTracks.count)")
        autosaveStatus = .saving

        do {
            // Always write the full session (style + tracks) when
            // either side is dirty — splitting writes would leave
            // session.json and tracks out of sync after crashes.
            try store.saveSessionState(currentSession)
            lastAutosavedSession = currentSession
            lastAutosavedTracks = project.tracks
            if segmentsDirty {
                // NOTE: autosave must NOT call pushRevision. Each user
                // mutation already captures its own pre-edit snapshot;
                // pushing again here would insert a spurious POST-edit
                // entry and the first Cmd+Z would "undo" to the same
                // state the user is already looking at — making the
                // shortcut feel broken until pressed a second time.
                lastAutosavedSegments = timelineSegments
            }
            autosaveStatus = .saved(Date())
            print(String(format: "📝 performAutosave done elapsed=%.1fms", Date().timeIntervalSince(t0)*1000))
        } catch {
            autosaveStatus = .error(error.localizedDescription)
            print("📝 performAutosave error \(error.localizedDescription)")
        }
    }

    /// Schedule an autosave ~1s after the current mutation, coalescing
    /// bursts of edits (drag-to-trim, typing) into a single disk write.
    /// The 30s timer is kept as a belt-and-braces fallback.
    func scheduleDebouncedAutosave() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                print("📝 debounced autosave firing")
                self?.performAutosave()
            }
        }
    }

    /// Human-readable label for the current autosave status, e.g.
    /// "Saved · 2m ago", "Saving…", "All changes saved".
    var autosaveStatusText: String {
        switch autosaveStatus {
        case .idle: return "Not saved yet"
        case .saving: return "Saving…"
        case .saved(let at):
            let interval = Date().timeIntervalSince(at)
            if interval < 5 { return "Saved · just now" }
            if interval < 60 { return "Saved · \(Int(interval))s ago" }
            if interval < 3600 { return "Saved · \(Int(interval / 60))m ago" }
            return "Saved · \(Int(interval / 3600))h ago"
        case .error(let msg): return "Autosave failed · \(msg)"
        }
    }

    func select(recordID: UUID) {
        // Preserve the existing preview when re-selecting the same record
        // (e.g. mid-analysis `loadRecords()` → `select()`). Nil'ing the
        // player here would blank the viewer and disable the transport
        // bar for the entire duration of the One-click first cut.
        let isSameSelection = (selectedRecordID == recordID && player != nil)
        selectedRecordID = recordID
        if !isSameSelection {
            player = nil
            clearSegmentSelection()
        }

        prewarmVisibleProxies()
        rebuildTimelineSegments()

        guard let record = selectedRecord else { return }
        // Allow `.analyzing` to still show the source preview — the proxy
        // file is produced during import and remains valid throughout the
        // AI analysis pass.
        guard record.status == .ready || record.status == .analyzing,
              let proxyRelativePath = record.derived.proxyRelativePath else { return }
        guard let projectRoot else { return }

        let proxyURL = projectRoot.appending(path: proxyRelativePath)

        if !timelineSegments.isEmpty {
            // Always rebuild — even on same-record reselect. The
            // previous player may be a flat proxy playback or an
            // older composition whose kept ranges have since been
            // replaced (e.g. by One-click first cut writing new
            // keptRanges). rebuildComposition() preserves the old
            // player until the new AVPlayerItem is ready, so the
            // viewer doesn't blank during mid-analysis reselects.
            rebuildComposition()
        } else if player == nil {
            player = playbackCore.makePlayer(proxyURL: proxyURL)
        }
    }

    /// Rebuild the V1 timeline, **preserving the user's clip ordering**.
    ///
    /// The timeline is the source of truth for "what's in the final
    /// video and in what order" — never the media library. So this
    /// function walks the *existing* timeline slot-by-slot and decides
    /// per slot:
    ///
    /// - If the slot is a **full-source placeholder** (its range
    ///   covers essentially the entire source) AND its source has
    ///   analyzed `keptRanges`, replace that slot with one segment
    ///   per kept range.
    /// - Otherwise (already-expanded sub-range, manual trim, manually
    ///   inserted segment), keep the slot verbatim. This is what
    ///   makes the function **idempotent** — once a slot has been
    ///   expanded into sub-ranges, re-running rebuild leaves it alone.
    ///   Without this guard, every call would re-expand each sub-range
    ///   slot by `keptRanges`, multiplying the timeline by M on each
    ///   call (M → M² → M³ …).
    /// - Records that exist in the library but are NOT on the timeline
    ///   contribute nothing — they were either never dragged in or were
    ///   deliberately deleted from the timeline.
    ///
    /// Duplicate placements of the same source survive: each slot
    /// expands independently. After analysis that means the same kept
    /// ranges appear once per placement, which is the documented v1
    /// behavior for "user dragged the same clip in twice".
    ///
    /// Fallback: if `timelineSegments` is empty (legacy projects
    /// loaded for the first time after this change shipped, or projects
    /// whose persisted timeline hasn't been replayed yet) we fall back
    /// to the old "iterate `records` and emit every record's
    /// `keptRanges`" behavior so existing analyzed projects still come
    /// up with a populated timeline on first load.
    private func rebuildTimelineSegments() {
        let preExisting = timelineSegments

        var allSegments: [TimelineSegment] = []

        if !preExisting.isEmpty {
            for slot in preExisting {
                guard let record = records.first(where: { $0.id == slot.sourceVideoID }) else {
                    // Source record is gone (deleted from library while
                    // still on timeline) — drop the slot to keep the
                    // composition consistent.
                    continue
                }

                let isPlaceholder = Self.slotIsFullSourcePlaceholder(slot: slot, record: record)

                if isPlaceholder, let kept = record.copilot?.keptRanges, !kept.isEmpty {
                    let expanded = Self.expandRecordIntoSegments(
                        record: record,
                        keptRanges: kept,
                        template: slot
                    )
                    allSegments.append(contentsOf: expanded)
                } else {
                    // Already expanded, manually trimmed, or manually
                    // inserted — keep verbatim. Re-expanding here is
                    // what caused the M² timeline explosion (every
                    // select() rebuild would multiply segments by the
                    // source's keptRanges count).
                    allSegments.append(slot)
                }
            }
        } else {
            // Legacy fallback: no timeline yet → emit kept ranges from
            // every analyzed record in `records` order. Matches the
            // behavior shipped before timeline-driven first cut.
            for record in records {
                guard let kept = record.copilot?.keptRanges, !kept.isEmpty else { continue }
                let expanded = Self.expandRecordIntoSegments(record: record, keptRanges: kept)
                allSegments.append(contentsOf: expanded)
            }
        }

        timelineSegments = allSegments
        reconcileSegmentSelection()

        if !allSegments.isEmpty {
            let composedDur = allSegments.reduce(0.0) { $0 + $1.durationSeconds }
            let sourceCount = Set(allSegments.map(\.sourceVideoID)).count
            print("🎬 Timeline: \(allSegments.count) segments from \(sourceCount) source(s), composed \(String(format: "%.1f", composedDur))s")
        } else {
            composedSubtitles = []
        }

        rebuildComposedSubtitles()
    }

    /// True iff the slot's source range covers (essentially) the full
    /// source duration — i.e., it's an unexpanded placeholder produced
    /// by the import auto-append path. AI-expanded sub-ranges and
    /// user-trimmed slots fail this check and are kept verbatim by
    /// `rebuildTimelineSegments`. Tolerance is 50ms on each end to
    /// absorb proxy/source duration rounding and floating-point noise
    /// from JSON round-trips.
    ///
    /// One legitimate corner: a single keptRange covering the entire
    /// source also satisfies this check after expansion, but
    /// re-expanding produces the same single segment, so the timeline
    /// stays at 1 segment (idempotent for that case).
    private static func slotIsFullSourcePlaceholder(slot: TimelineSegment, record: MediaAssetRecord) -> Bool {
        guard let dur = record.analysis?.durationSeconds, dur > 0 else { return false }
        let tolerance: Double = 0.05
        return slot.range.startSeconds <= tolerance
            && slot.range.endSeconds >= dur - tolerance
    }

    /// Compact, deterministic routing hint string fed into the
    /// downstream overlay-generation prompt for a given Phase-1
    /// section role.
    ///
    /// The downstream agent receives this verbatim — its job is to
    /// pick the right Remotion template for the role. The string must
    /// therefore name the canonical template (`SequenceSteps`,
    /// `ProcessFlow`, `Timeline`, `QuoteCard`, `ComparisonGrid`, or
    /// fall back to a non-routing catalog pick) and include the
    /// colloquial cue the LLM will actually attend to (`list`,
    /// `flow`, `timeline`, `Quote`, `Comparison`).
    ///
    /// Roles outside the closed canonical set fall back to a
    /// catalog-pick line that explicitly does *not* mention any
    /// strong-routing template — `BRollSuggestionServiceParsingTests`
    /// asserts on this, so a future contributor can't silently bias
    /// `other` toward (say) `SequenceSteps` by extending the switch
    /// carelessly.
    static func roleRoutingHint(_ role: String, isEnglish: Bool) -> String {
        switch role.lowercased() {
        case "enumeration":
            return isEnglish
                ? "Use the SequenceSteps template — render as a list, optionally split into quartiles."
                : "使用 SequenceSteps 模板 —— 以 list 列表形式呈现，必要时切成四分位。"
        case "process":
            return isEnglish
                ? "Use the ProcessFlow template — render as a stepwise flow."
                : "使用 ProcessFlow 模板 —— 以 flow 步骤流程呈现。"
        case "chronology":
            return isEnglish
                ? "Use the Timeline template — chronological timeline of events."
                : "使用 Timeline 模板 —— 按时间顺序的 timeline。"
        case "quote", "thesis":
            return isEnglish
                ? "Use the QuoteCard template — Quote the speaker's key line verbatim."
                : "使用 QuoteCard 模板 —— Quote 引用讲者的核心金句。"
        case "comparison":
            return isEnglish
                ? "Use the ComparisonGrid template — Comparison side-by-side."
                : "使用 ComparisonGrid 模板 —— Comparison 并列对照。"
        default:
            return isEnglish
                ? "Pick from the catalog — no role-specific routing."
                : "从模板目录中挑选 —— 无特定角色路由。"
        }
    }

    /// Build timeline segments for a single record's kept ranges.
    /// Extracted so `rebuildTimelineSegments` can call it from both the
    /// slot-preserving path and the legacy-fallback path without
    /// duplicating the alternate / subtitle plumbing.
    ///
    /// `template`, when non-nil, is the pre-analysis placeholder slot
    /// being replaced. Slot-level edits the user already made before
    /// analysis (volume, mute, hidden video, speed, effects, PiP /
    /// free-transform layout) are inherited by every expanded
    /// sub-segment so the AI cut respects manual adjustments. The
    /// `range` field is intentionally NOT inherited — kept ranges
    /// always come from the LLM. `placementOffset` and
    /// `linkedSegmentID` are also dropped because they only make
    /// sense as identity-preserving links (1:1) — when the slot
    /// expands into N sub-segments those links can't survive.
    private static func expandRecordIntoSegments(
        record: MediaAssetRecord,
        keptRanges: [TimeRange],
        template: TimelineSegment? = nil
    ) -> [TimelineSegment] {
        let texts: [String]
        if let keptTexts = record.copilot?.keptTexts, keptTexts.count == keptRanges.count {
            texts = keptTexts
        } else {
            texts = parseKeptTextsFromLog(record.copilot?.editLog, rangeCount: keptRanges.count)
        }

        let transcript = record.copilot?.transcript
        let wordTranscript = record.copilot?.wordTranscript
        let alternatesPerRange = record.copilot?.keptAlternativesPerRange

        var out: [TimelineSegment] = []
        for (index, range) in keptRanges.enumerated() {
            let text = texts[safe: index] ?? ""
            let subs = buildSubtitleEntries(
                for: range,
                from: transcript,
                wordTranscript: wordTranscript
            )
            // Stamp record.id onto each alternate so swap-in works
            // even when upstream transcript segments didn't carry a
            // sourceVideoID.
            var alternates = alternatesPerRange?[safe: index] ?? []
            for i in alternates.indices {
                alternates[i].sourceVideoID = record.id
            }
            out.append(TimelineSegment(
                id: UUID(),
                sourceVideoID: record.id,
                range: range,
                text: text,
                subtitles: subs,
                volumeLevel: template?.volumeLevel ?? 1.0,
                isVideoHidden: template?.isVideoHidden ?? false,
                speedRate: template?.speedRate ?? 1.0,
                effects: template?.effects ?? .default,
                placementOffset: nil,
                alternatives: alternates,
                linkedSegmentID: nil,
                pipLayout: template?.pipLayout,
                freeTransform: template?.freeTransform,
                overlaySpec: template?.overlaySpec
            ))
        }
        return out
    }

    /// Build per-sentence subtitle entries for a keptRange from the transcript.
    ///
    /// When a word-level transcript is available, words are grouped into short
    /// chunks that fit on a single line inside the viewer (bounded by character
    /// count and duration). This decouples subtitle lines from segment
    /// boundaries — a long sentence inside a kept range becomes multiple
    /// shorter, correctly-timed subtitles instead of one overflowing line.
    static func buildSubtitleEntries(
        for range: TimeRange,
        from transcript: [TranscriptSegment]?,
        wordTranscript: [TranscriptSegment]? = nil
    ) -> [SubtitleEntry] {
        let rangeDuration = range.endSeconds - range.startSeconds
        guard rangeDuration > 0 else { return [] }

        if let words = wordTranscript, !words.isEmpty {
            let chunks = chunkWords(words, within: range)
            if !chunks.isEmpty { return chunks }
        }

        guard let transcript = transcript else { return [] }

        var result: [SubtitleEntry] = []
        for seg in transcript {
            let overlapStart = max(seg.startSeconds, range.startSeconds)
            let overlapEnd = min(seg.endSeconds, range.endSeconds)
            guard overlapEnd > overlapStart + 0.05 else { continue }

            let relativeStart = overlapStart - range.startSeconds
            let relativeDuration = overlapEnd - overlapStart
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)

            let pieces = splitLongSubtitle(
                text: trimmed,
                relativeStart: relativeStart,
                relativeDuration: relativeDuration
            )
            result.append(contentsOf: pieces)
        }
        return result
    }

    // Display budgets kept small so subtitles never exceed the video width.
    private static let subtitleMaxCJKChars = 14
    private static let subtitleMaxLatinChars = 42
    private static let subtitleMaxDuration: Double = 3.5
    /// Inter-token silence threshold that signals a sentence/clause
    /// boundary. Tuned for Mandarin: typical articulation gap between
    /// chars is 80–150 ms, real "breath/clause" pauses sit at
    /// 200–400 ms, sentence-end stops at 500+ ms. 0.3 s is the
    /// sweet spot — captures real pauses without splitting on
    /// articulation seams.
    private static let subtitleWordGapBreak: Double = 0.3

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,  // CJK symbols/punct
             0x3040...0x30FF,  // Japanese kana
             0x3400...0x4DBF,  // CJK ext A
             0x4E00...0x9FFF,  // CJK unified
             0xF900...0xFAFF,  // CJK compat
             0xFF00...0xFFEF:  // Halfwidth/fullwidth
            return true
        default:
            return false
        }
    }

    private static func isPrimarilyCJK(_ text: String) -> Bool {
        var cjk = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else if scalar.properties.isAlphabetic {
                letters += 1
            }
        }
        return cjk > letters
    }

    private static func exceedsCharBudget(_ text: String) -> Bool {
        if isPrimarilyCJK(text) {
            // Count visible, non-whitespace characters for CJK budget.
            let count = text.unicodeScalars.reduce(0) { $1.properties.isWhitespace ? $0 : $0 + 1 }
            return count > subtitleMaxCJKChars
        }
        return text.count > subtitleMaxLatinChars
    }

    /// Split a single long subtitle line into shorter, proportionally-timed chunks.
    private static func splitLongSubtitle(
        text: String,
        relativeStart: Double,
        relativeDuration: Double
    ) -> [SubtitleEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [SubtitleEntry(
                id: UUID(),
                relativeStart: relativeStart,
                relativeDuration: relativeDuration,
                text: text
            )]
        }

        let needsSplit = exceedsCharBudget(trimmed) || relativeDuration > subtitleMaxDuration
        guard needsSplit else {
            return [SubtitleEntry(
                id: UUID(),
                relativeStart: relativeStart,
                relativeDuration: relativeDuration,
                text: trimmed
            )]
        }

        let pieces = splitTextIntoBudgetedChunks(trimmed)
        guard pieces.count > 1 else {
            return [SubtitleEntry(
                id: UUID(),
                relativeStart: relativeStart,
                relativeDuration: relativeDuration,
                text: trimmed
            )]
        }

        // Allocate duration proportionally to visible character count.
        let weights: [Double] = pieces.map { piece in
            let count = piece.unicodeScalars.reduce(0) { $1.properties.isWhitespace ? $0 : $0 + 1 }
            return max(1.0, Double(count))
        }
        let total = weights.reduce(0, +)

        var out: [SubtitleEntry] = []
        var offset = relativeStart
        for (i, piece) in pieces.enumerated() {
            let dur = relativeDuration * (weights[i] / total)
            out.append(SubtitleEntry(
                id: UUID(),
                relativeStart: offset,
                relativeDuration: dur,
                text: piece
            ))
            offset += dur
        }
        return out
    }

    /// Split text into line-sized chunks preferring punctuation/whitespace boundaries.
    private static func splitTextIntoBudgetedChunks(_ text: String) -> [String] {
        let cjk = isPrimarilyCJK(text)
        let breakers: Set<Character> = cjk
            ? ["，", "。", "！", "？", "、", "；", "：", "—", "…", " ", ",", ".", "!", "?"]
            : [" ", ",", ".", "!", "?", ";", ":", "—"]
        let budget = cjk ? subtitleMaxCJKChars : subtitleMaxLatinChars

        var chunks: [String] = []
        var current = ""
        var sinceBreak = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
            sinceBreak = 0
        }

        for ch in text {
            current.append(ch)
            if !ch.isWhitespace { sinceBreak += 1 }

            let visibleCount = cjk
                ? current.unicodeScalars.reduce(0) { $1.properties.isWhitespace ? $0 : $0 + 1 }
                : current.count

            if visibleCount >= budget, breakers.contains(ch) {
                flush()
            } else if visibleCount >= Int(Double(budget) * 1.4) {
                // Hard cap: force split mid-phrase if we've overshot the budget.
                flush()
            }
            _ = sinceBreak
        }
        flush()
        return chunks
    }

    /// Group word-level transcript entries into short subtitle chunks that
    /// overlap the provided range.
    private static func chunkWords(
        _ words: [TranscriptSegment],
        within range: TimeRange
    ) -> [SubtitleEntry] {
        let overlapping: [TranscriptSegment] = words.compactMap { word in
            let start = max(word.startSeconds, range.startSeconds)
            let end = min(word.endSeconds, range.endSeconds)
            guard end > start + 0.01 else { return nil }
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TranscriptSegment(
                startSeconds: start,
                endSeconds: end,
                text: trimmed,
                sourceVideoID: word.sourceVideoID
            )
        }
        guard !overlapping.isEmpty else { return [] }

        let isCJK: Bool = {
            let combined = overlapping.map(\.text).joined()
            return isPrimarilyCJK(combined)
        }()
        let budget = isCJK ? subtitleMaxCJKChars : subtitleMaxLatinChars

        var result: [SubtitleEntry] = []
        var chunkWords: [TranscriptSegment] = []
        var chunkVisibleChars = 0

        func visibleCount(of text: String) -> Int {
            text.unicodeScalars.reduce(0) { $1.properties.isWhitespace ? $0 : $0 + 1 }
        }

        func joinText(_ segs: [TranscriptSegment]) -> String {
            if isCJK {
                return segs.map(\.text).joined()
            }
            return segs.map(\.text).joined(separator: " ")
        }

        func flush() {
            guard !chunkWords.isEmpty else { return }
            let first = chunkWords.first!
            let last = chunkWords.last!
            let relStart = first.startSeconds - range.startSeconds
            let relDur = last.endSeconds - first.startSeconds
            let text = joinText(chunkWords).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, relDur > 0 {
                // Build per-word timings (entry-relative seconds) so the
                // karaoke composer can highlight each char/word as the
                // playhead crosses it. The composer searches for each
                // timing.text inside the cue text using a `range(of:)`
                // fallback when cumulative cursors drift, which makes
                // this safe even when `joinText` inserts separators
                // (Latin path joins with spaces).
                let timings = chunkWords.map { word in
                    WordTiming(
                        text: word.text,
                        startSeconds: word.startSeconds - first.startSeconds,
                        endSeconds: word.endSeconds - first.startSeconds
                    )
                }
                result.append(SubtitleEntry(
                    id: UUID(),
                    relativeStart: max(0, relStart),
                    relativeDuration: relDur,
                    text: text,
                    wordTimings: timings.isEmpty ? nil : timings
                ))
            }
            chunkWords.removeAll(keepingCapacity: true)
            chunkVisibleChars = 0
        }

        for (i, word) in overlapping.enumerated() {
            let wordVis = visibleCount(of: word.text)

            // Break on long silence gap before this word.
            if let prev = chunkWords.last,
               word.startSeconds - prev.endSeconds > subtitleWordGapBreak {
                flush()
            }

            // Break if this word would push the chunk past budget (but keep at
            // least one word per chunk to guarantee progress).
            if !chunkWords.isEmpty, chunkVisibleChars + wordVis > budget {
                flush()
            }

            // Break if adding this word would exceed max duration.
            if let first = chunkWords.first,
               word.endSeconds - first.startSeconds > subtitleMaxDuration {
                flush()
            }

            chunkWords.append(word)
            chunkVisibleChars += wordVis
            _ = i
        }
        flush()
        return result
    }

    /// Parse kept segment texts from editLog for backward compatibility.
    private static func parseKeptTextsFromLog(_ log: String?, rangeCount: Int) -> [String] {
        guard let log = log else { return [] }
        let lines = log.components(separatedBy: "\n")

        // Collect text lines between "✅" header and "❌" header
        var keptLines: [String] = []
        var inKeptSection = false
        for line in lines {
            if line.contains("✅") { inKeptSection = true; continue }
            if line.contains("❌") { break }
            if inKeptSection, let bracketEnd = line.firstIndex(of: "]") {
                let text = String(line[line.index(bracketEnd, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { keptLines.append(text) }
            }
        }

        // If counts match (no merging happened), return 1:1
        if keptLines.count == rangeCount { return keptLines }

        // If more texts than ranges (merging happened), distribute evenly
        if keptLines.count > rangeCount && rangeCount > 0 {
            var result: [String] = []
            let perRange = keptLines.count / rangeCount
            let extra = keptLines.count % rangeCount
            var offset = 0
            for i in 0..<rangeCount {
                let take = perRange + (i < extra ? 1 : 0)
                let chunk = keptLines[offset..<min(offset + take, keptLines.count)]
                result.append(chunk.joined(separator: " "))
                offset += take
            }
            return result
        }

        return keptLines
    }

    private struct LiveSubtitleMeta {
        let text: String
        let speakerID: Int?
        let translations: [String: String]
        let runs: [SubtitleRun]?
        let sourceStart: Double
        let sourceEnd: Double
    }

    /// Build derived subtitle entries for one or more source-time
    /// ranges of `sourceVideoID`, then overlay metadata
    /// (`speakerID`, `translations`, `runs`) from the pre-edit live
    /// timeline so AIActions like delete / split / trim / setSpeed
    /// don't silently strip user-authored data.
    ///
    /// **Why the overlay exists.** The copilot snapshot
    /// (`record.copilot?.transcript` + `wordTranscript`) is the only
    /// source of subtitle text + word timings. But diarization stamps
    /// `speakerID` on `timelineSegments[*].subtitles[*]` in place, and
    /// translations live there too — neither field is ever written back
    /// into the snapshot. Without this overlay, every AIAction that
    /// goes through `transcriptLookup` produces fresh entries with
    /// `speakerID = nil` and empty `translations`, which collapses the
    /// transcript to a single default speaker (regression seen by the
    /// user after `识别说话人` followed by deleting a cue).
    ///
    /// **Why this is safe to call mid-`apply`.** `AIActionExecutor.apply`
    /// works on a local copy of `segments` and only writes back to
    /// `self.timelineSegments` *after* it returns. So this snapshot of
    /// `self.timelineSegments` always sees the pre-edit state for the
    /// entire batch.
    private func subtitleEntries(
        for ranges: [TimeRange],
        sourceVideoID: UUID
    ) -> [SubtitleEntry] {
        guard let record = records.first(where: { $0.id == sourceVideoID }) else { return [] }
        let transcript = record.copilot?.transcript
        let wordTranscript = record.copilot?.wordTranscript

        let liveMeta: [LiveSubtitleMeta] = timelineSegments
            .filter { $0.sourceVideoID == sourceVideoID }
            .flatMap { seg -> [LiveSubtitleMeta] in
                seg.subtitles.map { entry in
                    let s = seg.range.startSeconds + entry.relativeStart
                    return LiveSubtitleMeta(
                        text: entry.text,
                        speakerID: entry.speakerID,
                        translations: entry.translations,
                        runs: entry.runs,
                        sourceStart: s,
                        sourceEnd: s + entry.relativeDuration
                    )
                }
            }

        return ranges.flatMap { range in
            let derived = Self.buildSubtitleEntries(
                for: range,
                from: transcript,
                wordTranscript: wordTranscript
            )
            return derived.map { entry -> SubtitleEntry in
                let derivedStart = range.startSeconds + entry.relativeStart
                let derivedEnd = derivedStart + entry.relativeDuration
                // Best-overlap match — robust to floating-point
                // boundaries and to a derived entry spanning more
                // than one live entry.
                let best: LiveSubtitleMeta? = liveMeta
                    .map { live -> (live: LiveSubtitleMeta, overlap: Double) in
                        let overlap = max(
                            0,
                            min(live.sourceEnd, derivedEnd) - max(live.sourceStart, derivedStart)
                        )
                        return (live, overlap)
                    }
                    .filter { $0.overlap > 0.001 }
                    .max(by: { $0.overlap < $1.overlap })?
                    .live
                guard let match = best else { return entry }

                // Field-by-field policy:
                //   • speakerID — preserved whenever a live entry
                //     overlaps the derived entry. Survives chunkWords
                //     re-segmenting the new range slightly differently
                //     than the original.
                //   • translations / runs — preserved only when the
                //     matched live entry's text equals the derived
                //     entry's text, so we never persist a stale
                //     translation or violate the
                //     `plainText(runs) == text` invariant.
                let textMatches = match.text == entry.text
                let preservedSpeakerID = match.speakerID
                let preservedTranslations = textMatches ? match.translations : entry.translations
                let preservedRuns = (textMatches && match.runs != nil) ? match.runs : entry.runs

                if preservedSpeakerID == entry.speakerID
                    && preservedTranslations == entry.translations
                    && preservedRuns == entry.runs {
                    return entry
                }

                return SubtitleEntry(
                    id: entry.id,
                    relativeStart: entry.relativeStart,
                    relativeDuration: entry.relativeDuration,
                    text: entry.text,
                    speakerID: preservedSpeakerID,
                    translations: preservedTranslations,
                    runs: preservedRuns,
                    wordTimings: entry.wordTimings,
                    styleOverride: entry.styleOverride
                )
            }
        }
    }

    /// Merge `cueID → translated text` into a segment snapshot,
    /// looking up each target cue by UUID. Separated from the
    /// `translate_subtitles` dispatcher so the write-back path is
    /// unit-testable without mocking an OpenAI client — the lookup-
    /// by-id behavior is the safety contract that keeps a
    /// mid-translation timeline edit from corrupting unrelated cues.
    ///
    /// Cues that no longer exist in `segments` (because the user
    /// deleted them while the translation was awaiting) are reported
    /// in `missingCount` and silently dropped. Cues that moved
    /// between segments (split / reorder) are written in their new
    /// home. Existing translations for other locales are preserved;
    /// we only overwrite the key named by `locale`.
    internal struct SubtitleTranslationMerge {
        let segments: [TimelineSegment]
        let writeCount: Int
        let missingCount: Int
    }

    internal func mergeSubtitleTranslations(
        into segments: [TimelineSegment],
        translations: [UUID: String],
        locale: String
    ) -> SubtitleTranslationMerge {
        var mutated = segments
        var writeCount = 0
        var missingCount = 0
        for (cueID, text) in translations {
            var located = false
            outer: for segIdx in mutated.indices {
                for subIdx in mutated[segIdx].subtitles.indices
                where mutated[segIdx].subtitles[subIdx].id == cueID {
                    let old = mutated[segIdx].subtitles[subIdx]
                    var newTranslations = old.translations
                    newTranslations[locale] = text
                    mutated[segIdx].subtitles[subIdx] = SubtitleEntry(
                        id: old.id,
                        relativeStart: old.relativeStart,
                        relativeDuration: old.relativeDuration,
                        text: old.text,
                        speakerID: old.speakerID,
                        translations: newTranslations,
                        runs: old.runs,
                        wordTimings: old.wordTimings,
                        styleOverride: old.styleOverride
                    )
                    writeCount += 1
                    located = true
                    break outer
                }
            }
            if !located { missingCount += 1 }
        }
        return SubtitleTranslationMerge(
            segments: mutated,
            writeCount: writeCount,
            missingCount: missingCount
        )
    }

    /// Build composed subtitles and timeline index from timeline segments.
    internal func rebuildComposedSubtitles() {
        let t0 = Date()
        print("📝 rebuildComposedSubtitles start segments=\(timelineSegments.count)")
        // Subtitle-only mutations (take text edit, cue delete) take this
        // fast path without touching the AVComposition. Schedule a
        // save so their changes still land on disk.
        scheduleDebouncedAutosave()

        // Rebuild composed timeline index
        composedIndex = ComposedTimelineIndex.build(from: timelineSegments)

        // Phase 1: collect every cue's raw composed range, clipped to
        // its owning segment's window. We keep the full `SubtitleEntry`
        // here (via its `translations` map) so every field that lives
        // on the source entry flows through to `ComposedSubtitle`
        // without us having to remember to extend this tuple each time
        // a new field lands on the entry type — missing fields here
        // silently blank the preview / burn-in.
        var raw: [(id: UUID, speakerID: Int?, text: String, start: Double, end: Double, sourceVideoID: UUID, sourceStart: Double, translations: [String: String], runs: [SubtitleRun]?, wordTimings: [CuttiKit.WordTiming]?, styleOverride: SubtitleCueStyleOverride?)] = []
        var composedOffset: Double = 0

        for segment in timelineSegments {
            let speedRate = segment.normalizedSpeedRate
            let segmentEnd = composedOffset + segment.durationSeconds

            for entry in segment.subtitles {
                let rawStart = composedOffset + (entry.relativeStart / speedRate)
                let rawEnd = rawStart + (entry.relativeDuration / speedRate)

                // Clip each cue to its owning segment's composed
                // window. Trimming / splitting a segment doesn't
                // rewrite its stored subtitle entries (they stay in
                // pre-speed source time), so an entry that used to
                // fit can now extend beyond the segment's current
                // duration.
                let clampedStart = max(composedOffset, rawStart)
                let clampedEnd = min(segmentEnd, rawEnd)

                guard clampedEnd - clampedStart > 0.001 else { continue }

                // Source-video time of this entry's start is stable
                // across future timeline edits — used by the
                // transcript view as a reading-order key so that
                // tombstones (which already store source coordinates)
                // stay in their original reading position when
                // surrounding live cues shift due to deletes.
                let sourceStart = segment.range.startSeconds + entry.relativeStart

                // Translate entry-relative pre-speed wordTimings into
                // entry-relative composed-timeline seconds (divide by
                // speedRate) and shift back by the front-clip amount
                // so timing 0 lines up with the cue's startSeconds.
                // Drop timings that fall outside the clipped window;
                // the karaoke composer is also robust to extras, but
                // filtering here keeps `cue.wordTimings` consistent
                // with `cue.text`/`cue.startSeconds`/`cue.endSeconds`.
                let clippedTimings: [CuttiKit.WordTiming]?
                if let original = entry.wordTimings, !original.isEmpty {
                    let frontClip = clampedStart - rawStart
                    let cueDuration = clampedEnd - clampedStart
                    var converted: [CuttiKit.WordTiming] = []
                    converted.reserveCapacity(original.count)
                    for t in original {
                        let s = (t.startSeconds / speedRate) - frontClip
                        let e = (t.endSeconds / speedRate) - frontClip
                        guard e > 0, s < cueDuration else { continue }
                        converted.append(CuttiKit.WordTiming(
                            text: t.text,
                            startSeconds: max(0, s),
                            endSeconds: min(cueDuration, e)
                        ))
                    }
                    clippedTimings = converted.isEmpty ? nil : converted
                } else {
                    clippedTimings = nil
                }

                raw.append((entry.id, entry.speakerID, entry.text, clampedStart, clampedEnd, segment.sourceVideoID, sourceStart, entry.translations, entry.runs, clippedTimings, entry.styleOverride))
            }
            composedOffset += segment.durationSeconds
        }

        // Phase 2: resolve cross-cue overlaps. Sort by start, then
        // clamp each cue's end to the next cue's start. This matches
        // the same algorithm used by TimelineDock.composedSubtitlePills
        // so the preview's "current cue at time t" always agrees with
        // the timeline pill the user sees under the playhead —
        // professional NLEs keep these two views in lockstep.
        raw.sort { $0.start < $1.start }

        var subs: [ComposedSubtitle] = []
        subs.reserveCapacity(raw.count)
        for i in 0..<raw.count {
            let start = raw[i].start
            var end = raw[i].end
            if i + 1 < raw.count {
                end = min(end, raw[i + 1].start)
            }
            guard end - start > 0.001 else { continue }

            // If overlap-clamp shortened this cue, drop trailing
            // timings whose start is now past the cue end.
            let cueDuration = end - start
            let trimmedTimings: [CuttiKit.WordTiming]?
            if let original = raw[i].wordTimings {
                let trimmed = original.compactMap { t -> CuttiKit.WordTiming? in
                    guard t.startSeconds < cueDuration else { return nil }
                    if t.endSeconds <= cueDuration { return t }
                    return CuttiKit.WordTiming(text: t.text,
                                      startSeconds: t.startSeconds,
                                      endSeconds: cueDuration)
                }
                trimmedTimings = trimmed.isEmpty ? nil : trimmed
            } else {
                trimmedTimings = nil
            }

            subs.append(ComposedSubtitle(
                id: raw[i].id,
                startSeconds: start,
                endSeconds: end,
                text: raw[i].text,
                speakerID: raw[i].speakerID,
                sourceVideoID: raw[i].sourceVideoID,
                sourceStart: raw[i].sourceStart,
                translations: raw[i].translations,
                runs: raw[i].runs,
                wordTimings: trimmedTimings,
                styleOverride: raw[i].styleOverride
            ))
        }

        composedSubtitles = subs
        // Keep the speakers registry in lockstep with whatever speaker
        // IDs the rebuilt cues actually contain, layering any user
        // renames back on top so they survive transcript edits. When
        // diarization hasn't run, rebuildSpeakerRegistry synthesizes a
        // default Speaker(id:0) so the transcript view always has a
        // real avatar to render.
        speakers = rebuildSpeakerRegistry(forCues: subs)
        print(String(format: "📝 rebuildComposedSubtitles done cues=%d elapsed=%.1fms", subs.count, Date().timeIntervalSince(t0)*1000))
    }

    /// Find the subtitle text at a given playhead position.
    func currentSubtitleText(at seconds: Double) -> String? {
        if let pinned = editingSubtitleCueID,
           let cue = composedSubtitles.first(where: { $0.id == pinned }) {
            return cue.text
        }
        return composedSubtitles.first { seconds >= $0.startSeconds && seconds < $0.endSeconds }?.text
    }

    /// Per-character-range style overrides for the active cue. Nil when
    /// the cue has no rich-text emphasis (the preview falls back to a
    /// uniform render). Mirrors `currentSubtitleText` for cue selection
    /// so the overlay's text and runs always belong to the same cue.
    func currentSubtitleRuns(at seconds: Double) -> [SubtitleRun]? {
        if let pinned = editingSubtitleCueID,
           let cue = composedSubtitles.first(where: { $0.id == pinned }) {
            return cue.runs
        }
        return composedSubtitles.first {
            seconds >= $0.startSeconds && seconds < $0.endSeconds
        }?.runs
    }

    /// Translation line to render alongside the primary subtitle text.
    /// Returns nil when (a) the current style is monolingual
    /// (`subtitleStyle.bilingual == nil`), (b) no cue is active, or
    /// (c) the active cue has no translation for the style's secondary
    /// locale. Missing translations fall back to single-line mode; this
    /// helper just gates on availability.
    func currentSubtitleSecondaryText(at seconds: Double) -> String? {
        guard let bilingual = subtitleStyle.bilingual else { return nil }
        let cue: ComposedSubtitle?
        if let pinned = editingSubtitleCueID {
            cue = composedSubtitles.first(where: { $0.id == pinned })
        } else {
            cue = composedSubtitles.first {
                seconds >= $0.startSeconds && seconds < $0.endSeconds
            }
        }
        // Normalize the style's secondary locale before lookup: the
        // translate tool keys `entry.translations` off the canonical
        // form, and the style may have been written through paths that
        // don't yet run the patch's normalizer (older projects, hand-
        // crafted style, etc). Asymmetric keys silently blank the line.
        let lookupKey = BilingualDisplayOptions.normalizeLocale(bilingual.secondaryLocale)
        guard !lookupKey.isEmpty else { return nil }
        guard let c = cue,
              let translated = c.translations[lookupKey]?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !translated.isEmpty
        else { return nil }
        return translated
    }

    /// Return the id of the composed subtitle active at a given playhead
    /// position, if any. Used by the viewer to know which cue is being
    /// edited in-place.
    func currentSubtitleID(at seconds: Double) -> UUID? {
        if let pinned = editingSubtitleCueID,
           composedSubtitles.contains(where: { $0.id == pinned }) {
            return pinned
        }
        return composedSubtitles.first { seconds >= $0.startSeconds && seconds < $0.endSeconds }?.id
    }

    /// Return the speaker that owns the subtitle cue active at `seconds`,
    /// if any. Used by the viewer overlay to show a colored speaker badge
    /// so diarization is visible end-to-end.
    func currentSubtitleSpeaker(at seconds: Double) -> Speaker? {
        let target: ComposedSubtitle?
        if let pinned = editingSubtitleCueID {
            target = composedSubtitles.first(where: { $0.id == pinned })
        } else {
            target = composedSubtitles.first(where: {
                seconds >= $0.startSeconds && seconds < $0.endSeconds
            })
        }
        guard let sid = target?.speakerID else { return nil }
        return speakers.first(where: { $0.id == sid })
    }

    /// Enter inline-subtitle edit mode. Pauses playback and pins the cue
    /// the user double-clicked so the overlay stays mounted through the
    /// full edit session, even if the playhead drifts past the original
    /// cue's window. Caller is responsible for calling
    /// `endSubtitleEditing()` on commit, cancel, or focus-out.
    func beginSubtitleEditing(cueID: UUID) {
        print("📝 VM.beginSubtitleEditing cueID=\(cueID)")
        editingSubtitleCueID = cueID
        player?.pause()
    }

    /// Leave inline-subtitle edit mode without committing. Unpins the
    /// cue so `currentSubtitleText` resumes tracking the playhead.
    func endSubtitleEditing() {
        print("📝 VM.endSubtitleEditing")
        editingSubtitleCueID = nil
    }

    /// Delete the video range covered by the subtitle cue with the given id.
    /// Uses `AIAction.deleteRange` under the hood so undo and the composed
    /// timeline stay consistent. Used by the transcript editor where pressing
    /// Delete on a selected cue removes the corresponding clip.
    func deleteSubtitleCue(id: UUID) {
        deleteSubtitleCues(ids: [id])
    }

    /// Delete every subtitle cue in `ids` in a single undoable step.
    /// For each cue we (a) capture a tombstone carrying the original
    /// source-video coordinates so `restoreSubtitleTombstone` can
    /// reconstruct the clip later, and (b) issue an
    /// `AIAction.deleteRange` spanning the cue's composed window.
    /// Deletions are applied in **descending composed-start order**
    /// because `AIActionExecutor.apply` loops in sequence: doing the
    /// rightmost delete first keeps the leftward composed ranges
    /// pointing at the right moments while we process them.
    func deleteSubtitleCues(ids: [UUID]) {
        guard !ids.isEmpty else { return }

        struct Plan {
            let tombstone: SubtitleTombstone
            let composedStart: Double
            let composedEnd: Double
        }

        // Lookup owning segment for each cue so we can resolve
        // source-video coordinates. Skip cues whose segment is gone
        // (e.g., user already deleted the segment some other way).
        var plans: [Plan] = []
        for id in ids {
            guard let cue = composedSubtitles.first(where: { $0.id == id }) else { continue }
            guard let seg = timelineSegments.first(where: { s in
                s.subtitles.contains(where: { $0.id == id })
            }) else { continue }
            guard let entry = seg.subtitles.first(where: { $0.id == id }) else { continue }

            let rawSourceStart = seg.range.startSeconds + entry.relativeStart
            // Clip to the owning segment's source window — an entry
            // whose raw extent pokes past its segment (e.g., after a
            // trim) is clipped by `rebuildComposedSubtitles`, so the
            // tombstone should store only what actually got removed.
            let clampedSourceStart = max(seg.range.startSeconds, rawSourceStart)
            let clampedSourceEnd = min(
                seg.range.endSeconds,
                rawSourceStart + entry.relativeDuration
            )
            guard clampedSourceEnd > clampedSourceStart else { continue }

            let tombstone = SubtitleTombstone(
                id: entry.id,
                text: entry.text,
                speakerID: entry.speakerID,
                sourceVideoID: seg.sourceVideoID,
                sourceStart: clampedSourceStart,
                sourceEnd: clampedSourceEnd,
                speedRate: seg.normalizedSpeedRate,
                originalComposedStart: cue.startSeconds,
                originalComposedEnd: cue.endSeconds,
                styleOverride: entry.styleOverride
            )
            plans.append(Plan(
                tombstone: tombstone,
                composedStart: cue.startSeconds,
                composedEnd: cue.endSeconds
            ))
        }
        guard !plans.isEmpty else { return }

        // Descending composed-start so earlier deletes don't shift
        // later ones. See AIActionSystem.swift:138 (sequential loop).
        let ordered = plans.sorted { $0.composedStart > $1.composedStart }
        let actions = ordered.map {
            AIAction.deleteRange(start: $0.composedStart, end: $0.composedEnd)
        }
        let batch = AIActionBatch(
            actions: actions,
            explanation: plans.count == 1 ? "Delete subtitle cue" : "Delete \(plans.count) subtitle cues"
        )
        let result = AIActionExecutor.apply(
            batch: batch,
            to: timelineSegments,
            baseSubtitleStyle: subtitleStyle,
            transcriptLookup: { ranges, sourceID in
                self.subtitleEntries(for: ranges, sourceVideoID: sourceID)
            }
        )
        guard result.appliedCount > 0 else { return }
        pushRevision(label: batch.explanation, trigger: .userEdit(description: "delete-subtitle-cues"))
        timelineSegments = result.segments
        subtitleTombstones.append(contentsOf: plans.map { $0.tombstone })
        reconcileSegmentSelection()
        rebuildComposedSubtitles()
        rebuildComposition()
    }

    /// Resurrect a previously tombstoned subtitle cue. Builds a new
    /// `TimelineSegment` covering the original source-video range and
    /// splices it back into its original reading position on the
    /// primary track — specifically, right after the last same-source
    /// segment whose source range ends at or before the tombstone's
    /// source start. This keeps the restored clip next to its
    /// neighbours instead of dumping it at the end, which matches the
    /// transcript reading order users expect.
    func restoreSubtitleTombstone(id: UUID) {
        guard let tombstoneIdx = subtitleTombstones.firstIndex(where: { $0.id == id }) else { return }
        let tombstone = subtitleTombstones[tombstoneIdx]

        let sourceDuration = tombstone.sourceEnd - tombstone.sourceStart
        guard sourceDuration > 0.001 else { return }

        let entry = SubtitleEntry(
            id: tombstone.id,
            relativeStart: 0,
            relativeDuration: sourceDuration,
            text: tombstone.text,
            speakerID: tombstone.speakerID,
            styleOverride: tombstone.styleOverride
        )
        let newSegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: tombstone.sourceVideoID,
            range: TimeRange(
                startSeconds: tombstone.sourceStart,
                endSeconds: tombstone.sourceEnd
            ),
            text: tombstone.text,
            subtitles: [entry],
            speedRate: tombstone.speedRate
        )

        // Walk primary segments and find where this source range
        // belongs, using the source-time coordinate (stable across
        // edits) to preserve original reading order. Insert after the
        // last same-source segment whose `range.endSeconds` sits at or
        // before the tombstone's `sourceStart`; fall back to before
        // the first same-source segment whose `range.startSeconds` is
        // at or after `sourceEnd`; otherwise append at end.
        let segs = timelineSegments
        var insertIndex = segs.count
        var foundLeftNeighbour = false
        for (idx, seg) in segs.enumerated() {
            guard seg.sourceVideoID == tombstone.sourceVideoID else { continue }
            if seg.range.endSeconds <= tombstone.sourceStart + 0.001 {
                insertIndex = idx + 1
                foundLeftNeighbour = true
            } else if !foundLeftNeighbour,
                      seg.range.startSeconds >= tombstone.sourceEnd - 0.001 {
                insertIndex = idx
                break
            }
        }

        pushRevision(label: "Restore subtitle cue", trigger: .userEdit(description: "restore-subtitle-tombstone"))
        var updated = timelineSegments
        updated.insert(newSegment, at: min(insertIndex, updated.count))
        timelineSegments = updated
        subtitleTombstones.remove(at: tombstoneIdx)
        rebuildComposedSubtitles()
        rebuildComposition()
    }


    /// Global find-and-replace across subtitle text. Returns the number of
    /// cues changed. Matching is substring-based; `caseSensitive` controls
    /// whether "foo" matches "Foo".
    @discardableResult
    func replaceSubtitleText(find: String, replace: String, caseSensitive: Bool = false) -> Int {
        guard !find.isEmpty else { return 0 }
        var changed = 0
        var newSegments = timelineSegments
        for segIndex in newSegments.indices {
            for subIndex in newSegments[segIndex].subtitles.indices {
                let old = newSegments[segIndex].subtitles[subIndex]
                let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                guard old.text.range(of: find, options: options) != nil else { continue }
                let updated = old.text.replacingOccurrences(
                    of: find, with: replace, options: options
                )
                if updated != old.text {
                    // Preserve speakerID + translations on text edits.
                    // Drop runs/wordTimings because both have invariants
                    // tied to the exact bytes of `text`
                    // (`runs.plainText == text`, UTF-16 word alignment),
                    // which a textual replace silently violates.
                    newSegments[segIndex].subtitles[subIndex] = SubtitleEntry(
                        id: old.id,
                        relativeStart: old.relativeStart,
                        relativeDuration: old.relativeDuration,
                        text: updated,
                        speakerID: old.speakerID,
                        translations: old.translations,
                        runs: nil,
                        wordTimings: nil,
                        styleOverride: old.styleOverride
                    )
                    changed += 1
                }
            }
        }
        if changed > 0 {
            pushRevision(label: "Replace \"\(find)\" with \"\(replace)\"", trigger: .userEdit(description: "replace-subtitle-text"))
            timelineSegments = newSegments
            rebuildComposedSubtitles()
        }
        return changed
    }

    /// Replace the text of the subtitle entry with the given id (which matches
    /// both `SubtitleEntry.id` and `ComposedSubtitle.id`). Rebuilds the
    /// composed-subtitle index so the viewer overlay and exports update.
    ///
    /// Preserves `speakerID` and `translations` so editing the source
    /// line of a bilingual cue does not silently wipe the AI translation.
    /// Resets `runs` and `wordTimings` because both have invariants tied
    /// to the exact bytes of `text`.
    func updateSubtitleText(id: UUID, newText: String) {
        print("📝 VM.updateSubtitleText start id=\(id) newText=\"\(newText.prefix(30))\"")
        defer { print("📝 VM.updateSubtitleText done") }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var didChange = false
        for segIndex in timelineSegments.indices {
            if let subIndex = timelineSegments[segIndex].subtitles.firstIndex(where: { $0.id == id }) {
                let old = timelineSegments[segIndex].subtitles[subIndex]
                guard old.text != trimmed else { return }
                pushRevision(label: "Edit subtitle text", trigger: .userEdit(description: "edit-subtitle"))
                timelineSegments[segIndex].subtitles[subIndex] = SubtitleEntry(
                    id: old.id,
                    relativeStart: old.relativeStart,
                    relativeDuration: old.relativeDuration,
                    text: trimmed,
                    speakerID: old.speakerID,
                    translations: old.translations,
                    runs: nil,
                    wordTimings: nil,
                    styleOverride: old.styleOverride
                )
                didChange = true
                break
            }
        }
        if didChange {
            rebuildComposedSubtitles()
        }
    }

    /// Update both the source-language line and the secondary-language
    /// translation of a subtitle cue in a single revision.
    ///
    /// - Parameters:
    ///   - id: SubtitleEntry.id to update.
    ///   - primaryText: The new source-language line. Trimmed; an empty
    ///                  primary makes the call a no-op (matching
    ///                  `updateSubtitleText`).
    ///   - secondaryText: The new translation line. Trimmed; an empty
    ///                    secondary REMOVES `translations[locale]` so
    ///                    users can drop a bad AI translation. Other
    ///                    locales' translations are untouched.
    ///   - secondaryLocale: BCP-47 locale of the translation. The locale
    ///                      is normalized via
    ///                      `BilingualDisplayOptions.normalizeLocale` so
    ///                      writes round-trip with the renderer's
    ///                      lookups.
    ///
    /// Pushes a single revision so the change is undoable as one step,
    /// and rebuilds composed subtitles so the preview updates.
    func updateSubtitleBilingualText(
        id: UUID,
        primaryText: String,
        secondaryText: String,
        secondaryLocale: String
    ) {
        let trimmedPrimary = primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecondary = secondaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrimary.isEmpty else { return }
        let normalizedLocale = BilingualDisplayOptions.normalizeLocale(secondaryLocale)
        guard !normalizedLocale.isEmpty else {
            // Fall back to the regular path so we don't silently drop
            // the primary edit when the locale is malformed.
            updateSubtitleText(id: id, newText: trimmedPrimary)
            return
        }
        for segIndex in timelineSegments.indices {
            guard let subIndex = timelineSegments[segIndex].subtitles
                .firstIndex(where: { $0.id == id }) else { continue }
            let old = timelineSegments[segIndex].subtitles[subIndex]
            let primaryChanged = old.text != trimmedPrimary
            var newTranslations = old.translations
            let existing = newTranslations[normalizedLocale] ?? ""
            let secondaryChanged = existing != trimmedSecondary
            if trimmedSecondary.isEmpty {
                newTranslations.removeValue(forKey: normalizedLocale)
            } else {
                newTranslations[normalizedLocale] = trimmedSecondary
            }
            guard primaryChanged || secondaryChanged else { return }
            pushRevision(label: "Edit subtitle text", trigger: .userEdit(description: "edit-subtitle-bilingual"))
            timelineSegments[segIndex].subtitles[subIndex] = SubtitleEntry(
                id: old.id,
                relativeStart: old.relativeStart,
                relativeDuration: old.relativeDuration,
                text: primaryChanged ? trimmedPrimary : old.text,
                speakerID: old.speakerID,
                translations: newTranslations,
                runs: primaryChanged ? nil : old.runs,
                wordTimings: primaryChanged ? nil : old.wordTimings,
                styleOverride: old.styleOverride
            )
            rebuildComposedSubtitles()
            return
        }
    }

    /// Split a cue into two pieces at a UTF-16 character offset within
    /// its `text`. The `SubtitleEntry.split(atUTF16Offset:)` data-layer
    /// helper handles the time-base math: when `wordTimings` are
    /// present, the time boundary snaps to the start of the first
    /// timing whose cumulative UTF-16 cursor crosses the offset;
    /// without timings, the boundary is interpolated proportional to
    /// the character ratio. The left half keeps the original cue's
    /// `id`; the right half gets a fresh `id`. `runs` and
    /// `translations` are dropped on both halves (matching
    /// `updateSubtitleText`).
    ///
    /// No-op when the offset is at a boundary (`0` or `text.utf16.count`).
    func splitSubtitleCue(id: UUID, atUTF16Offset offset: Int) {
        for segIndex in timelineSegments.indices {
            guard let subIndex = timelineSegments[segIndex].subtitles
                .firstIndex(where: { $0.id == id }) else { continue }
            let original = timelineSegments[segIndex].subtitles[subIndex]
            guard let halves = original.split(atUTF16Offset: offset) else {
                print("📝 splitSubtitleCue: offset \(offset) at boundary — no-op")
                return
            }
            pushRevision(
                label: "Split subtitle cue",
                trigger: .userEdit(description: "split-subtitle")
            )
            timelineSegments[segIndex].subtitles
                .replaceSubrange(subIndex...subIndex, with: [halves.left, halves.right])
            print("📝 splitSubtitleCue id=\(id) offset=\(offset) leftDur=\(halves.left.relativeDuration) rightDur=\(halves.right.relativeDuration)")
            rebuildComposedSubtitles()
            return
        }
        print("📝 splitSubtitleCue: cue \(id) not found")
    }

    /// Merge two or more cues into one. All `ids` must:
    /// - belong to the **same** `TimelineSegment.subtitles` array, AND
    /// - sit at **contiguous indices** within that array, AND
    /// - share the same `speakerID`.
    ///
    /// Cross-segment / non-contiguous / cross-speaker requests are
    /// silently rejected (with a log line) — the UI exposes the menu
    /// item even when the selection isn't valid, and the user gets a
    /// no-op rather than a half-applied merge.
    ///
    /// The merged cue's time span covers the extent of all inputs (any
    /// inter-cue gap becomes silent time inside the merged cue), and
    /// `wordTimings` are concatenated with the right halves rebased
    /// onto the merged-cue timeline. See `SubtitleEntry.appending` for
    /// the per-pair fold semantics.
    func mergeSubtitleCues(ids: [UUID]) {
        guard ids.count >= 2 else { return }

        struct Loc { let seg: Int; let sub: Int }
        var locs: [Loc] = []
        locs.reserveCapacity(ids.count)
        for id in ids {
            var found: Loc?
            for segIndex in timelineSegments.indices {
                if let subIndex = timelineSegments[segIndex].subtitles
                    .firstIndex(where: { $0.id == id }) {
                    found = Loc(seg: segIndex, sub: subIndex)
                    break
                }
            }
            guard let location = found else {
                print("📝 mergeSubtitleCues: cue \(id) not found")
                return
            }
            locs.append(location)
        }
        locs.sort { ($0.seg, $0.sub) < ($1.seg, $1.sub) }

        guard let firstLoc = locs.first else { return }
        let segIndex = firstLoc.seg
        guard locs.allSatisfy({ $0.seg == segIndex }) else {
            print("📝 mergeSubtitleCues: cues span multiple segments — abort")
            return
        }
        for i in 1..<locs.count {
            guard locs[i].sub == locs[i - 1].sub + 1 else {
                print("📝 mergeSubtitleCues: cues not contiguous in segment — abort")
                return
            }
        }
        let firstSpeaker = timelineSegments[segIndex].subtitles[firstLoc.sub].speakerID
        let allSameSpeaker = locs.allSatisfy {
            timelineSegments[segIndex].subtitles[$0.sub].speakerID == firstSpeaker
        }
        guard allSameSpeaker else {
            print("📝 mergeSubtitleCues: cues span multiple speakers — abort")
            return
        }

        var merged = timelineSegments[segIndex].subtitles[firstLoc.sub]
        for i in 1..<locs.count {
            let next = timelineSegments[segIndex].subtitles[locs[i].sub]
            merged = merged.appending(next)
        }
        pushRevision(
            label: ids.count == 2 ? "Merge subtitle cues" : "Merge \(ids.count) subtitle cues",
            trigger: .userEdit(description: "merge-subtitles")
        )
        let firstSub = firstLoc.sub
        let lastSub = locs.last!.sub
        timelineSegments[segIndex].subtitles
            .replaceSubrange(firstSub...lastSub, with: [merged])
        print("📝 mergeSubtitleCues count=\(ids.count) seg=\(segIndex) range=\(firstSub)...\(lastSub)")
        rebuildComposedSubtitles()
    }

    /// Convenience: when the user wants to merge a single cue with
    /// the cue immediately after it in the same segment. Returns
    /// silently when there's no successor in the same segment.
    func mergeSubtitleCueWithNext(id: UUID) {
        for segIndex in timelineSegments.indices {
            guard let subIndex = timelineSegments[segIndex].subtitles
                .firstIndex(where: { $0.id == id }) else { continue }
            let entries = timelineSegments[segIndex].subtitles
            guard subIndex + 1 < entries.count else {
                print("📝 mergeSubtitleCueWithNext: cue \(id) is the last in its segment")
                return
            }
            let nextID = entries[subIndex + 1].id
            mergeSubtitleCues(ids: [id, nextID])
            return
        }
    }

    /// Convenience: merge a single cue with the cue immediately before
    /// it. Returns silently when there's no predecessor in the same
    /// segment.
    func mergeSubtitleCueWithPrevious(id: UUID) {
        for segIndex in timelineSegments.indices {
            guard let subIndex = timelineSegments[segIndex].subtitles
                .firstIndex(where: { $0.id == id }) else { continue }
            guard subIndex > 0 else {
                print("📝 mergeSubtitleCueWithPrevious: cue \(id) is the first in its segment")
                return
            }
            let prevID = timelineSegments[segIndex].subtitles[subIndex - 1].id
            mergeSubtitleCues(ids: [prevID, id])
            return
        }
    }

    // MARK: - Subtitle emphasis (per-run styling)

    /// Apply per-run style overrides to one or more UTF-16 ranges inside
    /// a subtitle cue. Ranges are merged before application so adjacent
    /// tokens collapse into a single run. The cue's `text` stays exactly
    /// as-is; only `runs` is written. `mode` controls whether the patch
    /// merges with existing overrides (default) or replaces them outright
    /// on the affected ranges.
    ///
    /// Pushes a revision so the change is undoable and re-triggers the
    /// composed-subtitle rebuild so the preview + export see the new
    /// styling immediately.
    ///
    /// - Parameters:
    ///   - cueID: SubtitleEntry.id to update.
    ///   - utf16Ranges: Character ranges (UTF-16 offsets into `text`).
    ///                  Ranges outside `text` bounds are ignored.
    ///   - patch: Style fields to apply. When `replace` is false (default)
    ///            nil fields inherit the existing run's style; when true
    ///            the entire run style is overwritten (use `.empty` +
    ///            `replace: true` to reset a range to plain styling).
    ///   - replace: false → merge patch into existing styles; true →
    ///              replace styles on the range with `patch` verbatim.
    /// - Returns: true when the cue was found and updated.
    @discardableResult
    func applyEmphasisToSubtitle(
        cueID: UUID,
        utf16Ranges: [NSRange],
        patch: SubtitleRunStyle,
        replace: Bool = false
    ) -> Bool {
        let merged = SubtitleWordTokenizer.mergeRanges(utf16Ranges)
        guard !merged.isEmpty else { return false }

        for segIndex in timelineSegments.indices {
            guard let subIndex = timelineSegments[segIndex]
                .subtitles.firstIndex(where: { $0.id == cueID }) else { continue }

            let old = timelineSegments[segIndex].subtitles[subIndex]
            let utf16Total = (old.text as NSString).length

            // Seed with a single plain run covering the whole text when
            // the cue hasn't been rich-text-edited yet, then apply each
            // patch. This keeps the invariant
            // `runs.plainText == text` under all input paths.
            var runs = old.runs
                ?? [SubtitleRun(text: old.text, style: .empty)]
            var didApply = false
            for range in merged {
                let clampedEnd = min(range.location + range.length, utf16Total)
                guard range.location >= 0, clampedEnd > range.location else { continue }
                let r = range.location..<clampedEnd
                runs = replace
                    ? SubtitleRunEditor.setStyle(on: runs, range: r, style: patch)
                    : SubtitleRunEditor.applyStyle(to: runs, range: r, patch: patch)
                didApply = true
            }
            guard didApply else { return false }
            let normalized = SubtitleRunEditor.normalize(runs)

            pushRevision(label: "Emphasize subtitle words",
                         trigger: .userEdit(description: "emphasize-subtitle"))
            timelineSegments[segIndex].subtitles[subIndex] = SubtitleEntry(
                id: old.id,
                relativeStart: old.relativeStart,
                relativeDuration: old.relativeDuration,
                text: old.text,
                speakerID: old.speakerID,
                translations: old.translations,
                runs: normalized,
                wordTimings: old.wordTimings,
                styleOverride: old.styleOverride
            )
            rebuildComposedSubtitles()
            return true
        }
        return false
    }

    /// Strip all per-run styling from a cue — the cue renders uniformly
    /// with its parent `SubtitleStyle` again. Kept as a distinct helper
    /// because it's what the emphasis sheet's "Clear" button invokes
    /// and what the AI tool uses to undo prior emphasis.
    @discardableResult
    func clearEmphasisOnSubtitle(cueID: UUID) -> Bool {
        for segIndex in timelineSegments.indices {
            guard let subIndex = timelineSegments[segIndex]
                .subtitles.firstIndex(where: { $0.id == cueID }) else { continue }
            let old = timelineSegments[segIndex].subtitles[subIndex]
            guard old.runs != nil else { return false }
            pushRevision(label: "Clear subtitle emphasis",
                         trigger: .userEdit(description: "clear-emphasis"))
            timelineSegments[segIndex].subtitles[subIndex] = SubtitleEntry(
                id: old.id,
                relativeStart: old.relativeStart,
                relativeDuration: old.relativeDuration,
                text: old.text,
                speakerID: old.speakerID,
                translations: old.translations,
                runs: nil,
                wordTimings: old.wordTimings,
                styleOverride: old.styleOverride
            )
            rebuildComposedSubtitles()
            return true
        }
        return false
    }

    // MARK: - Per-cue style override

    /// Resolve the rendered style for the cue with `id`:
    /// `cue.styleOverride?.applied(to: subtitleStyle) ?? subtitleStyle`.
    /// The renderer (viewer overlay + burn-in) calls this for every
    /// composed cue so per-cue overrides land correctly. Falls back to
    /// the project-wide style when the cue is unknown (e.g. composed
    /// cue that doesn't map back to a `SubtitleEntry`, which shouldn't
    /// happen but keeps the renderer side robust).
    func effectiveSubtitleStyle(forCueID id: UUID) -> SubtitleStyle {
        guard let cue = subtitleEntry(forID: id) else { return subtitleStyle }
        return cue.styleOverride?.applied(to: subtitleStyle) ?? subtitleStyle
    }

    /// Locate a `SubtitleEntry` by id across all timeline segments.
    /// O(N) but the cue counts here are tiny in practice; if it ever
    /// becomes hot, fold into a derived dictionary on
    /// `rebuildComposedSubtitles`.
    func subtitleEntry(forID id: UUID) -> SubtitleEntry? {
        for seg in timelineSegments {
            if let cue = seg.subtitles.first(where: { $0.id == id }) {
                return cue
            }
        }
        return nil
    }

    /// Apply a `SubtitleStylePatch` to a single cue's per-cue override.
    /// The patch is layered on top of the cue's *effective* style
    /// (override-or-global), then diffed against the project-wide
    /// `subtitleStyle` to extract just the override fields. A field
    /// dragged back to its project-wide value naturally clears from
    /// the override (because diff sees no delta), and an override
    /// that ends up with no fields collapses to nil so the cue stops
    /// being marked "Customized".
    ///
    /// `commit` controls revision behavior:
    /// - `false` — write to `timelineSegments` silently. Use during
    ///   slider drag (`Slider.onEditingChanged: editing == true`) so
    ///   the viewer overlay updates live without spamming the undo
    ///   stack with intermediate values.
    /// - `true` — write **and** `pushRevision`. Use on mouse-up
    ///   (`editing == false`) and for non-slider controls so Cmd+Z
    ///   reverts the whole interaction in one step.
    ///
    /// Bilingual locale and karaoke fields stay project-wide by
    /// construction — `SubtitleCueStyleOverride` doesn't carry them,
    /// so they are silently dropped from the patch on this path.
    /// Callers that want to set bilingual/karaoke must use the global
    /// `applySubtitleStylePatch(_:commit:)` path instead.
    func applySubtitleStylePatch(
        _ patch: SubtitleStylePatch,
        toCueID cueID: UUID,
        commit: Bool
    ) {
        guard !patch.isEmpty else { return }
        guard let segIdx = timelineSegments.firstIndex(where: { seg in
            seg.subtitles.contains { $0.id == cueID }
        }) else { return }
        guard let subIdx = timelineSegments[segIdx].subtitles
            .firstIndex(where: { $0.id == cueID }) else { return }

        let old = timelineSegments[segIdx].subtitles[subIdx]
        let baseEffective = old.styleOverride?.applied(to: subtitleStyle) ?? subtitleStyle
        let report = patch.applyReporting(to: baseEffective)
        let newEffective = report.style
        let diffedOverride = SubtitleCueStyleOverride.diff(
            effective: newEffective, base: subtitleStyle
        )
        let nextOverride: SubtitleCueStyleOverride? =
            diffedOverride.hasAnyField ? diffedOverride : nil
        if nextOverride == old.styleOverride { return }

        if commit {
            pushRevision(
                label: "Edit subtitle style",
                trigger: .userEdit(description: "edit-cue-style")
            )
        }
        timelineSegments[segIdx].subtitles[subIdx] = SubtitleEntry(
            id: old.id,
            relativeStart: old.relativeStart,
            relativeDuration: old.relativeDuration,
            text: old.text,
            speakerID: old.speakerID,
            translations: old.translations,
            runs: old.runs,
            wordTimings: old.wordTimings,
            styleOverride: nextOverride
        )
        rebuildComposedSubtitles()
    }

    /// Apply a patch to the project-wide `subtitleStyle` (global
    /// scope). Equivalent to `subtitleStyle = patch.applied(to:
    /// subtitleStyle)` — written as a method so the Inspector can use
    /// the same `(SubtitleStylePatch, commit) -> Void` callback shape
    /// for both scopes. The `commit` flag is informational here
    /// because the existing `subtitleStyle.willSet` already coalesces
    /// rapid changes onto one undo step via
    /// `styleUndoCoalesceWindow`.
    func applySubtitleStylePatch(_ patch: SubtitleStylePatch, commit: Bool) {
        guard !patch.isEmpty else { return }
        let report = patch.applyReporting(to: subtitleStyle)
        let next = report.style
        if next == subtitleStyle { return }
        subtitleStyle = next
    }

    /// Apply a full `SubtitleStyle` snapshot to a single cue as a
    /// per-cue override. Computes the diff vs the project-wide
    /// `subtitleStyle` and stores just the diverging fields on the
    /// cue's `styleOverride`; an empty diff collapses the override
    /// back to nil so the cue stops being marked "Customized".
    ///
    /// Lets the Inspector / overlay drive per-cue edits via a plain
    /// `Binding<SubtitleStyle>` (the binding's setter calls this
    /// helper) without having to express every mutable visual field
    /// in `SubtitleStylePatch`. Rapid successive snapshots on the
    /// same cue are coalesced onto a single revision via
    /// `styleUndoCoalesceWindow` so a slider drag yields one
    /// undoable step rather than dozens — matches the global path's
    /// coalescing behaviour.
    func applySubtitleStyleSnapshot(
        _ newStyle: SubtitleStyle,
        toCueID cueID: UUID,
        commit: Bool
    ) {
        guard let segIdx = timelineSegments.firstIndex(where: { seg in
            seg.subtitles.contains { $0.id == cueID }
        }) else { return }
        guard let subIdx = timelineSegments[segIdx].subtitles
            .firstIndex(where: { $0.id == cueID }) else { return }

        let old = timelineSegments[segIdx].subtitles[subIdx]
        let diffedOverride = SubtitleCueStyleOverride.diff(
            effective: newStyle, base: subtitleStyle
        )
        let nextOverride: SubtitleCueStyleOverride? =
            diffedOverride.hasAnyField ? diffedOverride : nil
        if nextOverride == old.styleOverride { return }

        if commit {
            let now = Date()
            let withinWindow: Bool = {
                guard let last = lastPerCueStyleSnapshotAt,
                      lastPerCueStyleSnapshotCueID == cueID
                else { return false }
                return now.timeIntervalSince(last) < styleUndoCoalesceWindow
            }()
            if !withinWindow {
                pushRevision(
                    label: "Edit subtitle style",
                    trigger: .userEdit(description: "edit-cue-style")
                )
            }
            lastPerCueStyleSnapshotAt = now
            lastPerCueStyleSnapshotCueID = cueID
        }

        timelineSegments[segIdx].subtitles[subIdx] = SubtitleEntry(
            id: old.id,
            relativeStart: old.relativeStart,
            relativeDuration: old.relativeDuration,
            text: old.text,
            speakerID: old.speakerID,
            translations: old.translations,
            runs: old.runs,
            wordTimings: old.wordTimings,
            styleOverride: nextOverride
        )
        rebuildComposedSubtitles()
    }

    /// SwiftUI `Binding<SubtitleStyle>` that targets either the
    /// currently-selected cue's effective style (per-cue override
    /// merged onto the project baseline) when a subtitle is selected
    /// in the editor, or the project-wide `subtitleStyle` otherwise.
    /// Set-side routes per-cue writes through
    /// `applySubtitleStyleSnapshot(_:toCueID:commit:)` (auto-coalesced)
    /// and global writes through the existing `subtitleStyle` setter
    /// (which carries its own coalesced lightweight undo stack).
    ///
    /// Inspector + viewer overlay consume this binding so the same
    /// component code drives both scopes — UI components don't need
    /// to know whether they're editing a single cue or the global
    /// baseline.
    var subtitleStyleEffectiveBinding: Binding<SubtitleStyle> {
        Binding(
            get: { [weak self] in
                guard let self else { return SubtitleStyle.default }
                if let id = self.selectedSubtitleID {
                    return self.effectiveSubtitleStyle(forCueID: id)
                }
                return self.subtitleStyle
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if let id = self.selectedSubtitleID {
                    self.applySubtitleStyleSnapshot(newValue, toCueID: id, commit: true)
                } else {
                    self.subtitleStyle = newValue
                }
            }
        )
    }

    /// True when the cue with `id` has a non-empty per-cue style
    /// override (i.e. renders differently from the project-wide
    /// `subtitleStyle`). Drives the "Customized" badge in the
    /// transcript and the "Reset to default" button's enabled state.
    func cueHasStyleOverride(_ id: UUID) -> Bool {
        subtitleEntry(forID: id)?.styleOverride?.hasAnyField == true
    }

    /// "Apply to all cues" — promote the currently-selected cue's
    /// effective style to `subtitleStyle`, then wipe per-cue
    /// overrides project-wide so every cue renders identical to the
    /// one the user was editing. Matches the 剪映 escape-hatch
    /// semantics: one click makes "this look" the new baseline.
    ///
    /// V1 only handles single-cue selection. Returns false when no
    /// cue is selected or the selected cue has no override (the
    /// button shouldn't be enabled in those states; the guard is
    /// belt-and-braces).
    @discardableResult
    func applySelectedCueStyleToAllCues() -> Bool {
        guard let id = selectedSubtitleID else { return false }
        guard let cue = subtitleEntry(forID: id) else { return false }
        guard let override = cue.styleOverride, override.hasAnyField else { return false }
        let promoted = override.applied(to: subtitleStyle)
        if promoted == subtitleStyle && !anyCueHasStyleOverride() {
            return false
        }
        pushRevision(
            label: "Apply cue style to all",
            trigger: .userEdit(description: "apply-cue-style-globally")
        )
        // Silently set the global without re-recording on the
        // lightweight style undo stack — the timeline pushRevision
        // above is already the single undo entry for this whole
        // operation; layering style-undo on top would make Cmd+Z
        // take two presses to reverse one click.
        isApplyingStyleHistory = true
        subtitleStyle = promoted
        isApplyingStyleHistory = false
        // Wipe every cue's override project-wide.
        for segIdx in timelineSegments.indices {
            for subIdx in timelineSegments[segIdx].subtitles.indices {
                let old = timelineSegments[segIdx].subtitles[subIdx]
                guard old.styleOverride != nil else { continue }
                timelineSegments[segIdx].subtitles[subIdx] = SubtitleEntry(
                    id: old.id,
                    relativeStart: old.relativeStart,
                    relativeDuration: old.relativeDuration,
                    text: old.text,
                    speakerID: old.speakerID,
                    translations: old.translations,
                    runs: old.runs,
                    wordTimings: old.wordTimings,
                    styleOverride: nil
                )
            }
        }
        rebuildComposedSubtitles()
        return true
    }

    /// True when ANY cue carries a non-empty style override. Used by
    /// `applySelectedCueStyleToAllCues` to short-circuit the no-op
    /// case (selected cue's override would-be-promoted equals current
    /// global AND no other cue has an override to wipe).
    private func anyCueHasStyleOverride() -> Bool {
        for seg in timelineSegments {
            for cue in seg.subtitles {
                if cue.styleOverride?.hasAnyField == true { return true }
            }
        }
        return false
    }

    /// Clear the currently-selected cue's per-cue style override so
    /// it inherits `subtitleStyle` again. The Inspector "Reset to
    /// default" footer button calls this. Returns false when no cue
    /// is selected or the selected cue has no override (button
    /// shouldn't be enabled in those states).
    @discardableResult
    func resetSelectedCueStyleOverride() -> Bool {
        guard let id = selectedSubtitleID else { return false }
        guard let segIdx = timelineSegments.firstIndex(where: { seg in
            seg.subtitles.contains { $0.id == id }
        }) else { return false }
        guard let subIdx = timelineSegments[segIdx].subtitles
            .firstIndex(where: { $0.id == id }) else { return false }
        let old = timelineSegments[segIdx].subtitles[subIdx]
        guard old.styleOverride != nil else { return false }

        pushRevision(
            label: "Reset cue style",
            trigger: .userEdit(description: "reset-cue-style")
        )
        timelineSegments[segIdx].subtitles[subIdx] = SubtitleEntry(
            id: old.id,
            relativeStart: old.relativeStart,
            relativeDuration: old.relativeDuration,
            text: old.text,
            speakerID: old.speakerID,
            translations: old.translations,
            runs: old.runs,
            wordTimings: old.wordTimings,
            styleOverride: nil
        )
        rebuildComposedSubtitles()
        return true
    }

    // MARK: - Subtitle cue manipulation (timeline S1 lane)
    //
    // SubtitleEntry.relativeStart/relativeDuration are stored in PRE-SPEED
    // SOURCE time measured from the segment's source-in point. The timeline
    // displays them in POST-SPEED COMPOSED time via `source / speed`. These
    // helpers convert between the two and enforce:
    //   * stay within the owning segment's source window
    //   * no overlap with sibling cues in the same segment
    //   * minimum composed duration of 0.2s (so cues remain clickable and
    //     the overlay has time to render)

    /// Minimum cue duration enforced in COMPOSED time; source-time min is
    /// derived via `* speed` per segment.
    private static let minSubtitleComposedDuration: Double = 0.2

    /// Look up which segment index owns the cue with the given id.
    private func segmentIndexOwningSubtitle(_ cueID: UUID) -> Int? {
        for (idx, seg) in timelineSegments.enumerated() {
            if seg.subtitles.contains(where: { $0.id == cueID }) { return idx }
        }
        return nil
    }

    /// Composed (post-speed) start time of the segment at `index`.
    private func composedSegmentStart(at index: Int) -> Double {
        var offset: Double = 0
        for i in 0..<index { offset += timelineSegments[i].durationSeconds }
        return offset
    }

    /// Find the segment whose composed window covers `composedTime`.
    /// Returns nil if `composedTime` lies outside the whole timeline.
    private func segmentAtComposedTime(_ composedTime: Double) -> (index: Int, localComposed: Double)? {
        var offset: Double = 0
        for (idx, seg) in timelineSegments.enumerated() {
            let end = offset + seg.durationSeconds
            if composedTime >= offset && composedTime < end {
                return (idx, composedTime - offset)
            }
            offset = end
        }
        if let last = timelineSegments.indices.last, composedTime >= offset - 0.0001 {
            return (last, timelineSegments[last].durationSeconds)
        }
        return nil
    }

    /// Neighbor-based clamp for a moved/resized cue. Finds the maximum
    /// allowable window around `desiredStart..desiredEnd` without crossing
    /// into adjacent sibling cues (sorted by relativeStart).
    private func clampSubtitleToNeighbors(
        segIndex: Int,
        cueIndex: Int,
        desiredStart: Double,
        desiredDuration: Double
    ) -> (start: Double, duration: Double) {
        let seg = timelineSegments[segIndex]
        let speed = max(0.0001, seg.normalizedSpeedRate)
        let segSourceDuration = seg.durationSeconds * speed
        let minSourceDuration = Self.minSubtitleComposedDuration * speed

        let siblings = seg.subtitles.enumerated()
            .filter { $0.offset != cueIndex }
            .map { $0.element }
            .sorted { $0.relativeStart < $1.relativeStart }

        // Find neighbor bounds around the desired start.
        var leftBound: Double = 0
        var rightBound: Double = segSourceDuration
        for sib in siblings {
            let sibEnd = sib.relativeStart + sib.relativeDuration
            if sibEnd <= desiredStart {
                leftBound = max(leftBound, sibEnd)
            } else if sib.relativeStart >= desiredStart + desiredDuration {
                rightBound = min(rightBound, sib.relativeStart)
                break
            } else {
                // Overlaps — snap the desired range to the nearest non-overlapping slot.
                // Prefer staying on the side where more of the desired range lies.
                let leftRoom = max(0, desiredStart - leftBound)
                let rightRoom = max(0, sib.relativeStart - (desiredStart + desiredDuration))
                if leftRoom >= rightRoom {
                    rightBound = min(rightBound, sib.relativeStart)
                } else {
                    leftBound = max(leftBound, sibEnd)
                }
            }
        }

        var start = max(leftBound, min(desiredStart, rightBound - minSourceDuration))
        let end = min(rightBound, max(desiredStart + desiredDuration, start + minSourceDuration))
        start = max(leftBound, min(start, end - minSourceDuration))
        return (start, max(minSourceDuration, end - start))
    }

    /// Move a subtitle cue to a new composed start time. Cue stays in its
    /// owning segment; composed delta is converted to source time via speed.
    func moveSubtitle(id: UUID, to newComposedStart: Double) {
        guard let oldSegIndex = segmentIndexOwningSubtitle(id) else { return }
        guard let oldCueIndex = timelineSegments[oldSegIndex].subtitles.firstIndex(where: { $0.id == id }) else { return }
        let oldCue = timelineSegments[oldSegIndex].subtitles[oldCueIndex]
        let oldSeg = timelineSegments[oldSegIndex]
        let oldSpeed = max(0.0001, oldSeg.normalizedSpeedRate)
        // Cue duration in COMPOSED seconds (display time) — stays
        // constant across a move even if target segment has a
        // different speed.
        let composedDuration = oldCue.relativeDuration / oldSpeed
        guard composedDuration > 0 else { return }

        // Enumerate every fitting gap across EVERY segment, in
        // composed-space. Each candidate tells us:
        //   - segIndex of the segment the cue would land in
        //   - composedStart / composedEnd of the open slot
        //   - min / max composed-start the cue can occupy inside it
        //
        // Previously we only considered the segment under the drop
        // point, so cross-segment drags silently failed whenever the
        // target segment was already full of other subtitles. That's
        // what made leftward drags feel "stuck" at a segment boundary
        // while rightward drags into the blank tail of the last
        // segment felt unlimited.
        struct Candidate {
            let segIndex: Int
            let minComposedStart: Double
            let maxComposedStart: Double
        }
        var candidates: [Candidate] = []
        var walk: Double = 0
        for (i, seg) in timelineSegments.enumerated() {
            let segStart = walk
            let segComposedDur = seg.durationSeconds
            walk += segComposedDur
            let speed = max(0.0001, seg.normalizedSpeedRate)
            let segSourceDur = segComposedDur * speed
            let reqSourceDur = composedDuration * speed
            guard reqSourceDur <= segSourceDur + 0.0001 else { continue }

            let siblings = seg.subtitles.enumerated()
                .filter { !(i == oldSegIndex && $0.offset == oldCueIndex) }
                .map { $0.element }
                .sorted { $0.relativeStart < $1.relativeStart }

            var gaps: [(start: Double, end: Double)] = []
            var gc: Double = 0
            for sib in siblings {
                if sib.relativeStart > gc + 0.0001 {
                    gaps.append((gc, sib.relativeStart))
                }
                gc = max(gc, sib.relativeStart + sib.relativeDuration)
            }
            if gc < segSourceDur - 0.0001 {
                gaps.append((gc, segSourceDur))
            }

            for g in gaps where (g.end - g.start) + 0.0001 >= reqSourceDur {
                let startMinSource = g.start
                let startMaxSource = g.end - reqSourceDur
                // Convert back to composed space (start of segment +
                // source/speed).
                let minC = segStart + startMinSource / speed
                let maxC = segStart + startMaxSource / speed
                candidates.append(Candidate(
                    segIndex: i,
                    minComposedStart: minC,
                    maxComposedStart: maxC
                ))
            }
        }
        guard !candidates.isEmpty else { return }

        // Pick the candidate whose allowed composed-start range is
        // closest to the user's dragged position. Distance 0 means
        // the drop point falls inside the gap — preferred.
        func distance(_ c: Candidate) -> Double {
            if newComposedStart < c.minComposedStart { return c.minComposedStart - newComposedStart }
            if newComposedStart > c.maxComposedStart { return newComposedStart - c.maxComposedStart }
            return 0
        }
        let chosen = candidates.min(by: { distance($0) < distance($1) })!
        let chosenComposedStart = max(chosen.minComposedStart,
                                      min(chosen.maxComposedStart, newComposedStart))

        let targetSegIndex = chosen.segIndex
        let targetSeg = timelineSegments[targetSegIndex]
        let targetSpeed = max(0.0001, targetSeg.normalizedSpeedRate)
        let targetSegStart = composedSegmentStart(at: targetSegIndex)
        let bestStart = (chosenComposedStart - targetSegStart) * targetSpeed
        let targetDurationSource = composedDuration * targetSpeed

        if targetSegIndex == oldSegIndex && abs(bestStart - oldCue.relativeStart) < 0.0001 {
            return
        }
        pushRevision(label: "Move subtitle", trigger: .userEdit(description: "move-subtitle"))
        // Remove from old segment.
        timelineSegments[oldSegIndex].subtitles.remove(at: oldCueIndex)
        // Insert into target (same segment-index is still valid
        // because we only removed from oldSegIndex — in the case
        // where target == old, we use the array state AFTER removal).
        let newCue = SubtitleEntry(
            id: oldCue.id,
            relativeStart: bestStart,
            relativeDuration: targetDurationSource,
            text: oldCue.text,
            speakerID: oldCue.speakerID,
            translations: oldCue.translations,
            runs: oldCue.runs,
            wordTimings: oldCue.wordTimings,
            styleOverride: oldCue.styleOverride
        )
        timelineSegments[targetSegIndex].subtitles.append(newCue)
        timelineSegments[targetSegIndex].subtitles.sort { $0.relativeStart < $1.relativeStart }
        rebuildComposedSubtitles()
    }

    /// Resize a subtitle cue by moving its left (`.leading`) or right
    /// (`.trailing`) edge to a new composed time.
    enum SubtitleEdge { case leading, trailing }

    func resizeSubtitle(id: UUID, edge: SubtitleEdge, toComposedTime newComposed: Double) {
        guard let segIndex = segmentIndexOwningSubtitle(id) else { return }
        guard let cueIndex = timelineSegments[segIndex].subtitles.firstIndex(where: { $0.id == id }) else { return }
        let seg = timelineSegments[segIndex]
        let speed = max(0.0001, seg.normalizedSpeedRate)
        let segStart = composedSegmentStart(at: segIndex)
        let localComposed = max(0, min(seg.durationSeconds, newComposed - segStart))
        let newSource = localComposed * speed

        let oldCue = seg.subtitles[cueIndex]
        var desiredStart = oldCue.relativeStart
        var desiredDuration = oldCue.relativeDuration
        switch edge {
        case .leading:
            let oldEnd = oldCue.relativeStart + oldCue.relativeDuration
            desiredStart = min(newSource, oldEnd - 0.001)
            desiredDuration = oldEnd - desiredStart
        case .trailing:
            desiredStart = oldCue.relativeStart
            desiredDuration = max(0.001, newSource - oldCue.relativeStart)
        }
        let (clampedStart, clampedDuration) = clampSubtitleToNeighbors(
            segIndex: segIndex,
            cueIndex: cueIndex,
            desiredStart: desiredStart,
            desiredDuration: desiredDuration
        )
        if abs(clampedStart - oldCue.relativeStart) < 0.0001,
           abs(clampedDuration - oldCue.relativeDuration) < 0.0001 {
            return
        }
        pushRevision(label: "Resize subtitle", trigger: .userEdit(description: "resize-subtitle"))
        var newSubs = seg.subtitles
        newSubs[cueIndex] = SubtitleEntry(
            id: oldCue.id,
            relativeStart: clampedStart,
            relativeDuration: clampedDuration,
            text: oldCue.text,
            speakerID: oldCue.speakerID,
            translations: oldCue.translations,
            runs: oldCue.runs,
            wordTimings: oldCue.wordTimings,
            styleOverride: oldCue.styleOverride
        )
        newSubs.sort { $0.relativeStart < $1.relativeStart }
        timelineSegments[segIndex].subtitles = newSubs
        rebuildComposedSubtitles()
    }

    /// Insert a new empty subtitle cue at the given composed time.
    /// Default duration is 1s composed, shrunk to fit the gap to the next
    /// sibling or segment end. Returns the new cue id so the UI can auto-
    /// open the edit popover.
    @discardableResult
    func addSubtitle(atComposedTime composedTime: Double, text: String = L("New subtitle")) -> UUID? {
        guard let hit = segmentAtComposedTime(composedTime) else { return nil }
        let segIndex = hit.index
        let seg = timelineSegments[segIndex]
        let speed = max(0.0001, seg.normalizedSpeedRate)
        let segSourceDuration = seg.durationSeconds * speed
        let desiredSourceStart = min(segSourceDuration, max(0, hit.localComposed * speed))
        let defaultSourceDuration = min(1.0 * speed, segSourceDuration - desiredSourceStart)
        guard defaultSourceDuration >= Self.minSubtitleComposedDuration * speed else {
            bannerMessage = L("Not enough room in the clip for a new subtitle here.")
            return nil
        }
        let newID = UUID()
        // Use the neighbor clamp by temporarily indexing as if this cue
        // exists (cueIndex = nil means "no exclusion"), so the clamp uses
        // all existing siblings.
        let (clampedStart, clampedDuration) = clampSubtitleToNeighbors(
            segIndex: segIndex,
            cueIndex: -1, // no match; excludes nothing
            desiredStart: desiredSourceStart,
            desiredDuration: defaultSourceDuration
        )
        guard clampedDuration >= Self.minSubtitleComposedDuration * speed * 0.5 else {
            bannerMessage = L("Not enough room between subtitles to add here.")
            return nil
        }
        pushRevision(label: "Add subtitle", trigger: .userEdit(description: "add-subtitle"))
        var newSubs = seg.subtitles
        newSubs.append(SubtitleEntry(
            id: newID,
            relativeStart: clampedStart,
            relativeDuration: clampedDuration,
            text: text
        ))
        newSubs.sort { $0.relativeStart < $1.relativeStart }
        timelineSegments[segIndex].subtitles = newSubs
        selectedSubtitleID = newID
        clearSegmentSelection()
        rebuildComposedSubtitles()
        return newID
    }

    /// Remove a subtitle cue without touching the video range underneath.
    /// (`deleteSubtitleCue` removes the video range; this is the pure
    /// subtitle-only delete used by the S1 lane.)
    func removeSubtitleEntry(id: UUID) {
        guard let segIndex = segmentIndexOwningSubtitle(id) else { return }
        guard timelineSegments[segIndex].subtitles.contains(where: { $0.id == id }) else { return }
        pushRevision(label: "Delete subtitle", trigger: .userEdit(description: "delete-subtitle"))
        timelineSegments[segIndex].subtitles.removeAll { $0.id == id }
        if selectedSubtitleID == id { selectedSubtitleID = nil }
        rebuildComposedSubtitles()
    }

    /// Explicit subtitle selection (clears segment selection). Pass nil
    /// to clear the cue selection alone.
    func selectSubtitle(id: UUID?) {
        selectedSubtitleID = id
        if id != nil { clearSegmentSelection() }
    }

    /// Composed (timeline) start time of the cue with `id`, or nil if
    /// no such cue exists. Used by the UI to jump the playhead to the
    /// cue a user just clicked on.
    func composedStartOfSubtitle(id: UUID) -> Double? {
        var offset: Double = 0
        for seg in timelineSegments {
            if let cue = seg.subtitles.first(where: { $0.id == id }) {
                let speed = max(0.0001, seg.normalizedSpeedRate)
                return offset + min(seg.durationSeconds, max(0, cue.relativeStart / speed))
            }
            offset += seg.durationSeconds
        }
        return nil
    }

    /// Export subtitles as SRT format string.
    func exportSRT() -> String {
        SubtitleExporter.srt(from: composedSubtitles)
    }

    /// Export subtitles as WebVTT format string.
    func exportVTT() -> String {
        SubtitleExporter.vtt(from: composedSubtitles)
    }

    /// Move a segment from one position to another and rebuild the composition.
    // MARK: - Lock guards

    /// True when the primary V1 track is locked. Every index-based V1
    /// mutation (`moveSegment`, `beginTrim`, `splitAtPlayhead`,
    /// `deleteSegment(at:)`, `setSegmentVolume(at:)`, …) bails out
    /// immediately when this is true so the user's lock toggle
    /// actually holds.
    func isPrimaryTrackLocked() -> Bool {
        project.tracks.first(where: { $0.kind == .video })?.isLocked ?? false
    }

    func moveSegment(from source: IndexSet, to destination: Int) {
        guard !isPrimaryTrackLocked() else { return }
        pushRevision(label: "Reorder segments", trigger: .userEdit(description: "move"))
        timelineSegments.move(fromOffsets: source, toOffset: destination)
        syncAllLinkedAuxSegments()
        rebuildComposition()
    }

    /// Apply a trim to a segment's edge. Called live during drag.
    private var trimOriginalRange: TimeRange?

    func beginTrim(index: Int) {
        guard index >= 0, index < timelineSegments.count else { return }
        guard !isPrimaryTrackLocked() else { return }
        pushRevision(label: "Trim segment", trigger: .userEdit(description: "trim"))
        trimOriginalRange = timelineSegments[index].range
    }

    func liveTrim(index: Int, edge: HorizontalEdge, deltaSeconds: Double) {
        guard index >= 0, index < timelineSegments.count,
              let original = trimOriginalRange else { return }
        guard !isPrimaryTrackLocked() else { return }

        let sourceDuration = records.first(where: { $0.id == timelineSegments[index].sourceVideoID })?.analysis?.durationSeconds
            ?? .greatestFiniteMagnitude
        let minDuration = 0.2
        let sourceDelta = deltaSeconds * timelineSegments[index].normalizedSpeedRate

        switch edge {
        case .leading:
            let newStart = max(0, original.startSeconds + sourceDelta)
            let maxStart = original.endSeconds - minDuration
            timelineSegments[index].range.startSeconds = min(newStart, maxStart)
        case .trailing:
            let newEnd = min(sourceDuration, original.endSeconds + sourceDelta)
            let minEnd = original.startSeconds + minDuration
            timelineSegments[index].range.endSeconds = max(newEnd, minEnd)
        }
    }

    func endTrim(index: Int) {
        trimOriginalRange = nil
        syncAllLinkedAuxSegments()
        rebuildComposition()
    }

    // MARK: - Segment Editing Operations

    /// Split the segment at the given composed-timeline time into two halves.
    func splitAtPlayhead(composedTime: Double) {
        guard !isPrimaryTrackLocked() else { return }
        let minDuration = 0.2

        // Walk segments to find which one the playhead falls in
        var offset: Double = 0
        var targetIndex: Int?
        var relativeTime: Double = 0

        for (i, seg) in timelineSegments.enumerated() {
            let segEnd = offset + seg.durationSeconds
            if composedTime > offset + minDuration && composedTime < segEnd - minDuration {
                targetIndex = i
                relativeTime = composedTime - offset
                break
            }
            offset = segEnd
        }

        guard let index = targetIndex else { return }

        pushRevision(label: "Split at playhead", trigger: .userEdit(description: "split"))
        let original = timelineSegments[index]
        let splitSourceTime = original.range.startSeconds + (relativeTime * original.normalizedSpeedRate)

        // Preserve existing subtitles (including user-authored ones) by
        // splitting them at the cut point instead of regenerating from the
        // transcript. Offsets are in SOURCE time relative to original.range.startSeconds.
        let splitOffset = splitSourceTime - original.range.startSeconds
        var leftSubs: [SubtitleEntry] = []
        var rightSubs: [SubtitleEntry] = []
        for sub in original.subtitles {
            let subEnd = sub.relativeStart + sub.relativeDuration
            if subEnd <= splitOffset + 0.0001 {
                leftSubs.append(sub)
            } else if sub.relativeStart >= splitOffset - 0.0001 {
                rightSubs.append(SubtitleEntry(
                    id: sub.id,
                    relativeStart: max(0, sub.relativeStart - splitOffset),
                    relativeDuration: sub.relativeDuration,
                    text: sub.text,
                    speakerID: sub.speakerID,
                    styleOverride: sub.styleOverride
                ))
            } else {
                // Cue straddles the split — clip to left, and put a new
                // id'd clone of the tail on the right so both halves
                // remain independently editable.
                let leftDur = splitOffset - sub.relativeStart
                if leftDur > 0.001 {
                    leftSubs.append(SubtitleEntry(
                        id: sub.id,
                        relativeStart: sub.relativeStart,
                        relativeDuration: leftDur,
                        text: sub.text,
                        speakerID: sub.speakerID,
                        styleOverride: sub.styleOverride
                    ))
                }
                let rightDur = subEnd - splitOffset
                if rightDur > 0.001 {
                    rightSubs.append(SubtitleEntry(
                        id: UUID(),
                        relativeStart: 0,
                        relativeDuration: rightDur,
                        text: sub.text,
                        speakerID: sub.speakerID,
                        styleOverride: sub.styleOverride
                    ))
                }
            }
        }

        // Left half
        let leftRange = TimeRange(startSeconds: original.range.startSeconds, endSeconds: splitSourceTime)
        let leftText = String(original.text.prefix(original.text.count / 2))
        var leftSegment = TimelineSegment(id: UUID(), sourceVideoID: original.sourceVideoID, range: leftRange, text: leftText, subtitles: leftSubs)
        leftSegment.volumeLevel = original.volumeLevel
        leftSegment.speedRate = original.speedRate
        leftSegment.effects = original.effects
        // Preserve the alternate-takes pool on both halves so the swap
        // picker remains usable after a split — previously a split
        // silently wiped `alternatives`, and an undo of the split
        // reinstated the segment but left the swap UI empty because
        // there was no history to restore it from.
        leftSegment.alternatives = original.alternatives

        // Right half
        let rightRange = TimeRange(startSeconds: splitSourceTime, endSeconds: original.range.endSeconds)
        let rightText = String(original.text.suffix(original.text.count - original.text.count / 2))
        var rightSegment = TimelineSegment(id: UUID(), sourceVideoID: original.sourceVideoID, range: rightRange, text: rightText, subtitles: rightSubs)
        rightSegment.volumeLevel = original.volumeLevel
        rightSegment.speedRate = original.speedRate
        rightSegment.effects = original.effects
        rightSegment.alternatives = original.alternatives

        timelineSegments.replaceSubrange(index...index, with: [leftSegment, rightSegment])
        setSingleSelectedSegment(id: leftSegment.id)

        // If the V1 clip we just split had detached audio, mirror the
        // split on the aux track so each half keeps its paired audio.
        // Left half keeps the original aux segment (re-linked + range
        // trimmed to [start, splitSource]); a fresh aux segment is
        // inserted right after it for the right half.
        if let originalAuxID = original.linkedSegmentID,
           let (auxTrackIdx, auxSegIdx, auxSeg) = findAuxAudioSegment(segmentID: originalAuxID) {
            let leftAuxRange = TimeRange(startSeconds: auxSeg.range.startSeconds, endSeconds: splitSourceTime)
            let rightAuxRange = TimeRange(startSeconds: splitSourceTime, endSeconds: auxSeg.range.endSeconds)

            project.tracks[auxTrackIdx].segments[auxSegIdx].range = leftAuxRange
            project.tracks[auxTrackIdx].segments[auxSegIdx].linkedSegmentID = leftSegment.id
            leftSegment.linkedSegmentID = project.tracks[auxTrackIdx].segments[auxSegIdx].id

            var rightAux = TimelineSegment(
                id: UUID(),
                sourceVideoID: auxSeg.sourceVideoID,
                range: rightAuxRange,
                text: "",
                subtitles: [],
                placementOffset: 0
            )
            rightAux.volumeLevel = auxSeg.volumeLevel
            rightAux.speedRate = auxSeg.speedRate
            rightAux.linkedSegmentID = rightSegment.id
            rightSegment.linkedSegmentID = rightAux.id
            project.tracks[auxTrackIdx].segments.insert(rightAux, at: auxSegIdx + 1)

            // Re-write the two V1 halves we've just relinked.
            timelineSegments[index] = leftSegment
            timelineSegments[index + 1] = rightSegment
        }

        syncAllLinkedAuxSegments()
        rebuildComposition()
    }

    /// User-facing split entry point that respects which track the
    /// user is editing. When an overlay segment is selected and the
    /// playhead is inside its composed range, we route to the overlay
    /// split (which itself silently noops if the cut is too close to
    /// either edge); otherwise we fall back to the V1 split.
    ///
    /// We don't fall through to V1 just because the cut is near the
    /// overlay's edge — that would surprise the user by splitting the
    /// V1 clip underneath when they explicitly selected the overlay.
    /// Cmd+B and the timeline toolbar's Split button both route
    /// through here so the same shortcut works for AI-generated
    /// animations and B-roll on V2+ tracks. The `selectedOverlaySegmentID`
    /// `didSet` (above) plus the V1-click clear in `handleSegmentClick`
    /// guarantee the selection isn't cross-track-stale, so this
    /// dispatcher's "selected overlay wins" rule is unambiguous.
    func splitAtPlayheadRespectingSelection(composedTime: Double) {
        if let overlayID = selectedOverlaySegmentID,
           let composedRange = overlayComposedRange(segmentID: overlayID),
           composedTime >= composedRange.start,
           composedTime <= composedRange.end {
            splitOverlaySegmentAtPlayhead(segmentID: overlayID, composedTime: composedTime)
            return
        }
        splitAtPlayhead(composedTime: composedTime)
    }

    /// Split the given overlay (V2+) segment at the composed playhead.
    /// The two halves carry the same `sourceVideoID` and re-slice the
    /// underlying media: the left half covers `[range.start,
    /// splitSourceTime]` anchored at the original `placementOffset`,
    /// and the right half covers `[splitSourceTime, range.end]`
    /// anchored at `composedTime`. Visual fields (`pipLayout`,
    /// `freeTransform`, `effects`, `speedRate`, `volumeLevel`) are
    /// preserved on both halves.
    ///
    /// `overlaySpec` is preserved on the LEFT half but dropped on the
    /// RIGHT. Re-rendering the spec produces a fresh full-duration
    /// asset starting at source-time 0, so the right half (whose
    /// `range.startSeconds` is non-zero) would slice into the wrong
    /// part of the new render. Letting the right half be a plain
    /// media slice is correct; the user can undo the split if they
    /// want to keep AI-editing the full clip.
    ///
    /// Subtitles on the original (rare for AI animations but allowed
    /// by the model) are split correctly: cues fully on either side
    /// land in their half, cues that straddle the cut are clipped at
    /// the boundary while preserving `translations`, `speakerID`,
    /// and resetting `runs` / `wordTimings` only when the text
    /// actually changes (which it doesn't on a clean split).
    ///
    /// `linkedSegmentID` (detached-audio link) is dropped on both
    /// halves to avoid two segments pointing at the same aux clip;
    /// in practice overlay segments aren't detached-audio paired,
    /// but the defensive nil keeps the model consistent if they
    /// ever are.
    func splitOverlaySegmentAtPlayhead(segmentID: UUID, composedTime: Double) {
        guard !isSegmentLocked(segmentID) else { return }
        guard let (tIdx, sIdx) = findOverlaySegmentLocation(segmentID: segmentID) else { return }
        guard let composedRange = overlayComposedRange(segmentID: segmentID) else { return }

        let original = project.tracks[tIdx].segments[sIdx]
        let speed = original.normalizedSpeedRate
        let composedStart = composedRange.start
        let composedEnd = composedRange.end
        let minDuration = 0.2

        guard composedTime > composedStart + minDuration,
              composedTime < composedEnd - minDuration else { return }

        let splitSourceTime = original.range.startSeconds + (composedTime - composedStart) * speed
        let splitOffsetInSource = splitSourceTime - original.range.startSeconds

        // Subtitle split (correct bilingual data preservation).
        var leftSubs: [SubtitleEntry] = []
        var rightSubs: [SubtitleEntry] = []
        for sub in original.subtitles {
            let subEnd = sub.relativeStart + sub.relativeDuration
            if subEnd <= splitOffsetInSource + 0.0001 {
                leftSubs.append(sub)
            } else if sub.relativeStart >= splitOffsetInSource - 0.0001 {
                rightSubs.append(SubtitleEntry(
                    id: sub.id,
                    relativeStart: max(0, sub.relativeStart - splitOffsetInSource),
                    relativeDuration: sub.relativeDuration,
                    text: sub.text,
                    speakerID: sub.speakerID,
                    translations: sub.translations,
                    runs: sub.runs,
                    wordTimings: sub.wordTimings,
                    styleOverride: sub.styleOverride
                ))
            } else {
                let leftDur = splitOffsetInSource - sub.relativeStart
                if leftDur > 0.001 {
                    leftSubs.append(SubtitleEntry(
                        id: sub.id,
                        relativeStart: sub.relativeStart,
                        relativeDuration: leftDur,
                        text: sub.text,
                        speakerID: sub.speakerID,
                        translations: sub.translations,
                        runs: nil,
                        wordTimings: nil,
                        styleOverride: sub.styleOverride
                    ))
                }
                let rightDur = subEnd - splitOffsetInSource
                if rightDur > 0.001 {
                    rightSubs.append(SubtitleEntry(
                        id: UUID(),
                        relativeStart: 0,
                        relativeDuration: rightDur,
                        text: sub.text,
                        speakerID: sub.speakerID,
                        translations: sub.translations,
                        runs: nil,
                        wordTimings: nil,
                        styleOverride: sub.styleOverride
                    ))
                }
            }
        }

        let leftRange = TimeRange(
            startSeconds: original.range.startSeconds,
            endSeconds: splitSourceTime
        )
        var leftSegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: original.sourceVideoID,
            range: leftRange,
            text: original.text,
            subtitles: leftSubs,
            volumeLevel: original.volumeLevel,
            isVideoHidden: original.isVideoHidden,
            speedRate: original.speedRate,
            effects: original.effects,
            placementOffset: composedStart,
            alternatives: original.alternatives,
            linkedSegmentID: nil,
            pipLayout: original.pipLayout,
            freeTransform: original.freeTransform,
            overlaySpec: original.overlaySpec
        )

        let rightRange = TimeRange(
            startSeconds: splitSourceTime,
            endSeconds: original.range.endSeconds
        )
        var rightSegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: original.sourceVideoID,
            range: rightRange,
            text: original.text,
            subtitles: rightSubs,
            volumeLevel: original.volumeLevel,
            isVideoHidden: original.isVideoHidden,
            speedRate: original.speedRate,
            effects: original.effects,
            placementOffset: composedTime,
            alternatives: original.alternatives,
            linkedSegmentID: nil,
            pipLayout: original.pipLayout,
            freeTransform: original.freeTransform,
            overlaySpec: nil
        )
        // Touch the locals so the compiler keeps the explicit
        // construction visible if these structs grow new fields.
        _ = leftSegment.id
        _ = rightSegment.id

        pushRevision(label: "Split overlay", trigger: .userEdit(description: "split-overlay"))
        project.tracks[tIdx].segments.replaceSubrange(sIdx...sIdx, with: [leftSegment, rightSegment])
        selectedOverlaySegmentID = leftSegment.id
        rebuildComposition()
    }

    /// Resolve the composed-time `[start, end]` range of an overlay
    /// segment, mirroring `MultiTrackComposer.plan`'s cursor logic so
    /// segments that lack an explicit `placementOffset` are placed in
    /// the running cursor of their track. AI animations always carry
    /// `placementOffset`, but importing a sequence of B-roll clips
    /// onto the same overlay track relies on the running-cursor
    /// fallback and we want Split to work there too.
    func overlayComposedRange(segmentID: UUID) -> (start: Double, end: Double)? {
        for track in project.tracks where track.kind == .overlay {
            var cursor = track.segments.first?.placementOffset ?? 0
            for seg in track.segments {
                if let anchor = seg.placementOffset {
                    cursor = anchor
                }
                let start = cursor
                let end = cursor + seg.durationSeconds
                if seg.id == segmentID {
                    return (start, end)
                }
                cursor = end
            }
        }
        return nil
    }
    func deleteSegment(at index: Int) {
        guard index >= 0, index < timelineSegments.count else { return }
        guard !isPrimaryTrackLocked() else { return }
        pushRevision(label: "Delete segment", trigger: .userEdit(description: "delete"))
        let removed = timelineSegments[index]
        timelineSegments.remove(at: index)

        // Cascade-delete the mirror aux-audio segment so detached audio
        // doesn't outlive its V1 clip.
        if let linkedAuxID = removed.linkedSegmentID {
            removeAuxAudioSegment(linkedAuxID)
        }

        selectedSegmentIDs.remove(removed.id)
        if selectedSegmentIDs.isEmpty {
            if !timelineSegments.isEmpty {
                let safeIndex = min(index, timelineSegments.count - 1)
                setSingleSelectedSegment(id: timelineSegments[safeIndex].id)
            } else {
                clearSegmentSelection()
            }
        } else {
            reconcileSegmentSelection()
        }
        syncAllLinkedAuxSegments()
        rebuildComposedSubtitles()
        rebuildComposition()
    }

    /// Delete the currently selected segment.
    func deleteSelectedSegment() {
        guard let index = selectedSegmentIndex else { return }
        deleteSegment(at: index)
    }

    /// Delete all currently selected segments in one batch.
    func deleteSelectedSegments() {
        guard !isPrimaryTrackLocked() else { return }
        let indexes = selectedSegmentIndices
        guard !indexes.isEmpty else { return }

        if indexes.count == 1, let index = indexes.first {
            deleteSegment(at: index)
            return
        }

        pushRevision(label: "Delete segments", trigger: .userEdit(description: "delete-multi"))
        let nextIndex = indexes.min() ?? 0
        let removedSegments = indexes.map { timelineSegments[$0] }
        let idsToDelete = Set(removedSegments.map { $0.id })
        timelineSegments.removeAll { idsToDelete.contains($0.id) }
        // Cascade-delete linked aux-audio mirrors for each removed V1 seg.
        for removed in removedSegments {
            if let auxID = removed.linkedSegmentID {
                removeAuxAudioSegment(auxID)
            }
        }

        if timelineSegments.isEmpty {
            clearSegmentSelection()
        } else {
            let safeIndex = min(nextIndex, timelineSegments.count - 1)
            setSingleSelectedSegment(id: timelineSegments[safeIndex].id)
        }

        syncAllLinkedAuxSegments()
        rebuildComposedSubtitles()
        rebuildComposition()
    }

    /// Combine selected timeline segments into one. Only collapses
    /// runs where adjacent segments share a source video AND their
    /// source ranges are contiguous (end ≈ start within 50ms). Mixed
    /// sources or gapped ranges surface an error banner — we refuse
    /// to silently re-inflate content the user previously cut.
    ///
    /// Typical use: undoing one or several `splitAtPlayhead` calls.
    func mergeSelectedSegments() {
        guard !isPrimaryTrackLocked() else { return }
        let indexes = selectedSegmentIndices
        guard indexes.count >= 2 else {
            bannerMessage = L("Select 2 or more segments to merge.")
            return
        }

        let sorted = indexes.sorted()
        // Must be a contiguous run: indices [i, i+1, i+2, ...].
        for (pos, idx) in sorted.enumerated() where pos > 0 {
            if idx != sorted[pos - 1] + 1 {
                bannerMessage = L("Merge requires a continuous selection on the timeline.")
                return
            }
        }

        // Verify every adjacent pair is mergeable (same source + abutting).
        let epsilon = 0.05
        for pos in 0..<(sorted.count - 1) {
            let a = timelineSegments[sorted[pos]]
            let b = timelineSegments[sorted[pos + 1]]
            guard a.sourceVideoID == b.sourceVideoID else {
                bannerMessage = L("Can't merge segments from different clips.")
                return
            }
            if abs(a.range.endSeconds - b.range.startSeconds) > epsilon {
                bannerMessage = L("Can't merge — there's a cut between the selected segments.")
                return
            }
        }

        pushRevision(label: "Merge segments", trigger: .userEdit(description: "merge"))

        let first = timelineSegments[sorted.first!]
        let last  = timelineSegments[sorted.last!]
        let mergedRange = TimeRange(
            startSeconds: first.range.startSeconds,
            endSeconds: last.range.endSeconds
        )

        // Preserve existing (possibly user-edited) subtitles. Concatenate
        // each selected segment's cues with a cumulative source-time
        // offset equal to the sum of prior segments' source durations.
        var subs: [SubtitleEntry] = []
        var offsetSource: Double = 0
        for idx in sorted {
            let seg = timelineSegments[idx]
            for sub in seg.subtitles {
                subs.append(SubtitleEntry(
                    id: sub.id,
                    relativeStart: sub.relativeStart + offsetSource,
                    relativeDuration: sub.relativeDuration,
                    text: sub.text,
                    speakerID: sub.speakerID,
                    translations: sub.translations,
                    runs: sub.runs,
                    wordTimings: sub.wordTimings,
                    styleOverride: sub.styleOverride
                ))
            }
            offsetSource += seg.range.endSeconds - seg.range.startSeconds
        }
        subs.sort { $0.relativeStart < $1.relativeStart }
        let mergedText = sorted
            .map { timelineSegments[$0].text }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Preserve the leftmost segment's per-clip tweaks. Merging
        // heterogeneous speed/volume is ambiguous; we pick one side
        // rather than silently averaging or discarding it.
        var merged = TimelineSegment(
            id: UUID(),
            sourceVideoID: first.sourceVideoID,
            range: mergedRange,
            text: mergedText,
            subtitles: subs
        )
        merged.volumeLevel = first.volumeLevel
        merged.speedRate   = first.speedRate
        merged.effects     = first.effects

        timelineSegments.replaceSubrange(sorted.first!...sorted.last!, with: [merged])
        setSingleSelectedSegment(id: merged.id)
        rebuildComposition()
    }

    // MARK: - Restore cut between adjacent segments

    /// Returns the source-time gap (in seconds) immediately BEFORE the
    /// segment at `index`, or nil when there is no restorable cut there
    /// (no previous segment, different source, gap below `0.05`s, or
    /// either side has detached aux audio). Used by the timeline
    /// context menu to decide whether to surface the "Restore N.Ns cut
    /// before this clip" item, and by `restoreCutBetween` as a guard.
    func gapBeforeSegment(at index: Int) -> Double? {
        return restorableGap(leftIndex: index - 1, rightIndex: index)
    }

    /// Returns the source-time gap (in seconds) immediately AFTER the
    /// segment at `index`, or nil when there is no restorable cut there.
    func gapAfterSegment(at index: Int) -> Double? {
        return restorableGap(leftIndex: index, rightIndex: index + 1)
    }

    private func restorableGap(leftIndex: Int, rightIndex: Int) -> Double? {
        guard leftIndex >= 0,
              rightIndex == leftIndex + 1,
              rightIndex < timelineSegments.count else { return nil }
        let left = timelineSegments[leftIndex]
        let right = timelineSegments[rightIndex]
        guard left.sourceVideoID == right.sourceVideoID else { return nil }
        guard left.linkedSegmentID == nil,
              right.linkedSegmentID == nil else { return nil }
        let gap = right.range.startSeconds - left.range.endSeconds
        return gap > 0.05 ? gap : nil
    }

    /// Restore the source-time gap between two adjacent V1 segments
    /// that came from the same source video. Brings back the footage
    /// that was previously cut out (by first-cut, manual delete, or
    /// any other path) along with the matching subtitle cues from the
    /// original transcript.
    ///
    /// Behaviour:
    /// - When the two segments share `speedRate` / `volumeLevel` /
    ///   `isVideoHidden` / non-fade `effects` / `pipLayout` /
    ///   `freeTransform`, the pair is replaced by a single merged
    ///   segment whose `range` covers `[left.range.startSeconds,
    ///   right.range.endSeconds]` — matches the convention of
    ///   `mergeSelectedSegments`.  Outer crossfades are preserved
    ///   (`left.audioFadeIn` + `right.audioFadeOut`); the inner
    ///   pair is dropped because the boundary they faded across no
    ///   longer exists.
    /// - Otherwise a new clip carrying just the recovered footage is
    ///   inserted between them, leaving both untouched. A banner
    ///   explains why no merge happened. The inserted clip inherits
    ///   `speedRate` when both sides agree so the user doesn't hear
    ///   a sudden tempo change inside what was originally one
    ///   continuous span.
    /// - Subtitles for the recovered span are rebuilt from the
    ///   record's transcript via `rebuildSubtitles(for:recordID:)`.
    /// - Tombstones whose source range falls inside the recovered
    ///   span are dropped (the footage they were "remembering" is
    ///   back, so a strikethrough overlay would contradict the
    ///   restored cue).
    /// - Pushes a revision labelled "Restore cut" so the action is
    ///   undoable.
    func restoreCutBetween(leftIndex: Int, rightIndex: Int) {
        guard !isPrimaryTrackLocked() else { return }
        guard restorableGap(leftIndex: leftIndex, rightIndex: rightIndex) != nil else {
            return
        }
        let left = timelineSegments[leftIndex]
        let right = timelineSegments[rightIndex]

        // Source record must exist for transcript / subtitle rebuild.
        // `rebuildSubtitles` returns nil when the record is missing
        // (vs. an empty array when the record exists but isn't
        // transcribed). Refuse the merge in the missing case rather
        // than silently producing a clip with no captions and a
        // potentially broken playback URL.
        guard records.contains(where: { $0.id == left.sourceVideoID }) else {
            bannerMessage = L("Source clip not available — can't restore.")
            return
        }

        pushRevision(label: "Restore cut", trigger: .userEdit(description: "restore-cut"))

        let recoveredStart = left.range.endSeconds
        let recoveredEnd = right.range.startSeconds

        let compatible = effectsCompatibleForRestore(left: left, right: right)

        if compatible {
            // ---- Merge path ----
            let mergedRange = TimeRange(
                startSeconds: left.range.startSeconds,
                endSeconds: right.range.endSeconds
            )
            let mergedSubs = rebuildSubtitles(
                for: mergedRange,
                recordID: left.sourceVideoID
            ) ?? []
            let mergedTextFromSubs = mergedSubs
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let mergedText = mergedTextFromSubs.isEmpty
                ? [left.text, right.text].filter { !$0.isEmpty }.joined(separator: " ")
                : mergedTextFromSubs

            // Preserve outer crossfades; drop the inner pair (which
            // crossfaded across a boundary that no longer exists).
            var mergedEffects = left.effects
            mergedEffects.audioFadeInDuration = left.effects.audioFadeInDuration
            mergedEffects.audioFadeOutDuration = right.effects.audioFadeOutDuration

            var merged = TimelineSegment(
                id: UUID(),
                sourceVideoID: left.sourceVideoID,
                range: mergedRange,
                text: mergedText,
                subtitles: mergedSubs
            )
            merged.volumeLevel = left.volumeLevel
            merged.speedRate = left.speedRate
            merged.isVideoHidden = left.isVideoHidden
            merged.effects = mergedEffects
            merged.alternatives = left.alternatives

            timelineSegments.replaceSubrange(leftIndex...rightIndex, with: [merged])
            dropTombstones(
                inSourceRange: recoveredStart...recoveredEnd,
                forSource: left.sourceVideoID
            )
            setSingleSelectedSegment(id: merged.id)
        } else {
            // ---- Insert fallback ----
            let insertedRange = TimeRange(
                startSeconds: recoveredStart,
                endSeconds: recoveredEnd
            )
            let insertedSubs = rebuildSubtitles(
                for: insertedRange,
                recordID: left.sourceVideoID
            ) ?? []
            let insertedText = insertedSubs
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            var inserted = TimelineSegment(
                id: UUID(),
                sourceVideoID: left.sourceVideoID,
                range: insertedRange,
                text: insertedText,
                subtitles: insertedSubs
            )
            if left.speedRate == right.speedRate {
                inserted.speedRate = left.speedRate
            }

            timelineSegments.insert(inserted, at: rightIndex)
            dropTombstones(
                inSourceRange: recoveredStart...recoveredEnd,
                forSource: left.sourceVideoID
            )
            setSingleSelectedSegment(id: inserted.id)
            bannerMessage = L("Inserted recovered footage as a new clip — adjacent segments had different effects, so they couldn't be merged.")
        }

        syncAllLinkedAuxSegments()
        rebuildComposition()
    }

    /// Compatibility check used by `restoreCutBetween` to decide
    /// merge-vs-insert. Audio fade durations live inside
    /// `SegmentEffects` but encode boundary crossfades — they MUST be
    /// excluded from the equality check, otherwise a cross-faded pair
    /// would always fall into the insert fallback.
    private func effectsCompatibleForRestore(
        left: TimelineSegment,
        right: TimelineSegment
    ) -> Bool {
        func fadeStripped(_ e: SegmentEffects) -> SegmentEffects {
            var c = e
            c.audioFadeInDuration = 0
            c.audioFadeOutDuration = 0
            return c
        }
        return left.speedRate == right.speedRate
            && left.volumeLevel == right.volumeLevel
            && left.isVideoHidden == right.isVideoHidden
            && fadeStripped(left.effects) == fadeStripped(right.effects)
            && left.pipLayout == right.pipLayout
            && left.freeTransform == right.freeTransform
            && left.overlaySpec == nil
            && right.overlaySpec == nil
    }

    /// Drop every tombstone whose source range is fully contained in
    /// `range` for the given `sourceVideoID`. Used after restoring a
    /// cut so soft-deleted strikethrough cues don't shadow the
    /// freshly-recovered footage.
    private func dropTombstones(
        inSourceRange range: ClosedRange<Double>,
        forSource sourceVideoID: UUID
    ) {
        let epsilon = 0.001
        subtitleTombstones.removeAll { tomb in
            tomb.sourceVideoID == sourceVideoID
                && tomb.sourceStart >= range.lowerBound - epsilon
                && tomb.sourceEnd <= range.upperBound + epsilon
        }
    }

    /// Insert a manual segment from source video at the given timeline position.
    func insertManualSegment(
        range: TimeRange,
        at index: Int,
        sourceVideoID: UUID? = nil,
        revisionTrigger: RevisionTrigger = .userEdit(description: "insert"),
        revisionLabel: String = "Insert segment"
    ) {
        guard range.endSeconds - range.startSeconds >= 0.2 else { return }
        guard let sourceID = sourceVideoID ?? selectedRecordID else { return }
        // Pull transcripts off the segment's actual source record so
        // the placeholder gets correct subtitles even when the user
        // currently has a different record selected (e.g. the import
        // auto-add path runs before the new record is selected).
        let sourceRecord = records.first(where: { $0.id == sourceID })
        let subs = Self.buildSubtitleEntries(for: range, from: sourceRecord?.copilot?.transcript)
        let segment = TimelineSegment(id: UUID(), sourceVideoID: sourceID, range: range, text: "", subtitles: subs)
        pushRevision(label: revisionLabel, trigger: revisionTrigger)
        let safeIndex = min(index, timelineSegments.count)
        timelineSegments.insert(segment, at: safeIndex)
        setSingleSelectedSegment(id: segment.id)
        rebuildComposition()
    }

    /// Add a segment covering the full source duration at the end of the timeline.
    func addFullSourceSegment() {
        guard let record = selectedRecord,
              let analysis = record.analysis else { return }
        let range = TimeRange(startSeconds: 0, endSeconds: analysis.durationSeconds)
        insertManualSegment(range: range, at: timelineSegments.count)
    }

    /// Insert a full-duration segment of `mediaID` at the given primary
    /// timeline index. Used by the MediaBrowser → V1 drag-drop path
    /// and the import → auto-append-to-end path.
    /// Index is clamped into `[0, timelineSegments.count]`.
    ///
    /// `revisionTrigger` lets the import path tag its revisions as
    /// `.importMedia` so the History panel can distinguish auto-adds
    /// from user-driven edits / drags.
    func insertMediaAsPrimary(
        mediaID: UUID,
        at insertIndex: Int,
        revisionTrigger: RevisionTrigger = .userEdit(description: "insert"),
        revisionLabel: String = "Insert segment"
    ) {
        guard let record = records.first(where: { $0.id == mediaID }) else {
            bannerMessage = L("Can't add clip — media not found.")
            return
        }
        // Images use a fixed 4s default duration (matches the overlay
        // image default / Final Cut Pro's still-image default) since
        // they have no intrinsic length. CompositionBuilder handles
        // V1 image segments by reserving an empty time range on the
        // primary video track and rendering the still full-screen via
        // the PiP compositor (no AV video track required).
        let duration: Double
        if record.kind == .image {
            duration = 4.0
        } else {
            guard let analysis = record.analysis, analysis.durationSeconds > 0.1 else {
                bannerMessage = L("Can't add clip — analysis not ready.")
                return
            }
            duration = analysis.durationSeconds
        }
        let range = TimeRange(startSeconds: 0, endSeconds: duration)
        insertManualSegment(
            range: range,
            at: insertIndex,
            sourceVideoID: mediaID,
            revisionTrigger: revisionTrigger,
            revisionLabel: revisionLabel
        )
    }

    /// Insert a slice of `mediaID`'s source range — `[sourceStart,
    /// sourceEnd]` in source-video coordinates — as a new V1 segment
    /// at `insertIndex`. Used by the Highlights panel drag-onto-
    /// timeline path: each highlight row carries a span and the user
    /// drops it into a position on the primary track.
    ///
    /// Range is clamped to `[0, sourceDuration]`; clamped span less
    /// than 0.2s emits an "out of range" banner instead of inserting
    /// a degenerate clip.
    func insertSourceSlice(
        mediaID: UUID,
        sourceStart: Double,
        sourceEnd: Double,
        at insertIndex: Int,
        revisionTrigger: RevisionTrigger = .userEdit(description: "insert highlight"),
        revisionLabel: String = "Insert highlight"
    ) {
        guard let record = records.first(where: { $0.id == mediaID }) else {
            bannerMessage = L("Can't add highlight — media not found.")
            return
        }
        guard let analysis = record.analysis, analysis.durationSeconds > 0.1 else {
            bannerMessage = L("Can't add highlight — analysis not ready.")
            return
        }
        let clampedStart = max(0, min(sourceStart, analysis.durationSeconds))
        let clampedEnd = max(clampedStart, min(sourceEnd, analysis.durationSeconds))
        guard clampedEnd - clampedStart >= 0.2 else {
            bannerMessage = L("Can't add highlight — selection is out of range.")
            return
        }
        let range = TimeRange(startSeconds: clampedStart, endSeconds: clampedEnd)
        insertManualSegment(
            range: range,
            at: insertIndex,
            sourceVideoID: mediaID,
            revisionTrigger: revisionTrigger,
            revisionLabel: revisionLabel
        )
    }

    // MARK: - Manual highlights (PR 10)

    /// Returns true if the V1 segment identified by `segmentID` can
    /// be saved to Highlights right now. Used to gate the
    /// "Save to Highlights" context-menu item and the
    /// drop-on-Highlights-panel target so the affordances are
    /// disabled rather than failing post-interaction. Mirrors the
    /// validation gauntlet inside `addManualHighlight` so a green
    /// affordance always succeeds.
    func canSaveSegmentToHighlights(segmentID: UUID) -> Bool {
        guard let segment = timelineSegments.first(where: { $0.id == segmentID }) else { return false }
        guard let record = records.first(where: { $0.id == segment.sourceVideoID }) else { return false }
        guard record.copilot != nil else { return false }
        guard let analysis = record.analysis, analysis.durationSeconds > 0.1 else { return false }
        let span = max(0, segment.range.endSeconds - segment.range.startSeconds)
        return span >= 0.2
    }

    /// Append a `.manual`-origin `.highlight` marker to the source
    /// record's snapshot. Validates against the source's analyzed
    /// duration so we never persist a degenerate marker. Persists to
    /// the manifest when a `ProjectStore` is configured; otherwise
    /// (test mode) mutates the in-memory `records` array only.
    ///
    /// In-memory state is updated synchronously regardless so the
    /// Highlights panel rerenders immediately. The async manifest
    /// write reloads `records` on completion to settle any divergence
    /// (in practice the result is identical).
    func addManualHighlight(
        recordID: UUID,
        sourceStart: Double,
        sourceEnd: Double,
        label: String
    ) {
        guard let recIdx = records.firstIndex(where: { $0.id == recordID }) else {
            bannerMessage = L("Can't save highlight — media not found.")
            return
        }
        let record = records[recIdx]
        guard var snapshot = record.copilot else {
            bannerMessage = L("Can't save highlight — run AI analysis first.")
            return
        }
        guard let analysis = record.analysis, analysis.durationSeconds > 0.1 else {
            bannerMessage = L("Can't save highlight — analysis not ready.")
            return
        }
        let clampedStart = max(0, min(sourceStart, analysis.durationSeconds))
        let clampedEnd = max(clampedStart, min(sourceEnd, analysis.durationSeconds))
        guard clampedEnd - clampedStart >= 0.2 else {
            bannerMessage = L("Can't save highlight — selection is too short.")
            return
        }
        let marker = AICopilotMarker(
            kind: .highlight,
            seconds: clampedStart,
            endSeconds: clampedEnd,
            label: Self.normalizedHighlightLabel(label),
            origin: .manual
        )
        snapshot.markers.append(marker)
        records[recIdx].copilot = snapshot
        bannerMessage = L("Highlight saved.")
        persistMarkerAppend(recordID: recordID, markers: [marker])
    }

    /// Bulk version of `addManualHighlight` for the
    /// drag-segments-onto-Highlights-panel drop. Validates each
    /// segment, groups the resulting markers by source record so we
    /// hit the manifest just once per record, and emits a single
    /// summary banner. Segments whose source has no snapshot /
    /// analysis are silently skipped (the drop affordance was gated
    /// upstream; we count them as `skipped` for the summary).
    func saveTimelineSegmentsToHighlights(_ segmentIDs: [UUID]) {
        guard !segmentIDs.isEmpty else { return }
        let segmentsByID = Dictionary(uniqueKeysWithValues: timelineSegments.map { ($0.id, $0) })
        var perRecord: [UUID: [AICopilotMarker]] = [:]
        var saved = 0
        var skipped = 0
        for segID in segmentIDs {
            guard let seg = segmentsByID[segID] else { skipped += 1; continue }
            guard let record = records.first(where: { $0.id == seg.sourceVideoID }) else {
                skipped += 1; continue
            }
            guard record.copilot != nil else { skipped += 1; continue }
            guard let analysis = record.analysis, analysis.durationSeconds > 0.1 else {
                skipped += 1; continue
            }
            let clampedStart = max(0, min(seg.range.startSeconds, analysis.durationSeconds))
            let clampedEnd = max(clampedStart, min(seg.range.endSeconds, analysis.durationSeconds))
            guard clampedEnd - clampedStart >= 0.2 else { skipped += 1; continue }
            let marker = AICopilotMarker(
                kind: .highlight,
                seconds: clampedStart,
                endSeconds: clampedEnd,
                label: Self.normalizedHighlightLabel(seg.text),
                origin: .manual
            )
            perRecord[seg.sourceVideoID, default: []].append(marker)
            saved += 1
        }
        for (recordID, markers) in perRecord {
            guard let recIdx = records.firstIndex(where: { $0.id == recordID }) else { continue }
            guard var snap = records[recIdx].copilot else { continue }
            snap.markers.append(contentsOf: markers)
            records[recIdx].copilot = snap
        }
        if saved == 0 {
            bannerMessage = L("Couldn't save any highlights — check the analysis status.")
        } else if saved == 1 && skipped == 0 {
            bannerMessage = L("Highlight saved.")
        } else if skipped == 0 {
            bannerMessage = L("Saved %d highlights.", saved)
        } else {
            bannerMessage = L("Saved %d highlights (%d skipped).", saved, skipped)
        }
        guard let store, !perRecord.isEmpty else { return }
        Task { @MainActor [weak self] in
            do {
                var manifest = try store.loadManifest()
                for (recordID, markers) in perRecord {
                    guard let idx = manifest.media.firstIndex(where: { $0.id == recordID }),
                          var snap = manifest.media[idx].copilot else { continue }
                    snap.markers.append(contentsOf: markers)
                    manifest.media[idx].copilot = snap
                }
                try store.saveManifest(manifest)
                await self?.loadRecords()
            } catch {
                self?.bannerMessage = L("Failed to save highlights: %@", error.localizedDescription)
            }
        }
    }

    /// Removes the highlight at `markerIndex` in the record's raw
    /// `copilot.markers` array, but ONLY if the marker at that
    /// position still matches `fingerprint`. The fingerprint check
    /// defends against a `score_hook_candidates` rerun racing with
    /// the user's right-click → Remove flow: if the marker at that
    /// index has changed (e.g. AI markers were replaced en masse),
    /// the call is a no-op + reload so the panel resyncs to the new
    /// state instead of removing the wrong marker.
    func removeHighlight(
        recordID: UUID,
        markerIndex: Int,
        fingerprint: AICopilotPresentation.HighlightFingerprint
    ) {
        guard let recIdx = records.firstIndex(where: { $0.id == recordID }) else {
            bannerMessage = L("Can't remove highlight — media not found.")
            return
        }
        guard var snap = records[recIdx].copilot,
              markerIndex >= 0,
              markerIndex < snap.markers.count else {
            bannerMessage = L("Highlight no longer exists.")
            return
        }
        let m = snap.markers[markerIndex]
        guard m.kind == .highlight,
              m.seconds == fingerprint.seconds,
              m.endSeconds == fingerprint.endSeconds,
              m.origin == fingerprint.origin,
              m.label == fingerprint.label else {
            bannerMessage = L("Highlight has changed. Try again.")
            return
        }
        snap.markers.remove(at: markerIndex)
        records[recIdx].copilot = snap
        bannerMessage = L("Highlight removed.")
        guard let store else { return }
        Task { @MainActor [weak self] in
            do {
                var manifest = try store.loadManifest()
                guard let idx = manifest.media.firstIndex(where: { $0.id == recordID }),
                      var snap = manifest.media[idx].copilot,
                      markerIndex >= 0,
                      markerIndex < snap.markers.count else {
                    await self?.loadRecords()
                    return
                }
                let dm = snap.markers[markerIndex]
                guard dm.kind == .highlight,
                      dm.seconds == fingerprint.seconds,
                      dm.endSeconds == fingerprint.endSeconds,
                      dm.origin == fingerprint.origin,
                      dm.label == fingerprint.label else {
                    await self?.loadRecords()
                    return
                }
                snap.markers.remove(at: markerIndex)
                manifest.media[idx].copilot = snap
                try store.saveManifest(manifest)
                await self?.loadRecords()
            } catch {
                self?.bannerMessage = L("Failed to remove highlight: %@", error.localizedDescription)
            }
        }
    }

    /// Single-newline collapse + 60-char trim used by both the
    /// single-segment and bulk save paths to keep persisted labels
    /// readable. Empty inputs fall back to a generic
    /// "Manual highlight" so rows never render as blank.
    private static func normalizedHighlightLabel(_ raw: String) -> String {
        let collapsed = raw
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let body = collapsed.isEmpty ? L("Manual highlight") : collapsed
        return String(body.prefix(60))
    }

    /// Async manifest writer for the single-marker append path. Reads
    /// fresh manifest so concurrent analysis writes don't get
    /// clobbered, applies the append, saves, then reloads. No-op when
    /// there's no `ProjectStore` (test mode); the in-memory record
    /// has already been mutated by the caller.
    private func persistMarkerAppend(recordID: UUID, markers: [AICopilotMarker]) {
        guard let store, !markers.isEmpty else { return }
        Task { @MainActor [weak self] in
            do {
                var manifest = try store.loadManifest()
                guard let idx = manifest.media.firstIndex(where: { $0.id == recordID }),
                      var snap = manifest.media[idx].copilot else { return }
                snap.markers.append(contentsOf: markers)
                manifest.media[idx].copilot = snap
                try store.saveManifest(manifest)
                await self?.loadRecords()
            } catch {
                self?.bannerMessage = L("Failed to save highlight: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Use-as-hook (PR 11)

    /// Whether the per-row ⚡ "Use as hook" button on a Highlights panel
    /// row should be enabled. Mirrors all gates the dispatcher applies
    /// to `add_hook_teaser`:
    ///   - the marker must carry an `endSeconds` (legacy markers
    ///     persisted before PR 8 are excluded — they have no span).
    ///   - the source record must still be present and a video.
    ///   - chat scope chips must be empty (matches the
    ///     `add_hook_teaser` dispatcher's scope guard).
    ///   - no agent run is currently in flight (avoid interleaving a
    ///     UI-driven proposal with `emittedProposalThisTurn`
    ///     accounting and live-narration in `runAgentLoop`).
    func canUseHighlightAsHook(_ row: AICopilotPresentation.HighlightRow) -> Bool {
        guard row.endSeconds != nil else { return false }
        guard chatAttachmentScope.isEmpty else { return false }
        guard !isChatProcessing else { return false }
        return records.contains { $0.id == row.sourceVideoID && $0.kind == .video }
    }

    /// Insert a Pending opening-hook proposal seeded from a Highlights
    /// row, bypassing the LLM round-trip. Equivalent to the
    /// `add_hook_teaser` dispatcher path but invoked directly from the
    /// row's ⚡ button. Like the LLM path, this never auto-applies — the
    /// user must click Apply on the resulting card.
    ///
    /// On success: a `ProposedBatch` lands at the head of
    /// `pendingProposals`, an assistant chat bubble (anchored to the
    /// proposal via `proposedBatchID`) is appended to render the card,
    /// and a brief banner confirms the action. On any rejection
    /// (scope chips, missing record, validation errors, active agent
    /// run), `bannerMessage` carries the reason and the call is a
    /// no-op.
    func useHighlightAsHook(_ row: AICopilotPresentation.HighlightRow) {
        guard !isChatProcessing else {
            bannerMessage = L("Wait for the current AI run to finish before using a highlight as a hook.")
            return
        }
        guard chatAttachmentScope.isEmpty else {
            bannerMessage = L("Detach the scope chips above the chat box to use a highlight as a hook.")
            return
        }
        guard let endSeconds = row.endSeconds, endSeconds > row.seconds else {
            bannerMessage = L("This highlight is missing an end time and can't be used as a hook.")
            return
        }
        guard let record = records.first(where: { $0.id == row.sourceVideoID }),
              record.kind == .video else {
            bannerMessage = L("Source clip for this highlight is no longer in the project.")
            return
        }

        let sourceName = record.sourcePath.components(separatedBy: "/").last
        let duration = endSeconds - row.seconds
        let trimmedLabel = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation: String = {
            if trimmedLabel.isEmpty {
                return String(
                    format: "Add opening hook teaser (%.1fs%@)",
                    duration,
                    sourceName.map { " from \($0)" } ?? ""
                )
            }
            return String(format: "Add opening hook: %@ (%.1fs)", trimmedLabel, duration)
        }()
        let inputs = AgentHook.HookTeaserInputs(
            sourceVideoID: row.sourceVideoID,
            sourceName: sourceName,
            sourceStart: row.seconds,
            sourceEnd: endSeconds,
            audioTailSeconds: 0.4,
            fadeInSeconds: 0.15,
            explanation: explanation
        )

        let toolCallID = "ui-use-as-hook-\(UUID().uuidString)"
        switch proposeHookFromInputs(inputs, toolCallID: toolCallID) {
        case .failure(.validation(let bullets)):
            let joined = bullets.prefix(3).map { "• \($0)" }.joined(separator: "\n")
            bannerMessage = L("Pre-flight rejected:\n%@", joined)
        case .success(let result):
            // Anchor a chat bubble to the proposal so the existing
            // ProposedBatchCard render path lights up — same as the
            // agent loop does for LLM-driven hook proposals. We mirror
            // the agent loop's `extractLeadingIcon` step so this bubble
            // looks identical to one produced by `add_hook_teaser`.
            let (cleanContent, icon, tone) = Self.extractLeadingIcon(from: result.bubbleSummary)
            let bubble = EditorChatMessage(
                role: .assistant,
                content: cleanContent,
                proposedBatchID: result.proposal.id,
                iconSystemName: icon,
                iconTone: tone
            )
            chatMessages.append(bubble)
            Task { try? await chatStore?.append(bubble) }
            bannerMessage = L("Pending opening hook — review and Apply in chat.")
        }
    }

    /// Outcome carrier for `proposeHookFromInputs`. Bundles the
    /// ProposedBatch (already inserted into `pendingProposals`) plus a
    /// pre-built emoji-prefixed user-facing summary so the dispatcher
    /// callsite can return it directly and the UI callsite can pass it
    /// through `extractLeadingIcon`.
    struct HookProposalSuccess {
        let proposal: ProposedBatch
        let bubbleSummary: String
    }

    /// Failure carrier for `proposeHookFromInputs`. Right now the only
    /// rejection that can happen here is `AIActionValidator` reporting
    /// errors against the proposed batch — input parsing and
    /// scope/record gates are the caller's responsibility.
    enum HookProposalError: Error, Equatable {
        case validation([String])
    }

    /// Shared validate → dry-run → ProposedBatch.make → insert pipeline
    /// used by both the LLM-driven `add_hook_teaser` dispatcher and the
    /// UI-driven `useHighlightAsHook` entry point. Inserts the proposal
    /// at the head of `pendingProposals` on success.
    private func proposeHookFromInputs(
        _ inputs: AgentHook.HookTeaserInputs,
        toolCallID: String
    ) -> Swift.Result<HookProposalSuccess, HookProposalError> {
        let batch = AgentHook.buildHookBatch(inputs)
        let validation = AIActionValidator.validate(
            batch: batch,
            segments: timelineSegments,
            knownSourceVideoIDs: Set(records.map(\.id))
        )
        if validation.hasErrors {
            return .failure(.validation(validation.errors.prefix(5).map(\.message)))
        }
        let dryRun = AIActionExecutor.apply(
            batch: batch,
            to: timelineSegments,
            baseSubtitleStyle: subtitleStyle,
            transcriptLookup: { ranges, sourceID in
                self.subtitleEntries(for: ranges, sourceVideoID: sourceID)
            }
        )
        let proposal = ProposedBatch.make(
            toolCallID: toolCallID,
            batch: batch,
            before: timelineSegments,
            dryRun: dryRun
        )
        pendingProposals.insert(proposal, at: 0)
        let duration = inputs.sourceEnd - inputs.sourceStart
        let bubbleSummary = String(
            format: "🎯 Pending opening hook — %.1fs%@",
            duration,
            inputs.sourceName.map { " from \($0)" } ?? ""
        )
        return .success(HookProposalSuccess(
            proposal: proposal,
            bubbleSummary: bubbleSummary
        ))
    }

    /// Append a new overlay segment carrying `mediaID` to the existing
    /// overlay track identified by `trackID`, anchored at
    /// `composedStart` seconds. Invoked by the drop-on-lane path so
    /// dragging media onto V2/V3 goes into that lane instead of
    /// creating a brand-new one. Falls back to `insertBRollOverlay`
    /// (which creates a new lane) if `trackID` no longer exists.
    func insertMediaIntoOverlayTrack(mediaID: UUID, trackID: UUID, composedStart: Double) {
        guard let record = records.first(where: { $0.id == mediaID }) else {
            bannerMessage = L("B-roll source not found.")
            return
        }
        guard let tIdx = project.tracks.firstIndex(where: {
            $0.id == trackID && $0.kind == .overlay
        }) else {
            // Target lane was removed between hover and drop; fall
            // back to the new-track behavior so the drop still lands.
            insertBRollOverlay(mediaID: mediaID, at: composedStart, duration: .greatestFiniteMagnitude)
            return
        }

        let duration: Double
        if record.kind == .image {
            duration = 4.0
        } else {
            guard let analysis = record.analysis, analysis.durationSeconds > 0.1 else {
                bannerMessage = L("Can't add clip — analysis not ready.")
                return
            }
            duration = analysis.durationSeconds
        }
        let segment = TimelineSegment(
            id: UUID(),
            sourceVideoID: mediaID,
            range: TimeRange(startSeconds: 0, endSeconds: duration),
            text: "",
            subtitles: [],
            volumeLevel: 1.0,
            placementOffset: max(0, composedStart)
        )
        pushRevision(
            label: "Insert into overlay at \(String(format: "%.1fs", composedStart))",
            trigger: .userEdit(description: "insert-into-overlay")
        )
        var next = project
        next.tracks[tIdx].segments.append(segment)
        project = next
        rebuildComposition()
    }

    /// Set volume for a segment (0.0 = mute, 1.0 = full).
    func setSegmentVolume(at index: Int, volume: Double) {
        guard index >= 0, index < timelineSegments.count else { return }
        guard !isPrimaryTrackLocked() else { return }
        let clamped = max(0, min(1, volume))
        guard timelineSegments[index].volumeLevel != clamped else { return }
        pushRevision(label: "Change volume", trigger: .userEdit(description: "volume"))
        timelineSegments[index].volumeLevel = clamped
        rebuildComposition()
    }

    // MARK: - Manual creative actions (TimelineDock UI entry points)

    /// Default crossfade length used by the "Add Crossfade" context-menu
    /// items. Kept modest so it doesn't silently eat content; the user
    /// can extend via the audio-fade fields afterwards.
    static let manualCrossfadeDefaultSeconds: Double = 0.5

    /// Insert a crossfade between `timelineSegments[fromIndex]` and the
    /// segment immediately after it. No-op when the pair isn't valid.
    /// Pushes a `.userEdit` revision so Cmd+Z works.
    func addCrossfade(fromIndex: Int, duration: Double = MediaCoreViewModel.manualCrossfadeDefaultSeconds) {
        guard fromIndex >= 0, fromIndex + 1 < timelineSegments.count else { return }
        let from = timelineSegments[fromIndex]
        let to = timelineSegments[fromIndex + 1]
        let action = CreativeAction.insertCrossfade(
            fromSegmentID: from.id,
            toSegmentID: to.id,
            duration: duration
        )
        guard let plan = CreativeActionMapper.plan(crossfade: action, in: timelineSegments) else { return }
        pushRevision(
            label: "Crossfade (\(String(format: "%.2fs", plan.duration)))",
            trigger: .userEdit(description: "crossfade")
        )
        timelineSegments = CreativeActionMapper.apply(crossfade: plan, to: timelineSegments)
        rebuildComposition()
    }

    /// Insert a B-roll overlay track carrying `mediaID` at `composedTime`
    /// for `duration` seconds. Mirrors the Agent `insert_broll` tool path
    /// but goes through the user-edit revision trigger.
    func insertBRollOverlay(mediaID: UUID, at composedTime: Double, duration: Double) {
        guard let record = records.first(where: { $0.id == mediaID }) else {
            bannerMessage = L("B-roll source not found.")
            return
        }

        // Image overlays: use the industry-standard still-image default
        // (4 seconds, matching Final Cut Pro). They have no source
        // duration to clamp against, so we bypass
        // CreativeActionExecutor.insertBRoll entirely.
        if record.kind == .image {
            let imageDefaultDuration = 4.0
            let effective = duration == .greatestFiniteMagnitude ? imageDefaultDuration : max(0.05, duration)
            insertImageOverlay(
                mediaID: mediaID,
                at: composedTime,
                duration: effective
            )
            return
        }

        let action = CreativeAction.insertBRoll(
            composedTime: composedTime,
            mediaID: mediaID,
            duration: duration,
            muteOriginal: false
        )
        // Provide real source durations so callers can pass a sentinel
        // like `.greatestFiniteMagnitude` to mean "use the whole clip".
        // Without this the overlay segment was always created at the
        // caller's requested duration (e.g. 3s from the drop handler),
        // which made long clips render as a tiny pill at the timeline
        // origin instead of spanning their actual length.
        let durations: [UUID: Double] = Dictionary(
            uniqueKeysWithValues: records.compactMap { r in
                r.analysis.map { (r.id, $0.durationSeconds) }
            }
        )
        let nextProject: Project
        do {
            nextProject = try CreativeActionExecutor.apply(action, to: project, mediaDuration: { durations[$0] })
        } catch {
            bannerMessage = L("Couldn't insert B-roll: %@", error.localizedDescription)
            return
        }
        pushRevision(
            label: "Insert B-roll at \(String(format: "%.1fs", composedTime))",
            trigger: .userEdit(description: "insert-broll")
        )
        project = nextProject
        rebuildComposition()
    }

    /// Append a fresh overlay track with a single image segment.
    /// Images don't go through `CreativeActionExecutor.insertBRoll`
    /// because that path clamps duration to the source media's
    /// duration — a still image has no natural duration, so the
    /// executor would reject it. Instead we construct the segment
    /// directly; the user can resize it from the timeline later.
    private func insertImageOverlay(
        mediaID: UUID,
        at composedTime: Double,
        duration: Double
    ) {
        let imageSegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: mediaID,
            range: TimeRange(startSeconds: 0, endSeconds: duration),
            text: "",
            subtitles: [],
            volumeLevel: 1.0,
            placementOffset: max(0, composedTime)
        )
        pushRevision(
            label: "Insert image at \(String(format: "%.1fs", composedTime))",
            trigger: .userEdit(description: "insert-image")
        )
        var next = project
        let overlayCount = next.tracks.filter { $0.kind == .overlay }.count
        let track = Track(
            kind: .overlay,
            name: "V\(overlayCount + 2) (Image)",
            segments: [imageSegment]
        )
        next.tracks.append(track)
        project = next
        rebuildComposition()
    }

    /// Remove an overlay segment identified by its UUID. If the
    /// owning overlay track becomes empty as a result, the track
    /// itself is removed so the timeline doesn't keep an empty
    /// V{n} lane lying around. Goes through the user-edit revision
    /// path so the deletion is a single undo step.
    func removeOverlaySegment(segmentID: UUID) {
        guard !isSegmentLocked(segmentID),
              let (tIdx, sIdx) = findOverlaySegmentLocation(segmentID: segmentID) else {
            return
        }
        pushRevision(
            label: "Delete overlay",
            trigger: .userEdit(description: "remove-overlay")
        )
        var next = project
        next.tracks[tIdx].segments.remove(at: sIdx)
        if next.tracks[tIdx].segments.isEmpty {
            next.tracks.remove(at: tIdx)
        }
        project = next
        if selectedOverlaySegmentID == segmentID {
            selectedOverlaySegmentID = nil
        }
        rebuildComposition()
    }

    // MARK: - Free-transform editing

    /// Describes the currently-selected overlay segment suitable for
    /// free-transform editing in the viewer. Nil when no overlay is
    /// selected, the selection can't be resolved, or its source has
    /// no known dimensions (in which case we can't draw aspect-
    /// correct handles).
    struct FreeTransformTarget: Equatable {
        let segmentID: UUID
        let freeTransform: FreeTransform
        let sourceAspect: CGFloat
    }

    /// Currently-editable free-transform target for the viewer overlay
    /// handles. Exposes the segment ID, its live (or identity-default)
    /// `FreeTransform`, and the source's aspect ratio so the view can
    /// draw correctly-shaped handles regardless of layer size.
    var freeTransformTarget: FreeTransformTarget? {
        guard let segID = selectedOverlaySegmentID,
              let segment = project.overlayTracks.flatMap(\.segments).first(where: { $0.id == segID }),
              let record = records.first(where: { $0.id == segment.sourceVideoID })
        else { return nil }

        // Source dimensions: for images, use the stored analysis
        // width/height; for video, the analysis also carries it.
        guard let width = record.analysis?.width,
              let height = record.analysis?.height,
              width > 0, height > 0 else { return nil }
        let aspect = CGFloat(width) / CGFloat(height)

        return FreeTransformTarget(
            segmentID: segID,
            freeTransform: segment.freeTransform ?? .identity,
            sourceAspect: aspect
        )
    }

    /// Apply an in-progress or committed free-transform update to the
    /// identified overlay segment. While the user is dragging, callers
    /// pass `commit: false` to avoid pushing a revision per frame;
    /// on gesture end they call once with `commit: true` so a single
    /// undo step captures the whole manipulation.
    func updateFreeTransform(segmentID: UUID, transform: FreeTransform, commit: Bool) {
        guard !isSegmentLocked(segmentID) else { return }
        guard let (tIdx, sIdx) = findOverlaySegmentLocation(segmentID: segmentID) else { return }
        var next = project
        next.tracks[tIdx].segments[sIdx].freeTransform = transform
        if commit {
            pushRevision(
                label: "Transform overlay",
                trigger: .userEdit(description: "free-transform")
            )
        }
        project = next
        rebuildComposition()
    }

    ///      media for playback, thumbnails, and export.
    ///   3. `insertBRollOverlay` — places the new `MediaAssetRecord` on
    ///      the overlay track, clamped to the source's real duration.
    ///
    /// Any of those being absent → banner + early-return; we never
    /// leave the project in a half-mutated state.
    ///
    /// Render an overlay graphic via Remotion and drop it onto a fresh
    /// overlay track at `composedTime`. The rendered `.mov` is cached
    /// in `media/overlays/<cacheKey>.mov` by content hash so repeated
    /// calls with identical spec+duration reuse the same file, and the
    /// resulting `TimelineSegment` carries the full `OverlayRenderSpec`
    /// so the user (or the agent) can later edit the props via
    /// `updateOverlayProps(...)` and get a re-render.
    func generateOverlay(
        templateID: String,
        propsJSON: String,
        durationSeconds: Double,
        at composedTime: Double
    ) async -> Error? {
        let provider = CuttiSettings.aiProvider()
        print("🎬 [overlay] generateOverlay start template=\(templateID) duration=\(durationSeconds)s composedTime=\(composedTime)s aiProvider=\(provider)")
        // Belt-and-suspenders BYOK gate. `makeOverlayCache()` already
        // catches this, but failing fast at the entry point avoids any
        // chance of partial work (banner flashing twice, half-built
        // OverlayRenderSpec, etc.) and keeps every animation entry
        // point obviously gated when grepping for "BYOK".
        if provider == .custom {
            print("🎬 [overlay] BYOK gate hit (aiProvider == .custom) — bailing BEFORE touching renderer")
            bannerMessage = L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud.")
            return NSError(domain: "Cutti.Overlay", code: -2, userInfo: [NSLocalizedDescriptionKey: "Animation rendering is unavailable in BYOK mode."])
        }
        guard let cache = makeOverlayCache() else {
            print("🎬 [overlay] makeOverlayCache returned nil — bailing (no HTTP will fire)")
            return NSError(domain: "Cutti.Overlay", code: -1, userInfo: [NSLocalizedDescriptionKey: "Overlay cache unavailable."])
        }

        // Match the overlay render resolution to the project's primary
        // video so a portrait 1080×1920 phone clip gets a portrait
        // overlay (not the 1920×1080 default, which the AVComposition
        // then letter-pillarboxes into the portrait canvas and the user
        // sees the animation cropped / floating in a weird box).
        let (overlayW, overlayH) = primaryRenderDimensions()

        let spec = OverlayRenderSpec(
            templateID: templateID,
            propsJSON: propsJSON,
            durationSeconds: durationSeconds,
            width: overlayW,
            height: overlayH
        )

        bannerMessage = nil
        let mediaID: UUID
        do {
            mediaID = try await cache.resolveMediaID(for: spec)
            print("🎬 [overlay] resolveMediaID succeeded mediaID=\(mediaID) cacheKey=\(spec.cacheKey)")
        } catch {
            print("🎬 [overlay] resolveMediaID THREW: \(error)")
            return error
        }

        // Refresh `records` so `insertOverlaySegment` below can see the
        // freshly-imported asset on first-ever generation of this spec.
        await loadRecords()

        insertOverlaySegment(
            spec: spec,
            mediaID: mediaID,
            at: composedTime
        )
        bannerMessage = nil
        print("🎬 [overlay] generateOverlay done template=\(templateID) composedTime=\(composedTime)s")
        return nil
    }

    /// Inspector / agent entry-point for re-editing a previously
    /// AI-generated overlay. Merges `propsPatch` into the segment's
    /// existing `overlaySpec.propsJSON`, re-renders through the cache,
    /// and swaps the segment's `sourceVideoID` to the new asset. The
    /// segment's id is preserved so selection, placement, and Cmd+Z
    /// history all remain intact.
    func updateOverlayProps(
        segmentID: UUID,
        propsPatch: [String: Any]
    ) async {
        // Belt-and-suspenders BYOK gate (see generateOverlay).
        if CuttiSettings.aiProvider() == .custom {
            bannerMessage = L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud.")
            return
        }
        guard let cache = makeOverlayCache() else { return }
        guard let (trackIdx, segIdx) = findOverlaySegmentLocation(segmentID: segmentID),
              let currentSpec = project.tracks[trackIdx].segments[segIdx].overlaySpec else {
            bannerMessage = L("Animation segment not found or not AI-generated.")
            return
        }

        let mergedPropsJSON = mergeJSON(base: currentSpec.propsJSON, patch: propsPatch)
        let newSpec = OverlayRenderSpec(
            templateID: currentSpec.templateID,
            propsJSON: mergedPropsJSON,
            durationSeconds: currentSpec.durationSeconds,
            fps: currentSpec.fps,
            width: currentSpec.width,
            height: currentSpec.height
        )
        if newSpec.cacheKey == currentSpec.cacheKey { return }

        overlaysRendering.insert(segmentID)
        defer { overlaysRendering.remove(segmentID) }

        let mediaID: UUID
        do {
            mediaID = try await cache.resolveMediaID(for: newSpec)
        } catch {
            return
        }
        await loadRecords()

        pushRevision(
            label: "Edit overlay props",
            trigger: .userEdit(description: "update-overlay-props")
        )
        var next = project
        // Re-resolve indices after pushRevision (project identity stable
        // but defensive in case future hooks reorder tracks).
        if let (tIdx, sIdx) = findOverlaySegmentLocation(in: next, segmentID: segmentID) {
            let old = next.tracks[tIdx].segments[sIdx]
            var replacement = TimelineSegment(
                id: old.id,
                sourceVideoID: mediaID,
                range: old.range,
                text: old.text,
                subtitles: old.subtitles,
                volumeLevel: old.volumeLevel,
                placementOffset: old.placementOffset
            )
            replacement.isVideoHidden = old.isVideoHidden
            replacement.speedRate = old.speedRate
            replacement.effects = old.effects
            replacement.alternatives = old.alternatives
            replacement.linkedSegmentID = old.linkedSegmentID
            replacement.pipLayout = old.pipLayout
            replacement.overlaySpec = newSpec
            next.tracks[tIdx].segments[sIdx] = replacement
            project = next
            rebuildComposition()
        }
        bannerMessage = nil
    }

    /// Inspector convenience — return the `OverlayRenderSpec` for an
    /// overlay segment, or nil if the segment either doesn't exist or
    /// wasn't AI-generated.
    func overlaySpec(forSegmentID segmentID: UUID) -> OverlayRenderSpec? {
        guard let (tIdx, sIdx) = findOverlaySegmentLocation(segmentID: segmentID) else {
            return nil
        }
        return project.tracks[tIdx].segments[sIdx].overlaySpec
    }

    /// Resolve the overlay render resolution from the project's primary
    /// media. Walks the current timeline segments first (which reflects
    /// what's actually on-screen), then falls back to any
    /// `MediaAssetRecord` the project knows about. Clamps to even pixels
    /// because H.264/ProRes encoders require even dimensions.
    ///
    /// Returns the spec default (1920×1080) only when the project has
    /// no media at all, which in practice means the agent is running
    /// against an empty project and the overlay will be visible to
    /// whatever gets imported later — a 16:9 guess is as good as any.
    private func primaryRenderDimensions() -> (Int, Int) {
        let primarySourceID = timelineSegments.first?.sourceVideoID
            ?? project.tracks.first?.segments.first?.sourceVideoID
        if let id = primarySourceID,
           let rec = records.first(where: { $0.id == id }),
           let a = rec.analysis,
           a.width > 0, a.height > 0 {
            let w = max(16, a.width - (a.width & 1))
            let h = max(16, a.height - (a.height & 1))
            return (w, h)
        }
        return (1920, 1080)
    }

    /// Debounced entry point used by the Inspector panel: coalesces
    /// rapid prop changes (e.g. typing in the title field) into a
    /// single re-render. Subsequent calls for the same segment cancel
    /// the previously-scheduled task; after `debounce` of quiet time
    /// the patch is applied via `updateOverlayProps`.
    func scheduleOverlayPropsPatch(
        segmentID: UUID,
        patch: [String: Any],
        debounceMilliseconds: UInt64 = 500
    ) {
        overlayPropsDebounceTasks[segmentID]?.cancel()
        overlayPropsDebounceTasks[segmentID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounceMilliseconds * 1_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            await self.updateOverlayProps(segmentID: segmentID, propsPatch: patch)
            await MainActor.run { self.overlayPropsDebounceTasks[segmentID] = nil }
        }
    }

    /// Flush any pending debounced patch for `segmentID` immediately.
    /// Called from the Inspector's close button so the user never
    /// loses their last keystroke when dismissing the panel.
    func flushPendingOverlayPropsPatch(segmentID: UUID) async {
        guard let task = overlayPropsDebounceTasks[segmentID] else { return }
        // Cancelling the sleep lets the task exit its sleep early; the
        // `if Task.isCancelled { return }` guard then skips the render.
        // We want the opposite here (commit immediately), so just wait
        // for whatever is in flight rather than cancel.
        _ = await task.value
    }

    /// Clear the Inspector target. Called from the close button and
    /// automatically whenever the referenced segment disappears
    /// (delete, undo, etc.).
    func closeOverlayInspector() {
        inspectorOverlaySegmentID = nil
    }

    /// Lazily builds the `OverlayRenderCache`. Returns nil + sets a
    /// banner if any collaborator is missing so callers can simply
    /// `guard let cache = makeOverlayCache() else { return }`.
    private func makeOverlayCache() -> OverlayRenderCache? {
        // BYOK users opted out of the Cutti subscription stack,
        // including the cloud Remotion renderer (the local renderer
        // is dev-only — see `LocalRemotionRenderer.defaultProjectDirectory`).
        // We MUST gate here, not just at factory time:
        //   - a stale `overlayRenderer` may have been wired at VM
        //     construction when the user was still on `.cuttiCloud`;
        //   - `_overlayRenderCache` may already be memoized from a
        //     previous Generate Animation in that same session.
        // Both would otherwise let BYOK keep hitting `api.cutti.app`
        // after the user switched providers in Settings. Reusing the
        // existing AI-provider Settings copy keeps the warning
        // consistent across the UI.
        if CuttiSettings.aiProvider() == .custom {
            print("🎬 [overlay] makeOverlayCache: BYOK mode (aiProvider=.custom) — returning nil + clearing memoized cache")
            _overlayRenderCache = nil
            bannerMessage = L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud.")
            return nil
        }
        // The renderer was wired at VM-construction time. If the user
        // signed in mid-session, the original wiring may have been a
        // `LocalRemotionRenderer` (token-less fallback). Re-resolve so
        // a freshly-issued JWT promotes us to `CloudRemotionRenderer`
        // without forcing the user to fully restart the app. The reverse
        // flow (cloud → local) doesn't need handling because losing a
        // token doesn't happen mid-session under normal use.
        if !(overlayRenderer is CloudRemotionRenderer) {
            let upgraded = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer()
            if upgraded is CloudRemotionRenderer {
                print("🎬 [overlay] makeOverlayCache: upgrading renderer \(overlayRenderer.map { String(describing: type(of: $0)) } ?? "nil") → CloudRemotionRenderer (token now present)")
                overlayRenderer = upgraded
                _overlayRenderCache = nil
            }
        }
        if let existing = _overlayRenderCache {
            print("🎬 [overlay] makeOverlayCache: returning memoized cache")
            return existing
        }
        guard let overlayRenderer else {
            print("🎬 [overlay] makeOverlayCache: overlayRenderer is nil → \"Animation generation is not configured.\"")
            bannerMessage = L("Animation generation is not configured.")
            return nil
        }
        guard let mediaCore else {
            print("🎬 [overlay] makeOverlayCache: mediaCore is nil")
            bannerMessage = L("MediaCore is not configured.")
            return nil
        }
        guard let projectRoot else {
            print("🎬 [overlay] makeOverlayCache: projectRoot is nil")
            bannerMessage = L("Project root is not configured.")
            return nil
        }
        print("🎬 [overlay] makeOverlayCache: built fresh cache (renderer=\(type(of: overlayRenderer)) projectRoot=\(projectRoot.path))")
        let cache = OverlayRenderCache(
            renderer: overlayRenderer,
            projectRoot: projectRoot,
            mediaCore: mediaCore
        )
        _overlayRenderCache = cache
        return cache
    }

    /// Append a fresh overlay track carrying a single segment with
    /// `overlaySpec` attached. Mirrors `CreativeActionExecutor.insertBRoll`
    /// but writes the spec onto the segment so the result is
    /// Inspector-editable.
    private func insertOverlaySegment(
        spec: OverlayRenderSpec,
        mediaID: UUID,
        at composedTime: Double
    ) {
        guard records.contains(where: { $0.id == mediaID }) else {
            print("🎬 [overlay] insertOverlaySegment: mediaID=\(mediaID) NOT in records (\(records.count) records loaded) — bailing with 'media not found'. Likely a stale cache entry.")
            bannerMessage = L("Animation media not found after import.")
            return
        }
        print("🎬 [overlay] insertOverlaySegment: appending V\(project.tracks.filter { $0.kind == .overlay }.count + 2) overlay track @ composedTime=\(composedTime)s mediaID=\(mediaID)")
        let duration = spec.durationSeconds
        let segment = TimelineSegment(
            id: UUID(),
            sourceVideoID: mediaID,
            range: TimeRange(startSeconds: 0, endSeconds: duration),
            text: "",
            subtitles: [],
            volumeLevel: 1.0,
            placementOffset: max(0, composedTime)
        )
        var withSpec = segment
        withSpec.overlaySpec = spec

        pushRevision(
            label: "Generate overlay at \(String(format: "%.1fs", composedTime))",
            trigger: .userEdit(description: "generate-overlay")
        )
        var next = project
        let overlayCount = next.tracks.filter { $0.kind == .overlay }.count
        let track = Track(
            kind: .overlay,
            name: "V\(overlayCount + 2) (Overlay)",
            segments: [withSpec]
        )
        next.tracks.append(track)
        project = next
        rebuildComposition()
    }

    private func findOverlaySegmentLocation(segmentID: UUID) -> (Int, Int)? {
        findOverlaySegmentLocation(in: project, segmentID: segmentID)
    }

    private func findOverlaySegmentLocation(in project: Project, segmentID: UUID) -> (Int, Int)? {
        for (tIdx, track) in project.tracks.enumerated() where track.kind == .overlay {
            if let sIdx = track.segments.firstIndex(where: { $0.id == segmentID }) {
                return (tIdx, sIdx)
            }
        }
        return nil
    }

    /// Merge `patch` onto the object parsed from `baseJSON` (last-write-
    /// wins on matching keys). Always returns canonical JSON so the
    /// cache key is stable.
    private func mergeJSON(base baseJSON: String, patch: [String: Any]) -> String {
        var merged: [String: Any] = [:]
        if let baseData = baseJSON.data(using: .utf8),
           let baseObj = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] {
            merged = baseObj
        }
        for (k, v) in patch { merged[k] = v }
        guard let data = try? JSONSerialization.data(
            withJSONObject: merged,
            options: [.sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else {
            return baseJSON
        }
        return str
    }

    /// Set the composed-time starting position (`placementOffset`) of a
    /// single segment on an overlay track. Used by the TimelineDock's
    /// interactive overlay-pill drag / numeric start-time popover. No-op
    /// when the ID doesn't resolve to an overlay segment. Pushes a
    /// user-edit revision so Cmd+Z works, and rebuilds the composition
    /// so the preview reflects the new timing.
    func setOverlayPlacementOffset(segmentID: UUID, composedStart: Double) {
        guard !isSegmentLocked(segmentID) else { return }
        let clamped = max(0, composedStart)
        var mutated = project
        var hit = false
        for trackIdx in mutated.tracks.indices where mutated.tracks[trackIdx].kind == .overlay {
            if let segIdx = mutated.tracks[trackIdx].segments.firstIndex(where: { $0.id == segmentID }) {
                let current = mutated.tracks[trackIdx].segments[segIdx].placementOffset ?? 0
                if abs(current - clamped) < 0.001 { return }
                mutated.tracks[trackIdx].segments[segIdx].placementOffset = clamped
                hit = true
                break
            }
        }
        guard hit else { return }
        pushRevision(
            label: "Move overlay to \(String(format: "%.2fs", clamped))",
            trigger: .userEdit(description: "move-overlay")
        )
        project = mutated
        rebuildComposition()
    }

    /// Which timeline edge of an overlay pill is being trimmed. Leading
    /// shifts the start (pinning the right edge); trailing shifts the
    /// end (pinning the left edge). Matches `HorizontalEdge` semantics
    /// in TimelineDock but is redeclared here so the ViewModel has no
    /// dependency on the SwiftUI view layer.
    enum OverlayTrimEdge {
        case leading, trailing
    }

    /// Resize an overlay segment by dragging one of its pill edges.
    /// `composedEdgeTime` is the absolute target for the moving edge on
    /// the composed timeline. The non-moving edge stays pinned. Image
    /// overlays may grow/shrink freely (capped at 10 min) because the
    /// image layer has no source-duration constraint; video / audio
    /// overlays clamp to the source asset's length so we never request
    /// frames past the end of the file.
    ///
    /// Writes one revision per call so any drag that streams multiple
    /// updates should only invoke this on release (the UI tracks live
    /// state locally). Callers pass the already-snapped / clamped value
    /// for the moving edge; we still clamp here for safety (source
    /// duration, min duration, placement ≥ 0).
    func trimOverlaySegment(
        segmentID: UUID,
        edge: OverlayTrimEdge,
        composedEdgeTime: Double
    ) {
        guard !isSegmentLocked(segmentID) else { return }
        guard let (tIdx, sIdx) = findOverlaySegmentLocation(segmentID: segmentID) else { return }
        var seg = project.tracks[tIdx].segments[sIdx]
        let minDuration = 0.1
        let imageMaxDuration = 600.0

        let speed = seg.normalizedSpeedRate
        let currentStart = seg.placementOffset ?? 0
        let currentDuration = seg.durationSeconds
        let currentEnd = currentStart + currentDuration
        let currentRangeStart = seg.range.startSeconds
        let currentRangeEnd = seg.range.endSeconds

        let record = records.first(where: { $0.id == seg.sourceVideoID })
        let isImage = (record?.kind == .image)
        let sourceDuration = record?.analysis?.durationSeconds ?? 0

        var newRangeStart = currentRangeStart
        var newRangeEnd = currentRangeEnd
        var newPlacement = currentStart

        switch edge {
        case .trailing:
            let requestedDuration = max(minDuration, composedEdgeTime - currentStart)
            let requestedSourceSpan = requestedDuration * speed
            let sourceSpan: Double
            if isImage {
                sourceSpan = min(requestedSourceSpan, imageMaxDuration * speed)
            } else {
                let maxSpan = max(minDuration * speed, sourceDuration - currentRangeStart)
                sourceSpan = min(requestedSourceSpan, maxSpan)
            }
            newRangeEnd = currentRangeStart + max(minDuration * speed, sourceSpan)

        case .leading:
            let clampedEdge = min(max(0, composedEdgeTime), currentEnd - minDuration)
            let requestedDuration = currentEnd - clampedEdge
            let requestedSourceSpan = requestedDuration * speed
            if isImage {
                // Image: the "source range" is synthetic, so we
                // normalize to [0, durationInSource] and shift the
                // placementOffset so the right edge stays pinned.
                let sourceSpan = min(max(minDuration * speed, requestedSourceSpan), imageMaxDuration * speed)
                newRangeStart = 0
                newRangeEnd = sourceSpan
                newPlacement = max(0, currentEnd - (sourceSpan / speed))
            } else {
                // Video/audio: growing the left edge pulls range.start
                // earlier (toward 0); shrinking pushes it later.
                let currentSourceSpan = currentRangeEnd - currentRangeStart
                let delta = requestedSourceSpan - currentSourceSpan
                var candidateStart = currentRangeStart - delta
                if candidateStart < 0 {
                    candidateStart = 0
                }
                if candidateStart > currentRangeEnd - minDuration * speed {
                    candidateStart = currentRangeEnd - minDuration * speed
                }
                newRangeStart = candidateStart
                newRangeEnd = currentRangeEnd
                let actualDuration = (newRangeEnd - newRangeStart) / speed
                newPlacement = max(0, currentEnd - actualDuration)
            }
        }

        // Skip no-ops so we don't spam undo with identical revisions.
        if abs(newRangeStart - currentRangeStart) < 0.001 &&
           abs(newRangeEnd - currentRangeEnd) < 0.001 &&
           abs(newPlacement - currentStart) < 0.001 {
            return
        }

        var mutated = project
        seg.range = TimeRange(startSeconds: newRangeStart, endSeconds: newRangeEnd)
        seg.placementOffset = newPlacement
        mutated.tracks[tIdx].segments[sIdx] = seg

        let newDurationLabel = seg.durationSeconds
        pushRevision(
            label: "Trim overlay to \(String(format: "%.2fs", newDurationLabel))",
            trigger: .userEdit(description: "trim-overlay")
        )
        project = mutated
        rebuildComposition()
    }

    /// Atomic writer used by the viewer's interactive PiP handle when
    /// the user drops the rect after a drag. Updates `corner` +
    /// `insetFraction` + `sizeFraction` in one revision so undo
    /// restores the pre-drag position in a single step. Other layout
    /// fields (shape, border, shadow) are preserved from the existing
    /// layout or seeded from `.default`.
    func setPiPGeometry(
        segmentID: UUID,
        corner: PiPLayout.Corner,
        insetFraction: Double,
        sizeFraction: Double
    ) {
        guard !isSegmentLocked(segmentID) else { return }
        var mutated = project
        var hit = false
        for trackIdx in mutated.tracks.indices where mutated.tracks[trackIdx].kind == .overlay {
            if let segIdx = mutated.tracks[trackIdx].segments.firstIndex(where: { $0.id == segmentID }) {
                let base = mutated.tracks[trackIdx].segments[segIdx].pipLayout ?? .default
                var next = base
                next.corner = corner
                next.insetFraction = insetFraction
                next.sizeFraction = sizeFraction
                let normalized = next.normalized()
                if base == normalized { return }
                mutated.tracks[trackIdx].segments[segIdx].pipLayout = normalized
                hit = true
                break
            }
        }
        guard hit else { return }
        pushRevision(
            label: "Reposition Picture-in-Picture",
            trigger: .userEdit(description: "set-pip-geometry")
        )
        project = mutated
        rebuildComposition()
    }

    /// Overlay segments that are currently visible at `composedTime`
    /// and carry a `pipLayout`. Used by the viewer to render
    /// interactive drag handles aligned with the baked PiP pixels.
    /// Returns `(segmentID, layout)` so the caller can route click
    /// selection + layout edits back through the VM without having
    /// to scan the project tree itself.
    func activePiPOverlays(atComposedTime composedTime: Double) -> [(segmentID: UUID, layout: PiPLayout)] {
        var out: [(UUID, PiPLayout)] = []
        for track in project.overlayTracks {
            for seg in track.segments {
                guard let layout = seg.pipLayout else { continue }
                let start = seg.placementOffset ?? 0
                let end = start + seg.durationSeconds
                if composedTime >= start && composedTime < end {
                    out.append((seg.id, layout))
                }
            }
        }
        return out
    }

    /// Snap a canvas-space rect origin to the nearest of the 4
    /// corners. Returns the chosen corner plus the `insetFraction`
    /// (distance-from-corner / canvas height), clamped into
    /// `[0, PiPLayout.maxInsetFraction]`.
    ///
    /// Pure function so the viewer can preview the snap target
    /// while the user is still dragging — separate from the writer
    /// so tests don't need a full VM instance.
    static func snapPiPToNearestCorner(
        rectOrigin: CGPoint,
        rectSize: CGSize,
        canvasSize: CGSize
    ) -> (corner: PiPLayout.Corner, insetFraction: Double) {
        let cw = max(1, canvasSize.width)
        let ch = max(1, canvasSize.height)
        // Distances from the rect's anchor corner to each canvas corner.
        let distTopLeft = hypot(rectOrigin.x, rectOrigin.y)
        let distTopRight = hypot(cw - (rectOrigin.x + rectSize.width), rectOrigin.y)
        let distBottomLeft = hypot(rectOrigin.x, ch - (rectOrigin.y + rectSize.height))
        let distBottomRight = hypot(cw - (rectOrigin.x + rectSize.width), ch - (rectOrigin.y + rectSize.height))
        // Pick the corner with the minimum Chebyshev-ish distance.
        let options: [(PiPLayout.Corner, CGFloat, CGFloat, CGFloat)] = [
            (.topLeft, distTopLeft, rectOrigin.x, rectOrigin.y),
            (.topRight, distTopRight, cw - (rectOrigin.x + rectSize.width), rectOrigin.y),
            (.bottomLeft, distBottomLeft, rectOrigin.x, ch - (rectOrigin.y + rectSize.height)),
            (.bottomRight, distBottomRight, cw - (rectOrigin.x + rectSize.width), ch - (rectOrigin.y + rectSize.height)),
        ]
        let best = options.min(by: { $0.1 < $1.1 }) ?? options[3]
        // Use the max of x/y insets (in canvas-height units) — the
        // smaller one would force the rect to slide back toward the
        // corner on the short axis, which feels wrong to the user
        // who just dragged the rect to a specific spot.
        let insetPx = max(best.2, best.3)
        let rawFraction = Double(insetPx / ch)
        let fraction = min(max(rawFraction, 0), PiPLayout.maxInsetFraction)
        return (best.0, fraction)
    }

    /// Set or clear the Picture-in-Picture layout on an overlay segment.
    /// Only meaningful for overlay-track segments (primary/V1 never
    /// renders as PiP). Nil clears the layout so the overlay returns to
    /// the legacy full-cover behavior.
    func setPiPLayout(segmentID: UUID, layout: PiPLayout?) {
        guard !isSegmentLocked(segmentID) else { return }
        var mutated = project
        var hit = false
        for trackIdx in mutated.tracks.indices where mutated.tracks[trackIdx].kind == .overlay {
            if let segIdx = mutated.tracks[trackIdx].segments.firstIndex(where: { $0.id == segmentID }) {
                let current = mutated.tracks[trackIdx].segments[segIdx].pipLayout
                if current == layout { return }
                mutated.tracks[trackIdx].segments[segIdx].pipLayout = layout?.normalized()
                hit = true
                break
            }
        }
        guard hit else { return }
        let label: String
        if let l = layout {
            label = "Picture-in-Picture \(l.corner.rawValue)"
        } else {
            label = "Disable Picture-in-Picture"
        }
        pushRevision(label: label, trigger: .userEdit(description: "set-pip-layout"))
        project = mutated
        rebuildComposition()
    }

    /// Status surfaced to the UI while `applyAutoPiP` runs so the menu
    /// can show a spinner / disable re-entry. Reset to `.idle` on
    /// completion (success or failure).
    enum AutoPiPStatus: Equatable {
        case idle
        case running(segmentID: UUID)
        case completed(segmentID: UUID, applied: Bool, message: String)
    }

    @Published var autoPiPStatus: AutoPiPStatus = .idle

    /// Run the Auto-PiP analyzer on an overlay segment: find the V1
    /// segment playing underneath it, sample frames, classify, and if
    /// the overlay qualifies as a presenter cam apply the suggested
    /// layout via `setPiPLayout`. Shows a banner message if the clip
    /// doesn't look like a presenter cam so the user understands why
    /// nothing happened.
    func applyAutoPiP(segmentID: UUID) {
        autoPiPStatus = .running(segmentID: segmentID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let decision = await self.analyzeOverlayForPiP(segmentID: segmentID) else {
                self.autoPiPStatus = .idle
                return
            }
            if let layout = decision.suggestedLayout {
                self.setPiPLayout(segmentID: segmentID, layout: layout)
                let msg = "Auto PiP: \(layout.shape.rawValue) @ \(layout.corner.rawValue) (conf \(String(format: "%.0f", decision.confidence * 100))%)"
                self.autoPiPStatus = .completed(segmentID: segmentID, applied: true, message: msg)
                self.bannerMessage = msg
            } else {
                let msg = "Auto PiP: this clip doesn't look like a presenter cam."
                self.autoPiPStatus = .completed(segmentID: segmentID, applied: false, message: msg)
                self.bannerMessage = msg
            }
        }
    }

    /// Suggestions produced by the background PiP scanner. Most recent
    /// at index 0 so the banner always shows the newest hint. Kept
    /// in-memory only — cheap to regenerate on reload.
    @Published var pipSuggestions: [PiPSuggestion] = []

    /// Overlay segment IDs the user has explicitly dismissed or already
    /// accepted this session. Blocks the scanner from re-emitting the
    /// same hint on every `refreshPiPSuggestions` call.
    private var pipSuggestionBlocklist: Set<UUID> = []

    /// Apply the suggested PiP layout for `id`. Removes the suggestion
    /// from the list and marks the overlay as handled so it won't be
    /// re-suggested.
    func applyPiPSuggestion(id: UUID) {
        guard let idx = pipSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let suggestion = pipSuggestions.remove(at: idx)
        pipSuggestionBlocklist.insert(suggestion.overlaySegmentID)
        setPiPLayout(segmentID: suggestion.overlaySegmentID, layout: suggestion.layout)
    }

    /// Drop a pending suggestion. Blocklists the overlay so we won't
    /// nag the user again about the same clip in this session.
    func dismissPiPSuggestion(id: UUID) {
        guard let idx = pipSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let suggestion = pipSuggestions.remove(at: idx)
        pipSuggestionBlocklist.insert(suggestion.overlaySegmentID)
    }

    /// Workflow-menu entry point: run the Auto-PiP analyzer on every
    /// overlay segment that doesn't already have a `pipLayout`. Each
    /// qualifying clip gets the suggested layout written directly (no
    /// suggestion banner) so the user sees one composition update at
    /// the end. Non-presenter overlays are left alone. Progress /
    /// outcome surfaces via `bannerMessage`.
    func applyAutoPiPToAllOverlays() {
        let candidateIDs: [UUID] = project.overlayTracks.flatMap { track in
            track.segments.compactMap { seg -> UUID? in
                seg.pipLayout == nil ? seg.id : nil
            }
        }
        guard !candidateIDs.isEmpty else {
            bannerMessage = L("Auto PiP: no overlays available to analyze.")
            return
        }
        let chatID = beginPresetActionChat(
            userAction: L("⚡ Auto Picture-in-Picture"),
            working: L(candidateIDs.count == 1 ? "Analyzing %d overlay for presenter cams…" : "Analyzing %d overlays for presenter cams…", candidateIDs.count),
            icon: "person.crop.circle.badge.checkmark"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.runAutoPiPAnalysis(candidateIDs: candidateIDs)
            if result.applied > 0 {
                self.finishPresetActionChat(
                    id: chatID,
                    text: L(result.applied == 1 ? "Placed %d presenter cam in a tidy corner." : "Placed %d presenter cams in tidy corners.", result.applied),
                    tone: .success,
                    icon: "checkmark.seal.fill"
                )
            } else {
                self.finishPresetActionChat(
                    id: chatID,
                    text: L("No overlays looked like presenter cams — nothing changed."),
                    tone: .warning,
                    icon: "exclamationmark.circle.fill"
                )
            }
        }
    }

    /// Summary of an Auto-PiP sweep. `attempted` is the number of
    /// overlay candidates actually fed through the analyzer; `applied`
    /// is the subset that were classified as presenter cams and had a
    /// layout written. `appliedIDs` are the overlay segment IDs that
    /// now carry a PiP layout. Used by the chat-agent `auto_pip` tool
    /// so the LLM can describe the outcome.
    struct AutoPiPRunResult: Sendable {
        let attempted: Int
        let applied: Int
        let appliedIDs: [UUID]
    }

    /// Awaitable twin of `applyAutoPiPToAllOverlays` — runs the Vision
    /// analyzer over `candidateIDs` (defaults to every overlay segment
    /// that does not yet have a `pipLayout`) and writes the suggested
    /// layout for each clip that qualifies as a presenter cam. Returns
    /// an `AutoPiPRunResult` so the chat agent can report counts.
    @discardableResult
    func runAutoPiPAnalysis(candidateIDs: [UUID]? = nil) async -> AutoPiPRunResult {
        let ids: [UUID] = candidateIDs ?? project.overlayTracks.flatMap { track in
            track.segments.compactMap { seg -> UUID? in
                seg.pipLayout == nil ? seg.id : nil
            }
        }
        guard !ids.isEmpty else {
            return AutoPiPRunResult(attempted: 0, applied: 0, appliedIDs: [])
        }
        var applied = 0
        var appliedIDs: [UUID] = []
        for id in ids {
            // Drop the suggestion banner for this overlay — the direct
            // write path would otherwise leave a stale "Apply?" bubble.
            pipSuggestions.removeAll { $0.overlaySegmentID == id }
            guard let decision = await analyzeOverlayForPiP(segmentID: id) else { continue }
            guard let layout = decision.suggestedLayout else { continue }
            // Re-check the segment still exists and wasn't manually
            // configured while the analyzer ran.
            let stillCandidate = project.overlayTracks.contains { track in
                track.segments.contains { $0.id == id && $0.pipLayout == nil }
            }
            guard stillCandidate else { continue }
            setPiPLayout(segmentID: id, layout: layout)
            applied += 1
            appliedIDs.append(id)
        }
        return AutoPiPRunResult(attempted: ids.count, applied: applied, appliedIDs: appliedIDs)
    }

    /// Scan overlay segments and asynchronously append a `PiPSuggestion`
    /// for each clip that looks like a presenter cam and doesn't
    /// already have a `pipLayout` set. Safe to call repeatedly — the
    /// blocklist + pipLayout checks prevent duplicate work.
    func refreshPiPSuggestions() {
        let candidates: [UUID] = project.overlayTracks.flatMap { track in
            track.segments.compactMap { seg -> UUID? in
                guard seg.pipLayout == nil else { return nil }
                guard !pipSuggestionBlocklist.contains(seg.id) else { return nil }
                guard !pipSuggestions.contains(where: { $0.overlaySegmentID == seg.id }) else { return nil }
                return seg.id
            }
        }
        guard !candidates.isEmpty else { return }

        for segmentID in candidates {
            // Reserve immediately so a follow-up refresh during the
            // in-flight analysis doesn't double-launch the same task.
            pipSuggestionBlocklist.insert(segmentID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let decision = await self.analyzeOverlayForPiP(segmentID: segmentID) else { return }
                guard let layout = decision.suggestedLayout else { return }
                // The user may have moved / modified the segment while
                // the analyzer was running — re-check before surfacing.
                let stillValid = self.project.overlayTracks.contains { track in
                    track.segments.contains { $0.id == segmentID && $0.pipLayout == nil }
                }
                guard stillValid else { return }
                // Unblock so apply/dismiss can manage the final state.
                self.pipSuggestionBlocklist.remove(segmentID)
                self.pipSuggestions.insert(
                    PiPSuggestion(
                        overlaySegmentID: segmentID,
                        layout: layout,
                        confidence: decision.confidence
                    ),
                    at: 0
                )
            }
        }
    }

    /// Core Auto-PiP analysis pipeline extracted from `applyAutoPiP` so
    /// the suggestion scanner can reuse the same resolution logic.
    /// Returns nil when the overlay segment, the covering V1 segment,
    /// or the proxy URLs can't be resolved.
    private func analyzeOverlayForPiP(segmentID: UUID) async -> AutoPiPAnalyzer.Decision? {
        guard let projectRoot else { return nil }

        var overlayHit: TimelineSegment? = nil
        for track in project.tracks where track.kind == .overlay {
            if let seg = track.segments.first(where: { $0.id == segmentID }) {
                overlayHit = seg
                break
            }
        }
        guard let overlaySeg = overlayHit else { return nil }
        let overlayStart = overlaySeg.placementOffset ?? 0
        let overlayEnd = overlayStart + overlaySeg.durationSeconds

        let mid = (overlayStart + overlayEnd) / 2
        var cumulative: Double = 0
        var primaryHit: TimelineSegment? = nil
        for seg in timelineSegments {
            let end = cumulative + seg.durationSeconds
            if mid >= cumulative && mid < end {
                primaryHit = seg
                break
            }
            cumulative = end
        }
        guard let primary = primaryHit else { return nil }

        func proxyURL(for sourceID: UUID) -> URL? {
            guard let rec = records.first(where: { $0.id == sourceID }),
                  let rel = rec.derived.proxyRelativePath else { return nil }
            return projectRoot.appending(path: rel)
        }
        guard let overlayURL = proxyURL(for: overlaySeg.sourceVideoID),
              let primaryURL = proxyURL(for: primary.sourceVideoID) else { return nil }

        let overlayAsset = AVURLAsset(url: overlayURL)
        let primaryAsset = AVURLAsset(url: primaryURL)

        var aspect: Double = 16.0 / 9.0
        if let t = try? await overlayAsset.loadTracks(withMediaType: .video).first,
           let size = try? await t.load(.naturalSize),
           size.height > 0 {
            aspect = Double(size.width) / Double(size.height)
        }

        return await AutoPiPAnalyzer.analyze(
            primaryAsset: primaryAsset,
            primaryRangeStart: primary.range.startSeconds,
            primaryRangeEnd: primary.range.endSeconds,
            overlayAsset: overlayAsset,
            overlayRangeStart: overlaySeg.range.startSeconds,
            overlayRangeEnd: overlaySeg.range.endSeconds,
            overlaySourceAspect: aspect
        )
    }

    /// Toggle the video-visibility flag on one segment (primary or
    /// overlay). When hidden, the composition leaves the segment's time
    /// range occupied but shows empty/black — audio still plays
    /// according to `volumeLevel`, and downstream segments don't shift.
    /// Pushes a user-edit revision so Cmd+Z works.
    func setSegmentVideoHidden(segmentID: UUID, hidden: Bool) {
        // Primary track lives on the separate `timelineSegments` array
        // that the composition is actually built from.
        if let idx = timelineSegments.firstIndex(where: { $0.id == segmentID }) {
            guard timelineSegments[idx].isVideoHidden != hidden else { return }
            pushRevision(
                label: hidden ? "Hide segment video" : "Show segment video",
                trigger: .userEdit(description: "toggle-video-hidden")
            )
            timelineSegments[idx].isVideoHidden = hidden
            rebuildComposition()
            return
        }
        // Overlay tracks live under `project.tracks`.
        var mutated = project
        var hit = false
        for trackIdx in mutated.tracks.indices where mutated.tracks[trackIdx].kind == .overlay {
            if let segIdx = mutated.tracks[trackIdx].segments.firstIndex(where: { $0.id == segmentID }) {
                guard mutated.tracks[trackIdx].segments[segIdx].isVideoHidden != hidden else { return }
                mutated.tracks[trackIdx].segments[segIdx].isVideoHidden = hidden
                hit = true
                break
            }
        }
        guard hit else { return }
        pushRevision(
            label: hidden ? "Hide overlay video" : "Show overlay video",
            trigger: .userEdit(description: "toggle-video-hidden")
        )
        project = mutated
        rebuildComposition()
    }

    /// Toggle audio mute on one segment (primary or overlay) by flipping
    /// `volumeLevel` between 0.0 and 1.0. Simpler than remembering the
    /// pre-mute volume — users who want fine-grained levels use the
    /// volume slider on the V1 context menu or BGM lane bar.
    func toggleSegmentAudioMuted(segmentID: UUID) {
        if let idx = timelineSegments.firstIndex(where: { $0.id == segmentID }) {
            let next: Double = timelineSegments[idx].volumeLevel > 0 ? 0 : 1
            pushRevision(
                label: next == 0 ? "Mute segment" : "Unmute segment",
                trigger: .userEdit(description: "toggle-audio-muted")
            )
            timelineSegments[idx].volumeLevel = next
            rebuildComposition()
            return
        }
        var mutated = project
        var hit = false
        for trackIdx in mutated.tracks.indices where mutated.tracks[trackIdx].kind == .overlay {
            if let segIdx = mutated.tracks[trackIdx].segments.firstIndex(where: { $0.id == segmentID }) {
                let next: Double = mutated.tracks[trackIdx].segments[segIdx].volumeLevel > 0 ? 0 : 1
                mutated.tracks[trackIdx].segments[segIdx].volumeLevel = next
                hit = true
                break
            }
        }
        guard hit else { return }
        pushRevision(
            label: "Toggle overlay mute",
            trigger: .userEdit(description: "toggle-audio-muted")
        )
        project = mutated
        rebuildComposition()
    }

    // MARK: - Detach Audio (V1 ↔ A2 link)

    /// Human-readable name used for the detached-audio track. Reused
    /// across every V1 clip the user detaches so audio blocks all land
    /// on one "A2" lane rather than spawning a new track per detach.
    static let detachedAudioTrackName = "Detached Audio"

    /// Detach the audio of the V1 clip identified by `segmentID` onto an
    /// auxiliary audio track. Creates a mirror `TimelineSegment` with the
    /// same source range, anchored via `placementOffset` to the V1 clip's
    /// composed start, and links the two segments via `linkedSegmentID`.
    /// Mutes V1's own audio (`volumeLevel = 0`). No-op if the segment is
    /// already detached.
    func detachAudio(segmentID: UUID) {
        guard let v1Index = timelineSegments.firstIndex(where: { $0.id == segmentID }) else { return }
        guard timelineSegments[v1Index].linkedSegmentID == nil else { return }

        let v1 = timelineSegments[v1Index]
        let composedStart = composedSegmentStart(at: v1Index)

        pushRevision(label: "Detach audio", trigger: .userEdit(description: "detach-audio"))

        // Build the mirror aux-audio segment.
        var aux = TimelineSegment(
            id: UUID(),
            sourceVideoID: v1.sourceVideoID,
            range: v1.range,
            text: "",
            subtitles: [],
            placementOffset: composedStart
        )
        aux.volumeLevel = 1.0
        aux.speedRate = v1.speedRate
        aux.linkedSegmentID = v1.id

        // Wire the V1 side: mute its audio and record the link.
        timelineSegments[v1Index].volumeLevel = 0
        timelineSegments[v1Index].linkedSegmentID = aux.id

        // Append to an existing Detached Audio track (reuse so clips all
        // land on one lane) or spin up a new one.
        if let trackIdx = project.tracks.firstIndex(where: {
            $0.kind == .audio && $0.name == Self.detachedAudioTrackName
        }) {
            project.tracks[trackIdx].segments.append(aux)
        } else {
            let track = Track(
                kind: .audio,
                name: Self.detachedAudioTrackName,
                segments: [aux]
            )
            project.tracks.append(track)
        }

        rebuildComposition()
    }

    /// Re-attach previously detached audio. Works regardless of which
    /// side (V1 or aux) the caller hands us: follows `linkedSegmentID`
    /// to find the paired segment, deletes the aux mirror, unmutes V1,
    /// clears both link fields. If the Detached Audio track is left
    /// empty, removes it so stray tracks don't clutter the timeline.
    func reattachAudio(segmentID: UUID) {
        // Resolve the two endpoints regardless of which side was passed.
        let v1ID: UUID
        let auxID: UUID
        if let idx = timelineSegments.firstIndex(where: { $0.id == segmentID }) {
            guard let link = timelineSegments[idx].linkedSegmentID else { return }
            v1ID = segmentID
            auxID = link
        } else if let (_, _, seg) = findAuxAudioSegment(segmentID: segmentID),
                  let link = seg.linkedSegmentID {
            v1ID = link
            auxID = segmentID
        } else {
            return
        }

        pushRevision(label: "Reattach audio", trigger: .userEdit(description: "reattach-audio"))

        // V1 side: unmute + clear link.
        if let v1Idx = timelineSegments.firstIndex(where: { $0.id == v1ID }) {
            timelineSegments[v1Idx].volumeLevel = 1.0
            timelineSegments[v1Idx].linkedSegmentID = nil
        }

        // Aux side: remove the segment; remove the track if it became empty.
        for trackIdx in project.tracks.indices where project.tracks[trackIdx].kind == .audio {
            if let segIdx = project.tracks[trackIdx].segments.firstIndex(where: { $0.id == auxID }) {
                project.tracks[trackIdx].segments.remove(at: segIdx)
                if project.tracks[trackIdx].segments.isEmpty
                    && project.tracks[trackIdx].name == Self.detachedAudioTrackName {
                    project.tracks.remove(at: trackIdx)
                }
                break
            }
        }

        rebuildComposition()
    }

    /// Locate an aux-audio segment by id. Returns the owning track index,
    /// segment index, and a copy of the segment so callers can inspect
    /// the link without immediately mutating. Only scans `.audio`-kind
    /// tracks (BGM + detached-audio lanes).
    func findAuxAudioSegment(segmentID: UUID) -> (trackIndex: Int, segmentIndex: Int, segment: TimelineSegment)? {
        for trackIdx in project.tracks.indices where project.tracks[trackIdx].kind == .audio {
            if let segIdx = project.tracks[trackIdx].segments.firstIndex(where: { $0.id == segmentID }) {
                return (trackIdx, segIdx, project.tracks[trackIdx].segments[segIdx])
            }
        }
        return nil
    }

    /// Public wrapper around `composedSegmentStart(at:)` so the detach
    /// UI and tests can query "where does this V1 clip begin?" without
    /// the helper being internal-only.
    func composedStart(ofSegmentID segmentID: UUID) -> Double? {
        guard let idx = timelineSegments.firstIndex(where: { $0.id == segmentID }) else { return nil }
        return composedSegmentStart(at: idx)
    }

    /// Refresh every linked aux-audio segment so its placementOffset,
    /// range, and speedRate stay in sync with its paired V1 clip. Called
    /// after V1-side edits that can shift composed starts (move) or
    /// change the paired clip's duration (trim). No-op for projects with
    /// no detached audio.
    func syncAllLinkedAuxSegments() {
        for (i, seg) in timelineSegments.enumerated() where seg.linkedSegmentID != nil {
            syncLinkedAuxSegment(v1Index: i)
        }
    }

    private func syncLinkedAuxSegment(v1Index: Int) {
        guard v1Index >= 0, v1Index < timelineSegments.count else { return }
        let v1 = timelineSegments[v1Index]
        guard let auxID = v1.linkedSegmentID,
              let (trackIdx, segIdx, _) = findAuxAudioSegment(segmentID: auxID) else { return }
        project.tracks[trackIdx].segments[segIdx].range = v1.range
        project.tracks[trackIdx].segments[segIdx].speedRate = v1.speedRate
        project.tracks[trackIdx].segments[segIdx].placementOffset = composedSegmentStart(at: v1Index)
    }

    /// Remove the aux-audio segment with id `auxID`, wherever it lives,
    /// and clean up the owning detached-audio track if it becomes empty.
    /// Returns true when the segment was found + removed. Used by the
    /// V1-side delete path (cascade) and by `deleteAuxAudioSegment`
    /// (symmetric UI-initiated delete on A2).
    @discardableResult
    private func removeAuxAudioSegment(_ auxID: UUID) -> Bool {
        for trackIdx in project.tracks.indices where project.tracks[trackIdx].kind == .audio {
            if let segIdx = project.tracks[trackIdx].segments.firstIndex(where: { $0.id == auxID }) {
                project.tracks[trackIdx].segments.remove(at: segIdx)
                if project.tracks[trackIdx].segments.isEmpty
                    && project.tracks[trackIdx].name == Self.detachedAudioTrackName {
                    project.tracks.remove(at: trackIdx)
                }
                return true
            }
        }
        return false
    }

    /// Delete an aux-audio segment (as initiated from the A2 lane). If
    /// the segment was linked to a V1 clip, reattach that clip's audio
    /// first (i.e. unmute V1 + clear link) so the user is left with a
    /// consistent timeline rather than a silent V1 and an empty A2 slot.
    func deleteAuxAudioSegment(id: UUID) {
        guard let (_, _, seg) = findAuxAudioSegment(segmentID: id) else { return }
        if let v1ID = seg.linkedSegmentID {
            reattachAudio(segmentID: v1ID)
            return
        }
        pushRevision(label: "Delete audio clip", trigger: .userEdit(description: "delete-aux-audio"))
        removeAuxAudioSegment(id)
        rebuildComposition()
    }

    /// previous primary take becomes an alternate on the segment so the
    /// user can always swap back. Triggers an undo snapshot and a
    /// composition rebuild so the preview updates immediately.
    // MARK: - Chapter generation (AI)

    /// True while a chapter-generation request is in flight. UI binds to
    /// this to disable the trigger and show a spinner.
    @Published var isGeneratingChapters: Bool = false

    /// Chapters for the currently-loaded timeline. Reads from the
    /// primary record (the source of the first timeline segment).
    /// `nil` if no chapters have been generated yet.
    var currentChapters: [VideoChapter]? {
        guard let firstRecordID = timelineSegments.first?.sourceVideoID else { return nil }
        return records.first(where: { $0.id == firstRecordID })?.copilot?.chapters
    }

    /// Style + position of the chapter bar for the current timeline.
    /// Falls back to `ChapterBarStyle.default` when the project has
    /// never been customized.
    var currentChapterBarStyle: ChapterBarStyle {
        guard let firstRecordID = timelineSegments.first?.sourceVideoID else { return .default }
        return records.first(where: { $0.id == firstRecordID })?.copilot?.chapterBarStyle ?? .default
    }

    /// The record that owns the chapter list for the current timeline
    /// (= the source record of the first timeline segment). For v1 the
    /// chapters all live on this record; multi-source projects fall back
    /// to whichever record contributes the first segment.
    private var chapterOwnerRecordID: UUID? {
        timelineSegments.first?.sourceVideoID
    }

    /// Run the chapter-generation LLM pass on the *current* timeline and
    /// store the result on the owning record's snapshot. Pushes a
    /// revision so the previous chapter list (if any) can be restored
    /// via undo. Best-effort: any failure surfaces on `bannerMessage`.
    func regenerateChaptersWithAI() async {
        guard !isGeneratingChapters else { return }
        guard let ownerID = chapterOwnerRecordID,
              !timelineSegments.isEmpty else {
            bannerMessage = L("Nothing on the timeline to chapter.")
            return
        }
        guard let config = OpenAIConfiguration.fromEnvironment() else {
            bannerMessage = L("Set up an OpenAI API key to generate chapters.")
            return
        }

        // Build the cut-transcript with edited-timeline timing. Each
        // composed segment becomes one transcript entry.
        var cursor: Double = 0
        var cutTranscript: [TranscriptSegment] = []
        for seg in timelineSegments {
            let dur = max(0, seg.durationSeconds)
            cutTranscript.append(
                TranscriptSegment(
                    startSeconds: cursor,
                    endSeconds: cursor + dur,
                    text: seg.text,
                    sourceVideoID: nil
                )
            )
            cursor += dur
        }
        let total = cursor
        guard total > 1 else {
            bannerMessage = L("Timeline is too short to chapter.")
            return
        }

        isGeneratingChapters = true
        defer { isGeneratingChapters = false }

        let chatID = beginPresetActionChat(
            userAction: L("⚡ Generate chapter bar"),
            working: L("Drafting chapters from the cut…"),
            icon: "list.bullet.rectangle"
        )

        let service = LLMEditorService(client: OpenAIClient(configuration: config))
        let chapters: [VideoChapter]
        do {
            chapters = try await service.generateChapters(
                cutTranscript: cutTranscript,
                totalDuration: total
            )
        } catch {
            bannerMessage = L("Chapter generation failed: %@", error.localizedDescription)
            finishPresetActionChat(
                id: chatID,
                text: L("Chapter generation failed: %@", error.localizedDescription),
                tone: .failure,
                icon: "exclamationmark.triangle.fill"
            )
            return
        }

        guard !chapters.isEmpty else {
            bannerMessage = L("AI returned no chapters.")
            finishPresetActionChat(
                id: chatID,
                text: L("AI returned no chapters."),
                tone: .warning,
                icon: "exclamationmark.circle.fill"
            )
            return
        }

        pushRevision(
            label: "Generate chapter bar",
            trigger: .userEdit(description: "generate-chapters")
        )

        // Persist on the owning record's snapshot.
        if let store {
            do {
                var manifest = try store.loadManifest()
                if let idx = manifest.media.firstIndex(where: { $0.id == ownerID }) {
                    if manifest.media[idx].copilot == nil {
                        manifest.media[idx].copilot = AICopilotSnapshot(
                            semanticTags: [],
                            summary: nil,
                            transcriptPreview: nil,
                            suggestedInSeconds: nil,
                            suggestedOutSeconds: nil,
                            issues: [],
                            suggestions: [],
                            markers: [],
                            keptRanges: nil,
                            keptTexts: nil,
                            keptAlternativesPerRange: nil,
                            transcript: nil,
                            wordTranscript: nil,
                            editLog: nil,
                            bRollSuggestions: nil,
                            chapters: chapters
                        )
                    } else {
                        manifest.media[idx].copilot?.chapters = chapters
                    }
                    try store.saveManifest(manifest)
                    await loadRecords()
                    bannerMessage = L(chapters.count == 1 ? "Generated %d chapter." : "Generated %d chapters.", chapters.count)
                    finishPresetActionChat(
                        id: chatID,
                        text: L(chapters.count == 1 ? "Generated %d chapter and burned the progress bar." : "Generated %d chapters and burned the progress bar.", chapters.count),
                        tone: .success,
                        icon: "checkmark.seal.fill"
                    )
                }
            } catch {
                bannerMessage = L("Chapter persist failed: %@", error.localizedDescription)
                finishPresetActionChat(
                    id: chatID,
                    text: L("Chapter persist failed: %@", error.localizedDescription),
                    tone: .failure,
                    icon: "exclamationmark.triangle.fill"
                )
            }
        }
    }

    /// Overwrite the owning record's chapter list (used by divider
    /// drags, time-input edits, renames). Pushes a revision so the
    /// previous list can be restored via undo. Does **not** re-run
    /// the LLM pass.
    func updateChapters(_ chapters: [VideoChapter], label: String = "Edit chapters") {
        guard let ownerID = chapterOwnerRecordID else { return }
        guard currentChapters != chapters else { return }

        pushRevision(
            label: label,
            trigger: .userEdit(description: "chapters-edit")
        )

        persistChaptersAndStyle(
            ownerID: ownerID,
            chapters: chapters,
            style: nil
        )
    }

    /// Overwrite the owning record's chapter bar style. Pushes a
    /// revision so the previous style is restored via undo.
    func updateChapterBarStyle(_ style: ChapterBarStyle, label: String = "Edit chapter style") {
        guard let ownerID = chapterOwnerRecordID else { return }
        guard currentChapterBarStyle != style else { return }

        pushRevision(
            label: label,
            trigger: .userEdit(description: "chapter-style-edit")
        )

        persistChaptersAndStyle(
            ownerID: ownerID,
            chapters: nil,
            style: style
        )
    }

    /// Shared persistence path for chapter edits + style edits. Either
    /// (or both) may be nil to leave that half unchanged.
    private func persistChaptersAndStyle(
        ownerID: UUID,
        chapters: [VideoChapter]?,
        style: ChapterBarStyle?
    ) {
        guard let store else { return }
        do {
            var manifest = try store.loadManifest()
            guard let idx = manifest.media.firstIndex(where: { $0.id == ownerID }) else { return }
            if manifest.media[idx].copilot == nil {
                manifest.media[idx].copilot = AICopilotSnapshot(
                    semanticTags: [],
                    summary: nil,
                    transcriptPreview: nil,
                    suggestedInSeconds: nil,
                    suggestedOutSeconds: nil,
                    issues: [],
                    suggestions: [],
                    markers: [],
                    keptRanges: nil,
                    keptTexts: nil,
                    keptAlternativesPerRange: nil,
                    transcript: nil,
                    wordTranscript: nil,
                    editLog: nil,
                    bRollSuggestions: nil,
                    chapters: chapters,
                    chapterBarStyle: style
                )
            } else {
                if let chapters {
                    manifest.media[idx].copilot?.chapters = chapters
                }
                if let style {
                    manifest.media[idx].copilot?.chapterBarStyle = style
                }
            }
            try store.saveManifest(manifest)
            Task { await loadRecords() }
        } catch {
            bannerMessage = L("Chapter persist failed: %@", error.localizedDescription)
        }
    }

    func swapAlternativeTake(segmentID: UUID, takeID: UUID) {        guard let idx = timelineSegments.firstIndex(where: { $0.id == segmentID }) else { return }
        let current = timelineSegments[idx]
        guard let takeIdx = current.alternatives.firstIndex(where: { $0.id == takeID }) else { return }
        let take = current.alternatives[takeIdx]

        // Build the "demoted" alternate from the currently-on-timeline
        // take so it can be swapped back later. Reuse the primary's
        // existing alternative id slot if present to preserve stable
        // identity across swaps.
        let demoted = AlternativeTake(
            id: takeID, // recycle ids so the ordering stays stable
            sourceVideoID: current.sourceVideoID,
            startSeconds: current.range.startSeconds,
            endSeconds: current.range.endSeconds,
            text: current.text,
            reason: take.reason
        )

        pushRevision(
            label: "Swap alternate take",
            trigger: .userEdit(description: "swap-alternative-take")
        )

        var updated = current
        updated.range = TimeRange(
            startSeconds: take.startSeconds,
            endSeconds: take.endSeconds
        )
        updated.text = take.text
        // `sourceVideoID` on the take is set by rebuildTimelineSegments
        // to the owning record; only swap it in when valid so a missing
        // id can't break playback.
        var newAlternatives = current.alternatives
        newAlternatives[takeIdx] = demoted
        updated.alternatives = newAlternatives
        // The swap changes the source window, so its subtitle index is
        // stale. Clear it — rebuildComposition / subtitle rebuild will
        // resynthesize from the source transcript for the new window.
        updated.subtitles = rebuildSubtitles(
            for: updated.range,
            recordID: updated.sourceVideoID
        ) ?? []

        timelineSegments[idx] = updated
        rebuildComposition()
    }

    /// Lightweight helper to build subtitle entries for a source-time
    /// window from the owning record's transcript. Returns nil when the
    /// record isn't analyzed yet (caller should treat that as "no
    /// subtitles").
    private func rebuildSubtitles(
        for range: TimeRange,
        recordID: UUID
    ) -> [SubtitleEntry]? {
        guard let record = records.first(where: { $0.id == recordID }) else { return nil }
        return Self.buildSubtitleEntries(
            for: range,
            from: record.copilot?.transcript,
            wordTranscript: record.copilot?.wordTranscript
        )
    }

    // MARK: - Visual markers (timeline analysis overlay)

    /// Cached visual-analysis matches published to the timeline markers
    /// overlay. Populated by `refreshVisualMarkers()`.
    @Published var visualMarkers: [VisualAgentQuery.CueMatch] = []
    @Published var isLoadingVisualMarkers: Bool = false

    /// Re-run the visual-index queries over the current timeline and
    /// publish the result for the timeline marker strip.
    func refreshVisualMarkers() {
        guard !isLoadingVisualMarkers else { return }
        isLoadingVisualMarkers = true
        Task { @MainActor in
            let indices = await loadOrBuildVisualIndices()
            var all: [VisualAgentQuery.CueMatch] = []
            all.append(contentsOf: VisualAgentQuery.findBlackFrames(segments: timelineSegments, indices: indices))
            all.append(contentsOf: VisualAgentQuery.findEmptyFrames(segments: timelineSegments, indices: indices))
            all.append(contentsOf: VisualAgentQuery.findSceneChanges(segments: timelineSegments, indices: indices))
            self.visualMarkers = all
            self.isLoadingVisualMarkers = false
        }
    }

    // MARK: - Audio post-processing (P1)

    /// Analyze each unique source clip's average loudness and attenuate
    /// segments toward `targetDB` (default -16 dBFS, the Apple Podcasts
    /// loudness target). Quiet sources are left untouched because
    /// AVMutableAudioMix can't go above unity gain.
    func normalizeLoudness(targetDB: Double = -16) async {
        guard !timelineSegments.isEmpty else {
            bannerMessage = L("Nothing on the timeline to normalize.")
            return
        }

        bannerMessage = L("Analyzing audio loudness…")

        let analyzer = AudioQualityService()
        let uniqueSourceIDs = Set(timelineSegments.map(\.sourceVideoID))
        var sourceAvgDB: [UUID: Double] = [:]
        for sid in uniqueSourceIDs {
            guard let rec = records.first(where: { $0.id == sid }) else { continue }
            let url = URL(fileURLWithPath: rec.sourcePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let result = try await analyzer.analyze(url: url)
                sourceAvgDB[sid] = result.averageLoudnessDB
            } catch {
                continue
            }
        }

        let gains = AudioPostProcessor.computeNormalizationGains(
            sourceAverageDB: sourceAvgDB,
            targetDB: targetDB
        )

        guard !gains.isEmpty else {
            bannerMessage = L("Loudness already at or below %d dB — nothing to attenuate.", Int(targetDB))
            return
        }

        var changed = 0
        var pendingSegments = timelineSegments
        for i in pendingSegments.indices {
            guard let gain = gains[pendingSegments[i].sourceVideoID] else { continue }
            // Set volume to the absolute target gain (not multiply). Gain
            // is already derived from source dB → target dB so running
            // this repeatedly with the same targetDB is idempotent.
            // Prior per-segment volume is recoverable via undo
            // (pushRevision just above snapshots it).
            let newLevel = max(0, min(1, gain))
            if abs(pendingSegments[i].volumeLevel - newLevel) > 0.001 {
                pendingSegments[i].volumeLevel = newLevel
                changed += 1
            }
        }

        guard changed > 0 else {
            bannerMessage = L("Loudness normalization didn't change any segments.")
            return
        }

        pushRevision(
            label: "Normalize loudness to \(Int(targetDB)) dB",
            trigger: .userEdit(description: "audio-normalize")
        )
        timelineSegments = pendingSegments
        rebuildComposition()
        bannerMessage = L(changed == 1 ? "Normalized loudness on %d segment." : "Normalized loudness on %d segments.", changed)
    }

    /// Detect runs of silence at least `minDuration` long and apply
    /// `setSpeedRange` actions to skim through them at `rate` (default 4×).
    /// Mirrors a common podcast workflow ("compress dead air"). Reuses the
    /// existing AIAction pipeline so undo/redo and timeline rebuilding
    /// behave the same as a manual edit.
    func compressSilences(minDuration: Double = 1.0, rate: Double = 4.0) async {
        guard !timelineSegments.isEmpty else {
            bannerMessage = L("Nothing on the timeline to compress.")
            return
        }

        bannerMessage = L("Scanning for silences…")

        let analyzer = AudioQualityService()
        var silentRangesBySource: [UUID: [ClosedRange<Double>]] = [:]
        for sid in Set(timelineSegments.map(\.sourceVideoID)) {
            guard let rec = records.first(where: { $0.id == sid }) else { continue }
            let url = URL(fileURLWithPath: rec.sourcePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let result = try await analyzer.analyze(url: url)
                silentRangesBySource[sid] = result.silentRanges
            } catch {
                continue
            }
        }

        let regions = AudioPostProcessor.computeSilenceSpeedUps(
            segments: timelineSegments,
            silentRangesBySource: silentRangesBySource,
            minDuration: minDuration,
            rate: rate
        )

        guard !regions.isEmpty else {
            bannerMessage = L("No silences longer than %.1fs found.", minDuration)
            return
        }

        let actions: [AIAction] = regions.map {
            .setSpeedRange(start: $0.startSeconds, end: $0.endSeconds, rate: $0.rate)
        }
        let batch = AIActionBatch(
            actions: actions,
            explanation: "Compress \(regions.count) silence\(regions.count == 1 ? "" : "s") at \(String(format: "%.1fx", rate))"
        )

        let result = AIActionExecutor.apply(
            batch: batch,
            to: timelineSegments,
            baseSubtitleStyle: subtitleStyle,
            transcriptLookup: { ranges, sourceID in
                self.subtitleEntries(for: ranges, sourceVideoID: sourceID)
            }
        )

        pushRevision(label: batch.explanation, trigger: .userEdit(description: "audio-silence-compress"))
        timelineSegments = result.segments
        reconcileSegmentSelection()
        rebuildComposedSubtitles()
        rebuildComposition()
        bannerMessage = L(regions.count == 1 ? "Compressed %d silence." : "Compressed %d silences.", regions.count)
    }

    /// Add a BGM (background music) track. The source file is imported
    /// through the media core (same pipeline as video imports so it ends
    /// up in `records` and is visible to `sourceLookup`). A single
    /// timeline segment spans the full audio source and is placed on a
    /// new `.audio` Track in the project. The BGM mixes on top of the
    /// primary video track's audio at export time via CompositionBuilder's
    /// auxAudioTracks path.
    func addBGMTrack(from url: URL) async {
        guard let mediaCore else {
            bannerMessage = L("Media core not configured.")
            return
        }
        bannerMessage = L("Importing BGM %@…", url.lastPathComponent)
        do {
            let mediaId = try await mediaCore.importLocalVideo(url: url)
            await loadRecords()

            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            guard duration > 0.05 else {
                bannerMessage = L("BGM file has no playable duration.")
                return
            }

            let segment = TimelineSegment(
                id: UUID(),
                sourceVideoID: mediaId,
                range: TimeRange(startSeconds: 0, endSeconds: duration),
                text: "BGM",
                subtitles: [],
                volumeLevel: 0.3
            )
            let trackName = "BGM \(project.audioTracks.count + 1)"
            let track = Track(
                kind: .audio,
                name: trackName,
                segments: [segment]
            )

            pushRevision(label: "Add BGM: \(url.lastPathComponent)",
                         trigger: .userEdit(description: "add-bgm"))
            project.tracks.append(track)
            bannerMessage = L("Added %@ (%.1fs)", trackName, duration)
        } catch {
            bannerMessage = L("Failed to import BGM: %@", error.localizedDescription)
        }
    }

    /// Insert a built-in synthesized sound effect at `composedTime` on
    /// the timeline. The .wav is rendered on first use (cached under
    /// Application Support) and then imported through the same
    /// MediaCore pipeline as BGM so it participates normally in the
    /// aux audio mix at export time.
    ///
    /// Unlike BGM (which spans the full source), an SFX is short and
    /// anchored — we use `placementOffset` so CompositionBuilder drops
    /// it at exactly the composed time the user chose.
    func addSFX(kind: SFXKind, at composedTime: Double) async {
        guard let mediaCore else {
            bannerMessage = L("Media core not configured.")
            return
        }
        let def = SFXCatalog.definition(for: kind)
        let displayName = L(def.displayKey)
        bannerMessage = L("Adding sound effect %@…", displayName)
        do {
            let url = try SFXRenderer.ensureRendered(kind)
            let mediaId = try await mediaCore.importLocalVideo(url: url)
            await loadRecords()

            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration))?.seconds ?? def.durationSeconds
            guard duration > 0.01 else {
                bannerMessage = L("Sound effect render produced no audio.")
                return
            }

            let anchor = max(0, composedTime)
            let segment = TimelineSegment(
                id: UUID(),
                sourceVideoID: mediaId,
                range: TimeRange(startSeconds: 0, endSeconds: duration),
                text: displayName,
                subtitles: [],
                volumeLevel: 0.9,
                placementOffset: anchor
            )
            let trackName = String(format: L("SFX %d"), project.audioTracks.count + 1)
            let track = Track(
                kind: .audio,
                name: trackName,
                segments: [segment]
            )
            pushRevision(label: "Add SFX: \(displayName)",
                         trigger: .userEdit(description: "add-sfx"))
            project.tracks.append(track)
            bannerMessage = L("Added %@ at %.1fs", displayName, anchor)
        } catch {
            bannerMessage = L("Failed to add sound effect: %@", error.localizedDescription)
        }
    }

    /// Remove a non-primary track (audio / overlay). The primary video
    /// track is protected — it's the backing store for `timelineSegments`.
    func removeTrack(id: UUID) {
        guard let idx = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        guard project.tracks[idx].kind != .video else { return }
        pushRevision(label: "Remove \(project.tracks[idx].name)",
                     trigger: .userEdit(description: "remove-track"))
        project.tracks.remove(at: idx)
    }

    /// Toggle mute on any track — including V1. For V1 this zeroes the
    /// primary track's audio contribution in the export / preview mix;
    /// overlay tracks are skipped entirely, aux audio tracks drop out
    /// of the mix.
    func toggleTrackMute(id: UUID) {
        mutateProject(label: "Toggle mute") { project in
            guard let idx = project.tracks.firstIndex(where: { $0.id == id }) else { return false }
            project.tracks[idx].isMuted.toggle()
            return true
        }
    }

    /// Lock / unlock a track. Locked tracks have every segment-level
    /// mutation (move, trim, delete, split, speed, volume, rotate, …)
    /// blocked at the VM boundary. Toggling the lock itself is always
    /// allowed regardless of current state.
    func toggleTrackLocked(id: UUID) {
        mutateProject(label: "Toggle lock") { project in
            guard let idx = project.tracks.firstIndex(where: { $0.id == id }) else { return false }
            project.tracks[idx].isLocked.toggle()
            return true
        }
    }

    /// Find the track that owns the given segment id, if any.
    func trackID(forSegment segmentID: UUID) -> UUID? {
        for track in project.tracks {
            if track.segments.contains(where: { $0.id == segmentID }) {
                return track.id
            }
        }
        return nil
    }

    /// Convenience: is the track currently locked?
    func isTrackLocked(id: UUID) -> Bool {
        project.tracks.first(where: { $0.id == id })?.isLocked ?? false
    }

    /// True when `segmentID` lives on a locked track. Used as a guard
    /// at the top of every segment-targeted mutation.
    func isSegmentLocked(_ segmentID: UUID) -> Bool {
        guard let tID = trackID(forSegment: segmentID) else { return false }
        return isTrackLocked(id: tID)
    }

    /// Set volume for the single segment on an aux audio track
    /// (convenience for BGM volume knobs in the UI).
    func setAuxTrackVolume(id: UUID, volume: Double) {
        let clamped = max(0, min(1, volume))
        mutateProject(label: "Adjust aux track volume") { project in
            guard let idx = project.tracks.firstIndex(where: { $0.id == id }) else { return false }
            guard project.tracks[idx].kind == .audio else { return false }
            var mutated = false
            for segIdx in project.tracks[idx].segments.indices where abs(project.tracks[idx].segments[segIdx].volumeLevel - clamped) > 0.001 {
                project.tracks[idx].segments[segIdx].volumeLevel = clamped
                mutated = true
            }
            return mutated
        }
    }

    /// Lightweight transcribe-only path used by `detect_speakers` when
    /// the user clicks "Detect speakers" on a clip that hasn't been
    /// analyzed yet. We run the local `AnalysisOrchestrator`
    /// (transcription + scene + audio quality, no LLM cuts, no B-roll)
    /// for every video on the timeline that is missing a copilot
    /// snapshot, then store a "keep everything" snapshot whose single
    /// keptRange covers the full source duration verbatim — no silence
    /// trimming, no cuts. This lets diarization stamp speaker IDs onto
    /// the resulting cues without having to run First Cut, which would
    /// otherwise rewrite the user's timeline against their will.
    ///
    /// Best-effort: each source is processed independently, failures
    /// are logged + skipped. Returns whether at least one source ended
    /// up with a transcript.
    func transcribeForDiarization() async -> Bool {
        guard let store else { return false }
        guard !isAnalyzing else { return false }

        let allOnTimeline = videoRecordsOnTimeline
        let pending = allOnTimeline.filter {
            $0.status == .ready && $0.copilot == nil && $0.analysis != nil
        }
        if pending.isEmpty {
            // We came in here because composedSubtitles was empty, so
            // the agent expected a transcript to materialize. Surfacing
            // *why* `pending` is empty makes the difference between
            // "no audio" and "import didn't probe yet" obvious from the
            // console log without needing a debugger.
            for r in allOnTimeline {
                let hasAnalysis = r.analysis != nil
                let hasCopilot = r.copilot != nil
                let txCount = r.copilot?.transcript?.count ?? 0
                print("🔴 transcribeForDiarization: pending empty. record=\(r.id) " +
                      "status=\(r.status) hasAnalysis=\(hasAnalysis) hasCopilot=\(hasCopilot) " +
                      "transcriptCues=\(txCount)")
            }
            if allOnTimeline.isEmpty {
                print("🔴 transcribeForDiarization: pending empty — no video records on timeline.")
            }
            return false
        }

        isAnalyzing = true
        bannerMessage = nil

        let totalCount = pending.count
        appendAnalysisAssistantLine(
            totalCount > 1
                ? L("Transcribing %d clips for speaker detection…", totalCount)
                : L("Transcribing for speaker detection…"),
            icon: "waveform",
            tone: .working,
            persist: true
        )

        let orchestrator = AnalysisOrchestrator()
        var anySucceeded = false

        for record in pending {
            guard let analysis = record.analysis else { continue }
            let sourceURL: URL
            if let proxyPath = record.derived.proxyRelativePath, let root = projectRoot {
                sourceURL = root.appending(path: proxyPath)
            } else {
                sourceURL = URL(fileURLWithPath: record.sourcePath)
            }

            // Mark this source as analyzing so the UI status chip
            // updates and concurrent analysis calls bail.
            do {
                var manifest = try store.loadManifest()
                if let idx = manifest.media.firstIndex(where: { $0.id == record.id }) {
                    manifest.media[idx].status = .analyzing
                    try store.saveManifest(manifest)
                }
            } catch {
                print("🔴 transcribeForDiarization: failed to mark analyzing for \(record.id): \(error)")
                continue
            }

            do {
                let localResult = try await orchestrator.analyze(
                    sourceURL: sourceURL,
                    analysis: analysis,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.analysisProgress = progress
                            self?.updateAnalysisChatBubble(progress)
                        }
                    }
                )

                // Single keptRange covering the whole source — no
                // silence trimming, no LLM cuts. We're _only_ here to
                // get a transcript so diarization has cues to stamp.
                let fullRange = TimeRange(
                    startSeconds: 0,
                    endSeconds: analysis.durationSeconds
                )
                let allText = localResult.transcript
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let snapshot = AICopilotSnapshot(
                    semanticTags: localResult.semanticTags,
                    issues: localResult.audioIssues,
                    suggestions: [],
                    markers: [],
                    keptRanges: [fullRange],
                    keptTexts: [allText],
                    transcript: localResult.transcript,
                    wordTranscript: localResult.rawWordTranscript,
                    isTranscribeOnly: true
                )

                var manifest = try store.loadManifest()
                if let idx = manifest.media.firstIndex(where: { $0.id == record.id }) {
                    manifest.media[idx].copilot = snapshot
                    manifest.media[idx].status = .ready
                    try store.saveManifest(manifest)
                    anySucceeded = true
                }
            } catch {
                print("🔴 transcribeForDiarization failed for \(record.id): \(error)")
                // Best-effort revert so the clip doesn't look stuck.
                if var manifest = try? store.loadManifest(),
                   let idx = manifest.media.firstIndex(where: { $0.id == record.id }) {
                    manifest.media[idx].status = .ready
                    try? store.saveManifest(manifest)
                }
            }
        }

        isAnalyzing = false
        analysisProgress = nil
        await loadRecords()

        // Defensive pass for the (rare) case where the user manually
        // trimmed a slot before detection. `rebuildTimelineSegments`
        // keeps non-placeholder slots verbatim and won't re-derive
        // their subs from the freshly-saved transcript, so do it here.
        for segIdx in timelineSegments.indices {
            guard timelineSegments[segIdx].subtitles.isEmpty else { continue }
            let sid = timelineSegments[segIdx].sourceVideoID
            guard let record = records.first(where: { $0.id == sid }),
                  let transcript = record.copilot?.transcript else { continue }
            let subs = Self.buildSubtitleEntries(
                for: timelineSegments[segIdx].range,
                from: transcript,
                wordTranscript: record.copilot?.wordTranscript
            )
            if !subs.isEmpty {
                timelineSegments[segIdx].subtitles = subs
            }
        }
        rebuildComposedSubtitles()

        return anySucceeded
    }

    /// Pause-based speaker auto-detection. Cycles through `speakerCount`
    /// IDs whenever the gap between cues exceeds `pauseThreshold`. Good
    /// enough for two-person interview podcasts; users can rename the
    /// resulting speakers in the Inspector. Subtitles' speaker IDs are
    /// applied to both `composedSubtitles` and the underlying
    /// per-segment `SubtitleEntry` records so they survive a composition
    /// rebuild.
    /// Auto-assign speaker IDs using **real voice-timbre diarization**
    /// (sherpa-onnx pyannote + 3D-Speaker embeddings). On first use the
    /// required ~47 MB of model weights are downloaded to
    /// `~/Library/Application Support/cutti/models/sherpa/` — mirroring
    /// how the Qwen3-ASR sidecar ships. If the download hasn't happened yet or the
    /// real pipeline errors out (no audio track, unreadable file, etc.)
    /// we fall back to the legacy pause-based heuristic so the button
    /// always produces *some* answer.
    ///
    /// The diarizer decides the speaker count on its own via fast
    /// cosine-clustering of embeddings; `speakerCount` is now only
    /// consulted by the heuristic fallback.
    func autoDetectSpeakers(pauseThreshold: Double = 1.5, speakerCount: Int = 2) async {
        guard !composedSubtitles.isEmpty else {
            bannerMessage = L("Run analysis first — there are no subtitles to diarize.")
            return
        }

        let modelStore = SherpaModelStore.shared
        if !modelStore.isReady {
            do {
                try await modelStore.ensureReady()
            } catch {
                autoDetectSpeakersHeuristic(
                    pauseThreshold: pauseThreshold,
                    speakerCount: speakerCount
                )
                return
            }
        }

        let segMap = await runRealDiarizationForAllSources()

        if segMap.isEmpty {
            autoDetectSpeakersHeuristic(
                pauseThreshold: pauseThreshold,
                speakerCount: speakerCount
            )
            return
        }

        applyRealDiarization(segMap)
    }

    /// Run `RealSpeakerDiarizationService` once per unique source URL on
    /// a background queue. Returns `sourceVideoID → segments` in source
    /// time (empty for any source that fails; those are treated as
    /// "unknown speaker" and left untouched below).
    nonisolated private func runRealDiarizationForAllSources()
    async -> [UUID: [SherpaSpeakerSegment]] {
        let (sourceURLs, modelURLs): ([UUID: URL], (URL, URL)) = await MainActor.run {
            let pairs = Dictionary(uniqueKeysWithValues: self.records.map {
                ($0.id, URL(fileURLWithPath: $0.sourcePath))
            })
            return (
                pairs,
                (
                    SherpaModelStore.shared.segmentationModelPath,
                    SherpaModelStore.shared.embeddingModelPath
                )
            )
        }

        let sourceIDs: Set<UUID> = await MainActor.run {
            Set(self.timelineSegments.map { $0.sourceVideoID })
        }

        var out: [UUID: [SherpaSpeakerSegment]] = [:]
        for sid in sourceIDs {
            guard let url = sourceURLs[sid],
                  FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            do {
                let segs = try await RealSpeakerDiarizationService.run(
                    url: url,
                    models: (modelURLs.0, modelURLs.1)
                )
                out[sid] = segs
            } catch {
                print("🔴 RealSpeakerDiarization failed for \(sid): \(error)")
            }
        }
        return out
    }

    /// Commit `[sourceID: diarization]` onto timeline segments and
    /// composed cues. Runs on MainActor.
    ///
    /// - Parameter pushCheckpoint: when `true` (the default, used by the
    ///   manual "Auto-detect speakers" menu), pushes a dedicated undo
    ///   checkpoint. When called inline as part of an enclosing
    ///   pipeline (One-click first cut already pushes its own
    ///   checkpoint up-front), pass `false` so the diarization step
    ///   doesn't add a redundant entry the user would have to undo
    ///   twice to roll back.
    private func applyRealDiarization(
        _ segMap: [UUID: [SherpaSpeakerSegment]],
        pushCheckpoint: Bool = true
    ) {
        // Global speaker IDs across sources: base offset per source so
        // different sources don't collide. 16 is plenty of headroom.
        let sourceIDs = Array(segMap.keys).sorted { $0.uuidString < $1.uuidString }
        var baseOffsets: [UUID: Int] = [:]
        for (i, sid) in sourceIDs.enumerated() {
            baseOffsets[sid] = i * 16
        }

        if pushCheckpoint {
            pushRevision(label: "Auto-detect speakers", trigger: .userEdit(description: "diarize"))
        }

        for segIdx in timelineSegments.indices {
            let seg = timelineSegments[segIdx]
            guard let diarization = segMap[seg.sourceVideoID],
                  let base = baseOffsets[seg.sourceVideoID] else {
                continue
            }
            for subIdx in timelineSegments[segIdx].subtitles.indices {
                let entry = timelineSegments[segIdx].subtitles[subIdx]
                let srcStart = seg.range.startSeconds + entry.relativeStart
                let srcEnd = srcStart + entry.relativeDuration
                if let local = RealSpeakerDiarizationService.dominantSpeaker(
                    for: srcStart...srcEnd,
                    in: diarization
                ) {
                    timelineSegments[segIdx].subtitles[subIdx].speakerID = base + local
                }
            }
        }

        rebuildComposedSubtitles()
        speakers = applyNameOverrides(to: SpeakerDiarizer.registry(forCues: composedSubtitles))
    }

    /// One-click first cut hook: run real-model diarization on every
    /// timeline source and stamp speaker IDs onto the cues, so the
    /// transcript view shows distinct speakers as soon as analysis
    /// finishes (instead of forcing the user to find the manual
    /// "Auto-detect speakers" menu item afterwards).
    ///
    /// Best-effort: any failure (model not yet downloaded, network
    /// down, audio extraction fails) is logged and swallowed — the
    /// first cut still completes successfully without speaker labels,
    /// matching the legacy behavior.
    ///
    /// Does NOT push its own undo checkpoint: the enclosing first-cut
    /// flow already pushed one up-front, and a second checkpoint would
    /// force the user to undo twice to roll back.
    private func runDiarizationDuringFirstCut() async {
        guard !composedSubtitles.isEmpty else {
            print("🗣 [first-cut diarize] skipped: no composed subtitles yet")
            return
        }

        let modelStore = SherpaModelStore.shared
        if !modelStore.isReady {
            appendAnalysisAssistantLine(
                L("Downloading speaker model…"),
                icon: "person.2.wave.2",
                tone: .working,
                persist: true
            )
            do {
                try await modelStore.ensureReady()
            } catch {
                print("🗣 [first-cut diarize] skipped: model not ready (\(error))")
                return
            }
        }

        appendAnalysisAssistantLine(
            L("Identifying speakers"),
            icon: "person.2.wave.2",
            tone: .working,
            persist: true
        )

        let segMap = await runRealDiarizationForAllSources()
        guard !segMap.isEmpty else {
            print("🗣 [first-cut diarize] no segments produced; leaving cues unlabelled")
            return
        }

        applyRealDiarization(segMap, pushCheckpoint: false)

        let distinctSpeakers = Set(timelineSegments.flatMap { seg in
            seg.subtitles.compactMap(\.speakerID)
        }).count
        print("🗣 [first-cut diarize] applied — \(distinctSpeakers) distinct speaker(s) on \(timelineSegments.count) segment(s)")
    }

    /// Legacy pause-based heuristic, kept as a fallback when the real
    /// diarizer isn't available. Not exposed to the UI directly.
    private func autoDetectSpeakersHeuristic(pauseThreshold: Double, speakerCount: Int) {
        guard !composedSubtitles.isEmpty else {
            bannerMessage = L("Run analysis first — there are no subtitles to diarize.")
            return
        }

        let labelled = SpeakerDiarizer.assignAlternatingBySilence(
            cues: composedSubtitles,
            pauseThreshold: pauseThreshold,
            speakerCount: speakerCount
        )

        pushRevision(label: "Auto-detect speakers", trigger: .userEdit(description: "diarize"))

        // Update the source-of-truth SubtitleEntry rows so a future
        // rebuildComposedSubtitles() preserves the assignments.
        var idToSpeaker: [UUID: Int] = [:]
        for cue in labelled {
            if let sid = cue.speakerID { idToSpeaker[cue.id] = sid }
        }
        for segIdx in timelineSegments.indices {
            for subIdx in timelineSegments[segIdx].subtitles.indices {
                let entry = timelineSegments[segIdx].subtitles[subIdx]
                if let sid = idToSpeaker[entry.id] {
                    timelineSegments[segIdx].subtitles[subIdx].speakerID = sid
                }
            }
        }

        composedSubtitles = labelled
        speakers = applyNameOverrides(to: SpeakerDiarizer.registry(forCues: labelled))
        bannerMessage = L(speakers.count == 1 ? "Detected %d speaker." : "Detected %d speakers.", speakers.count)
    }

    // MARK: - Speaker name persistence

    /// Decode the on-disk `[String: String]` (Int IDs are JSON-friendly
    /// only as strings) into the in-memory `[Int: String]` map. Skips
    /// any keys that aren't valid integers so corrupt manifests don't
    /// poison the in-memory state.
    static func unpackSpeakerNames(_ raw: [String: String]?) -> [Int: String] {
        guard let raw else { return [:] }
        var out: [Int: String] = [:]
        for (k, v) in raw {
            if let id = Int(k) { out[id] = v }
        }
        return out
    }

    /// Inverse of `unpackSpeakerNames` for save.
    static func packSpeakerNames(_ map: [Int: String]) -> [String: String]? {
        guard !map.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (id, name) in map { out[String(id)] = name }
        return out
    }

    /// Decode the on-disk `[String: String]` color map into the
    /// in-memory `[Int: String]` keyed by speaker ID. Drops invalid keys.
    static func unpackSpeakerColors(_ raw: [String: String]?) -> [Int: String] {
        guard let raw else { return [:] }
        var out: [Int: String] = [:]
        for (k, v) in raw {
            if let id = Int(k) { out[id] = v }
        }
        return out
    }

    /// Inverse of `unpackSpeakerColors` for save.
    static func packSpeakerColors(_ map: [Int: String]) -> [String: String]? {
        guard !map.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (id, hex) in map { out[String(id)] = hex }
        return out
    }

    /// Decode the on-disk `[String: Double]` label-size map into the
    /// in-memory `[Int: Double]` keyed by speaker ID. Drops invalid keys.
    static func unpackSpeakerLabelSizes(_ raw: [String: Double]?) -> [Int: Double] {
        guard let raw else { return [:] }
        var out: [Int: Double] = [:]
        for (k, v) in raw {
            if let id = Int(k) { out[id] = v }
        }
        return out
    }

    /// Inverse of `unpackSpeakerLabelSizes` for save.
    static func packSpeakerLabelSizes(_ map: [Int: Double]) -> [String: Double]? {
        guard !map.isEmpty else { return nil }
        var out: [String: Double] = [:]
        for (id, size) in map { out[String(id)] = size }
        return out
    }

    /// Apply `speakerNames` / `speakerColors` / `speakerLabelSizes`
    /// overrides on top of a freshly built default registry so renamed,
    /// recolored, or resized speakers keep their custom identity across
    /// re-runs of diarization or composed-subtitle rebuilds.
    func applyNameOverrides(to registry: [Speaker]) -> [Speaker] {
        guard !speakerNames.isEmpty
            || !speakerColors.isEmpty
            || !speakerLabelSizes.isEmpty
        else { return registry }
        return registry.map { sp in
            var copy = sp
            if let custom = speakerNames[sp.id], !custom.isEmpty {
                copy.displayName = custom
            }
            if let hex = speakerColors[sp.id], let color = Color(hex: hex) {
                copy.color = color
            }
            if let size = speakerLabelSizes[sp.id] {
                copy.labelSize = size
            }
            return copy
        }
    }

    /// Rename a speaker. Updates the in-memory registry, the
    /// `speakerNames` override map, and persists to the manifest. Empty
    /// or whitespace-only names are treated as "reset to default".
    func renameSpeaker(id: Int, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakerNames.removeValue(forKey: id)
        } else {
            speakerNames[id] = trimmed
        }
        speakers = rebuildSpeakerRegistry(forCues: composedSubtitles)
        guard let store = self.store else { return }
        do {
            var manifest = try store.loadManifest()
            manifest.speakerNames = Self.packSpeakerNames(speakerNames)
            try store.saveManifest(manifest)
        } catch {
            bannerMessage = L("Could not save speaker name: %@", error.localizedDescription)
        }
    }

    /// Recolor a speaker. Hex string `#RRGGBB`; pass nil/empty to reset
    /// to the palette default. Persists to the manifest.
    func recolorSpeaker(id: Int, to hex: String?) {
        let trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty, Color(hex: trimmed) != nil {
            speakerColors[id] = trimmed
        } else {
            speakerColors.removeValue(forKey: id)
        }
        speakers = rebuildSpeakerRegistry(forCues: composedSubtitles)
        guard let store = self.store else { return }
        do {
            var manifest = try store.loadManifest()
            manifest.speakerColors = Self.packSpeakerColors(speakerColors)
            try store.saveManifest(manifest)
        } catch {
            bannerMessage = L("Could not save speaker color: %@", error.localizedDescription)
        }
    }

    /// Resize a speaker's on-video label. `size` is in points; pass
    /// `nil` to reset to the renderer default. Persists to the manifest.
    func resizeSpeakerLabel(id: Int, to size: Double?) {
        if let size, size > 0 {
            speakerLabelSizes[id] = size
        } else {
            speakerLabelSizes.removeValue(forKey: id)
        }
        speakers = rebuildSpeakerRegistry(forCues: composedSubtitles)
        guard let store = self.store else { return }
        do {
            var manifest = try store.loadManifest()
            manifest.speakerLabelSizes = Self.packSpeakerLabelSizes(speakerLabelSizes)
            try store.saveManifest(manifest)
        } catch {
            bannerMessage = L("Could not save speaker label size: %@", error.localizedDescription)
        }
    }

    /// Reassign the speaker label of one or more transcript cues. Used
    /// by the transcript right-click menu when diarization mislabeled a
    /// segment (or didn't run at all). All matching cues are mutated in
    /// a single revision so undo treats the reassignment as one step.
    /// Pass `speakerID = nil` to clear the assignment.
    func setSpeakerForCues(ids: [UUID], speakerID: Int?) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        var didChange = false
        for segIndex in timelineSegments.indices {
            for subIndex in timelineSegments[segIndex].subtitles.indices {
                let entry = timelineSegments[segIndex].subtitles[subIndex]
                guard idSet.contains(entry.id) else { continue }
                guard entry.speakerID != speakerID else { continue }
                if !didChange {
                    pushRevision(
                        label: "Reassign speaker",
                        trigger: .userEdit(description: "reassign-speaker")
                    )
                    didChange = true
                }
                timelineSegments[segIndex].subtitles[subIndex].speakerID = speakerID
            }
        }
        if didChange {
            rebuildComposedSubtitles()
        }
    }

    /// Allocate the next free speaker ID and assign it to the given
    /// cues. The new ID is `(max existing speakerID across cues) + 1`,
    /// so the registry rebuild surfaces it as the next "Speaker N+1".
    /// Returns the assigned ID for callers that want to log it.
    @discardableResult
    func assignNewSpeakerToCues(ids: [UUID]) -> Int? {
        guard !ids.isEmpty else { return nil }
        let existing = composedSubtitles.compactMap(\.speakerID)
        let newID = (existing.max() ?? -1) + 1
        setSpeakerForCues(ids: ids, speakerID: newID)
        return newID
    }

    /// Build the speaker registry for a set of cues, layering user
    /// renames on top. When cues exist but none have a speakerID
    /// (diarization hasn't been run), synthesize a single default
    /// `Speaker(id: 0)` so the transcript view always has a real
    /// avatar+name to render — and so renaming it persists across
    /// rebuilds even though no cue carries the ID yet.
    func rebuildSpeakerRegistry(forCues cues: [ComposedSubtitle]) -> [Speaker] {
        let detected = SpeakerDiarizer.registry(forCues: cues)
        if detected.isEmpty && !cues.isEmpty {
            return applyNameOverrides(to: [
                Speaker(
                    id: 0,
                    displayName: Speaker.defaultName(for: 0),
                    color: Speaker.defaultColor(for: 0)
                )
            ])
        }
        return applyNameOverrides(to: detected)
    }

    // MARK: - B-roll suggestions

    /// Hint projected onto composed-timeline coordinates. Produced on
    /// demand from the union of all records' stored suggestions; any
    /// suggestion anchored to source time that's been cut out of the
    /// current edit resolves to a nil composed time and is simply not
    /// rendered.
    struct BRollSuggestionHint: Identifiable, Equatable {
        let id: UUID
        let sourceVideoID: UUID
        /// Anchor position on the composed timeline (mid-point of the
        /// suggestion's source range projected forward).
        let composedSeconds: Double
        /// Length of the speaker's anchor window (sourceEnd − sourceStart)
        /// in source seconds. Used as the default `durationSeconds` for
        /// sequence-style overlays so the animation's runtime mirrors
        /// how long the speaker spent on the topic.
        let anchorDurationSeconds: Double
        let kind: BRollSuggestion.Kind
        let prompt: String
        let rationale: String
        /// Crisp ≤20-char card title in the transcript's language.
        /// `nil` for legacy suggestions persisted before the field was
        /// introduced.
        let userTitle: String?
        /// Per-kind structured signal forwarded to the downstream
        /// overlay agent (e.g. an enumeration's quartile splits).
        /// `nil` for legacy suggestions or when the LLM didn't supply
        /// one.
        let agentHint: String?
        /// Phase-1 section role (intro/thesis/enumeration/process/...)
        /// driving deterministic template routing in
        /// `buildOverlayInstruction`. `nil` for legacy suggestions.
        let sectionRole: String?
    }

    /// Union of every record's non-dismissed B-roll suggestion,
    /// projected onto composed time. Recomputed on access because the
    /// set of suggestions and the composed index rarely both change
    /// faster than once a second.
    var bRollSuggestionHints: [BRollSuggestionHint] {
        records.flatMap { record -> [BRollSuggestionHint] in
            (record.copilot?.bRollSuggestions ?? [])
                .filter { !$0.isDismissed }
                .compactMap { s in
                    let mid = (s.sourceStartSeconds + s.sourceEndSeconds) / 2
                    guard let composed = composedIndex.toComposedTime(
                        sourceVideoID: s.sourceVideoID,
                        sourceTime: mid
                    ) else { return nil }
                    return BRollSuggestionHint(
                        id: s.id,
                        sourceVideoID: s.sourceVideoID,
                        composedSeconds: composed,
                        anchorDurationSeconds: max(0, s.sourceEndSeconds - s.sourceStartSeconds),
                        kind: s.kind,
                        prompt: s.prompt,
                        rationale: s.rationale,
                        userTitle: s.userTitle,
                        agentHint: s.agentHint,
                        sectionRole: s.sectionRole
                    )
                }
        }
        .sorted { $0.composedSeconds < $1.composedSeconds }
    }

    /// Turn a B-roll suggestion into a concrete Remotion-rendered
    /// overlay. Today we only have the `ChapterTitle` template, so
    /// suggestions of any kind are mapped to a chapter-card with the
    /// suggestion prompt as the title text. As more templates land
    /// (chart, lower-third, animated icon…) the mapping here picks
    /// the best fit per `BRollSuggestion.Kind`.
    ///
    /// The resulting overlay lands at the suggestion's already-projected
    /// composed time (the strip computes it via `ComposedTimelineIndex`
    /// so it stays anchored to the source sentence even after re-cuts).
    func generateOverlayFromSuggestion(
        _ hint: TimelineCreativeActions.BRollSuggestionHint,
        editedPrompt: String? = nil
    ) {
        // BYOK gate. Without this, an animation hint that somehow
        // survives the strip-level filter (older serialized hint, race
        // between settings change and UI refresh, hand-typed tool call,
        // etc.) would still scaffold a long agent prompt and burn a
        // chat turn before the runtime gate rejects the resulting
        // generate_overlay tool call.
        if CuttiSettings.aiProvider() == .custom {
            switch hint.kind {
            case .image, .chart, .mapGraphic, .dataTable, .screenRecording:
                // Image generation still works in BYOK (uses the user's
                // own image API). Fall through to the normal path.
                break
            case .animation, .other:
                bannerMessage = L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud.")
                return
            }
        }

        // Treat the user's textfield edit as authoritative when it
        // genuinely differs from the popover seed (`userTitle` joined
        // with `prompt`, mirroring `BRollSuggestionStrip.popoverBody`).
        // If they kept the seed, cleared the field, or didn't pass an
        // edit at all, fall back to the existing transcript-driven
        // extraction. The two cases drive very different agent
        // instructions below — edited → the user's words are the
        // source of truth for screen text; not-edited → the transcript
        // drives item labels and the suggestion is just inspiration.
        let trimmedEdit = editedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let popoverSeed: String = {
            let headline = (hint.userTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = hint.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !headline.isEmpty, !body.isEmpty, headline != body {
                return "\(headline)\n\n\(body)"
            }
            return headline.isEmpty ? body : headline
        }()
        let userDidEdit: Bool = {
            guard let e = trimmedEdit, !e.isEmpty else { return false }
            return e != popoverSeed
        }()
        let rawPrompt = (trimmedEdit?.isEmpty == false ? trimmedEdit : nil)
            ?? hint.prompt

        // Image-like suggestions route through the FLUX image service
        // rather than the Remotion ChapterTitle template. The still is
        // dropped onto a new overlay track at the suggestion's composed
        // time for 4s (Final Cut still default).
        switch hint.kind {
        case .image, .chart, .mapGraphic, .dataTable, .screenRecording:
            Task {
                await generateAIImageAndInsertOverlay(
                    prompt: rawPrompt,
                    size: .landscape,
                    at: hint.composedSeconds,
                    duration: 4.0
                )
            }
            return
        case .animation, .other:
            // Server-authoritative animation compose path.
            //
            // Stage-2 already produced clean structured signals
            // (`userTitle`, `agentHint`, `sectionRole`). We forward
            // those — plus the spoken transcript window in this anchor —
            // as a `ComposeBrief` to `/v1/agents/animation/compose`.
            // The relay-side AnimationSkill picks the template, fills
            // the props, and runs a server-side validator loop. We
            // never assemble template-picking instructions on the
            // client anymore — the skill is the sole authority.
            //
            // The local Qwen3-ASR sidecar (or Apple Speech fallback)
            // already persists word-level timestamps on
            // `record.copilot?.wordTranscript` (each `TranscriptSegment`
            // is ≈ one spoken word). We bucket those into ~1.5s phrases
            // because sentence-level subtitles are too coarse — a
            // single breath enumerating "first X, second Y, third Z"
            // is usually one cue, which gives the agent no temporal
            // information about when to show each item.
            var anchorDuration = max(1.0, hint.anchorDurationSeconds)
            var cues: [ComposeBrief.TranscriptCue] = []
            for record in records {
                guard let sugg = (record.copilot?.bRollSuggestions ?? [])
                    .first(where: { $0.id == hint.id }) else { continue }
                let src0 = sugg.sourceStartSeconds
                let src1 = sugg.sourceEndSeconds
                anchorDuration = max(1.0, src1 - src0)
                let words = record.copilot?.wordTranscript ?? []
                if !words.isEmpty {
                    cues = Self.buildWordBucketCues(
                        words: words,
                        windowStart: src0,
                        windowEnd: src1
                    )
                } else {
                    // Fallback to composed-subtitle cues centered on
                    // the hint when there's no word-level data.
                    let half = anchorDuration / 2.0
                    let ws = max(0, hint.composedSeconds - half)
                    let we = hint.composedSeconds + half
                    cues = composedSubtitles
                        .filter { $0.endSeconds >= ws && $0.startSeconds <= we }
                        .compactMap { cue -> ComposeBrief.TranscriptCue? in
                            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return nil }
                            let off = max(0.0, min(anchorDuration, cue.startSeconds - ws))
                            return ComposeBrief.TranscriptCue(relativeSec: off, text: text)
                        }
                }
                break
            }

            let isEnglish = Self.currentAppLanguageIsEnglish()
            // The brief's `language` controls what language the
            // animation copy is generated in (heading / labels / etc).
            // It must reflect the SOURCE audio's language so visuals
            // match what the speaker actually said — not the editor's
            // UI language. A Chinese speaker who switched their app
            // to English still wants Chinese overlays on a Chinese
            // recording, and vice versa.
            //
            // Detect language from the highest-signal source we have:
            // userTitle + agentHint (Stage-1 produces these in the
            // source language) + a sample of transcript text.
            let signalForLang = [
                hint.userTitle ?? "",
                hint.agentHint ?? "",
                cues.prefix(3).map(\.text).joined(separator: " "),
            ].joined(separator: " ")
            let sourceIsCJK = Self.textIsPredominantlyCJK(signalForLang)
            let briefLanguage: ComposeBrief.Language = sourceIsCJK ? .zh : .en

            // User-facing bubble text. Shows only what the user can
            // (and did) edit — never the full brief payload.
            let suggestionDisplayText: String = {
                let body = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if isEnglish {
                    return body.isEmpty ? "Generate animation" : "Generate animation: \(body)"
                } else {
                    return body.isEmpty ? "生成动画" : "生成动画：\(body)"
                }
            }()

            // Pull (and bump) this suggestion's attempt counter. The
            // first click on a suggestion is attempt=1 (deterministic
            // pass with no variation hint). Subsequent clicks bump to
            // 2/3/… and forward the prior takes' summaries so the
            // server can deliberately produce a different valid take.
            // We bump BEFORE building the brief so attempt=1 maps to
            // a virgin click, not "after one prior render".
            //
            // We never bump when the user typed a fresh edit — a
            // userEdit IS a different brief, no need to nudge the
            // model toward variance, and bumping would reset the
            // headline list against an unrelated baseline.
            let suggestionID = hint.id
            var history = composeAttemptHistory[suggestionID] ?? ComposeAttemptHistory()
            if !userDidEdit {
                history.count += 1
            } else {
                // A user-edited brief is treated as a fresh first
                // pass; clear the previous-attempts list so the LLM
                // isn't told to avoid headlines that no longer
                // describe what the user wants.
                history.count = 1
                history.summaries = []
            }
            composeAttemptHistory[suggestionID] = history
            let attempt = history.count
            let previousAttempts =
                attempt > 1 && !history.summaries.isEmpty ? history.summaries : nil

            let brief = ComposeBrief(
                language: briefLanguage,
                section: ComposeBrief.Section(
                    composedTime: hint.composedSeconds,
                    durationSec: anchorDuration,
                    role: hint.sectionRole ?? "other",
                    userTitle: hint.userTitle,
                    agentHint: hint.agentHint,
                    rationale: hint.rationale,
                    userEdit: userDidEdit ? trimmedEdit : nil
                ),
                transcriptWindow: cues,
                attempt: attempt,
                previousAttempts: previousAttempts
            )

            let working = isEnglish ? "Composing animation…" : "正在挑模板…"
            let bubbleID = beginPresetActionChat(
                userAction: suggestionDisplayText,
                working: working,
                icon: "wand.and.stars"
            )

            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.composeAnimationViaRelay(brief: brief)
                    print("🎬 [compose] template=\(result.template_id) iters=\(result.iterations) duration=\(result.duration_seconds)s")
                    // Record this successful take so a *subsequent*
                    // click on the same suggestion can tell the
                    // server "don't repeat this headline". We extract
                    // the most identifying screen text from props
                    // (heading / first item label / quote) up to 80
                    // chars — that's what the user will visually
                    // recognize as "the same one".
                    let headline = Self.extractComposeHeadline(
                        templateID: result.template_id,
                        propsJSON: result.props_json
                    )
                    var updated = self.composeAttemptHistory[suggestionID]
                        ?? ComposeAttemptHistory(count: attempt, summaries: [])
                    updated.summaries.append(
                        ComposeBrief.PreviousAttemptSummary(
                            template_id: result.template_id,
                            headline: headline
                        )
                    )
                    if updated.summaries.count > 3 {
                        updated.summaries.removeFirst(updated.summaries.count - 3)
                    }
                    self.composeAttemptHistory[suggestionID] = updated
                    if let err = await self.generateOverlay(
                        templateID: result.template_id,
                        propsJSON: result.props_json,
                        durationSeconds: result.duration_seconds,
                        at: hint.composedSeconds
                    ) {
                        let msg = isEnglish
                            ? "Animation generation failed: \(err.localizedDescription)"
                            : "动画生成失败：\(err.localizedDescription)"
                        self.finishPresetActionChat(
                            id: bubbleID,
                            text: msg,
                            tone: .failure,
                            icon: "exclamationmark.triangle.fill"
                        )
                        self.bannerMessage = msg
                        return
                    }
                    let okMsg = isEnglish
                        ? "Generated \(result.template_id) overlay"
                        : "已生成 \(result.template_id) 动画"
                    self.finishPresetActionChat(
                        id: bubbleID,
                        text: okMsg,
                        tone: .success,
                        icon: "checkmark.circle.fill"
                    )
                } catch {
                    let msg: String = (error as? AnimationComposeError)?.errorDescription
                        ?? error.localizedDescription
                    print("🎬 [compose] failed: \(msg)")
                    // Roll back the attempt bump so the user's NEXT
                    // click is treated as a fresh attempt rather than
                    // counting this transport/decode failure as a
                    // "prior take to vary from". We don't append to
                    // summaries on failure (there's no headline to
                    // reference), but we do need to undo the count++
                    // we did before sending the request.
                    var rolled = self.composeAttemptHistory[suggestionID]
                        ?? ComposeAttemptHistory()
                    if rolled.count > 0 { rolled.count -= 1 }
                    self.composeAttemptHistory[suggestionID] = rolled
                    self.finishPresetActionChat(
                        id: bubbleID,
                        text: msg,
                        tone: .failure,
                        icon: "exclamationmark.triangle.fill"
                    )
                    self.bannerMessage = msg
                }
            }
            return
        }

        // (unreachable now — both kinds handled above.)
    }

    /// Pulls the most identifying screen text out of a compose result
    /// so it can be cited in the next regeneration's "don't repeat"
    /// list. Tries (in order): `heading`, the first `items[].label`,
    /// `quote`, `title`, then any first string field. Capped to ~80
    /// chars so a long heading + several items list stays compact in
    /// the prompt. Returns "(no headline)" only if everything fails.
    private static func extractComposeHeadline(
        templateID: String,
        propsJSON: String
    ) -> String {
        guard let data = propsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "(no headline)" }
        let preferredKeys = ["heading", "title", "tagline", "quote", "label", "appName", "agentName", "assistantName", "repoName"]
        for key in preferredKeys {
            if let v = obj[key] as? String, !v.isEmpty {
                return String(v.prefix(80))
            }
        }
        if let items = obj["items"] as? [[String: Any]],
           let first = items.first,
           let label = first["label"] as? String, !label.isEmpty {
            return String(label.prefix(80))
        }
        if let userPrompt = obj["userPrompt"] as? String, !userPrompt.isEmpty {
            return String(userPrompt.prefix(80))
        }
        if let userMessage = obj["userMessage"] as? String, !userMessage.isEmpty {
            return String(userMessage.prefix(80))
        }
        return "(no headline)"
    }

    /// Context stashed by `generateOverlayFromSuggestion` so the
    /// `generate_overlay` tool handler can verify the agent's response
    /// matches the speaker's anchor window. Cleared on successful
    /// overlay render; also self-expires so a hand-typed generate_overlay
    /// from a much later chat turn isn't retroactively validated.
    struct PendingOverlayAnchor: Equatable {
        let anchorDurationSeconds: Double
        let expiresAt: Date
    }

    /// Build a fresh `AnimationComposeClient` from the live relay
    /// credentials and POST the brief. Returns the server's
    /// `template_id` + `props_json` + `duration_seconds` choice,
    /// which the caller hands straight to `generateOverlay(...)`.
    /// Throws an `AnimationComposeError` (or rethrows) on failure.
    private func composeAnimationViaRelay(
        brief: ComposeBrief
    ) async throws -> ComposeResult {
        guard let url = URL(string: RelayClient.relayBaseURL) else {
            throw AnimationComposeError.transport("Invalid relay base URL.")
        }
        let jwt = RelaySession.currentBearerToken() ?? ""
        let dev = UserDefaults.standard.string(forKey: "cutti_relay_dev_token") ?? ""
        let token: String
        if !jwt.isEmpty {
            token = "jwt:\(jwt)"
        } else if !dev.isEmpty {
            token = "dev:\(dev)"
        } else {
            // No credentials -> surface the same banner copy as the
            // BYOK gate. The compose endpoint requires auth and would
            // 401 anyway; failing fast here avoids a useless round-trip.
            throw AnimationComposeError.relayMessage(
                L("Sign in to Cutti Cloud to generate animated overlays.")
            )
        }
        let client = AnimationComposeClient(
            relayBaseURL: url,
            bearerToken: token
        )
        return try await client.compose(brief)
    }

    /// Group word-level `TranscriptSegment`s (each ~= one spoken word)
    /// inside [windowStart, windowEnd] into short phrases with a start
    /// offset relative to `windowStart`. A new phrase starts when
    /// either the accumulated phrase crosses ~1.5s or there is a
    /// silence gap > 0.4s between adjacent words. Output is a list of
    /// `ComposeBrief.TranscriptCue` ready to embed in a brief.
    private static func buildWordBucketCues(
        words: [TranscriptSegment],
        windowStart: Double,
        windowEnd: Double
    ) -> [ComposeBrief.TranscriptCue] {
        let inWindow = words
            .filter { $0.startSeconds >= windowStart && $0.startSeconds <= windowEnd }
            .sorted { $0.startSeconds < $1.startSeconds }
        if inWindow.isEmpty { return [] }

        struct Bucket { var startOffset: Double; var text: String; var lastEnd: Double }
        var buckets: [Bucket] = []
        let maxDuration = 1.5
        let maxGap = 0.4

        for w in inWindow {
            let offset = w.startSeconds - windowStart
            if var last = buckets.last {
                let gap = w.startSeconds - last.lastEnd
                let bucketDur = w.startSeconds - (windowStart + last.startOffset)
                if gap > maxGap || bucketDur > maxDuration {
                    buckets.append(Bucket(
                        startOffset: offset,
                        text: w.text,
                        lastEnd: w.endSeconds
                    ))
                } else {
                    // Per-word segments from local ASR don't carry trailing
                    // spaces, so naive concatenation collapses
                    // "We actually use" into "Weactuallyuse" and the
                    // LLM loses every word boundary. Insert a space
                    // when joining two Latin tokens; CJK characters
                    // don't need spaces.
                    let prevTrim = last.text
                    let nextTrim = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prevTrim.isEmpty && !nextTrim.isEmpty
                        && Self.shouldInsertJoinSpace(prev: prevTrim, next: nextTrim) {
                        last.text = prevTrim + " " + nextTrim
                    } else {
                        last.text = prevTrim + nextTrim
                    }
                    last.lastEnd = w.endSeconds
                    buckets[buckets.count - 1] = last
                }
            } else {
                buckets.append(Bucket(
                    startOffset: offset,
                    text: w.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    lastEnd: w.endSeconds
                ))
            }
        }
        return buckets.map { b in
            ComposeBrief.TranscriptCue(
                relativeSec: b.startOffset,
                text: b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Decide whether two adjacent ASR word tokens need a space when
    /// concatenated. CJK tokens (Han, Hiragana, Katakana, Hangul)
    /// concatenate without a space — Asian writing systems don't use
    /// inter-word whitespace. Latin / Cyrillic / Greek tokens do.
    /// Punctuation on either edge skips the separator (matches how
    /// natural orthography reads "word, next" → "word," + " " + "next").
    private static func shouldInsertJoinSpace(prev: String, next: String) -> Bool {
        guard let last = prev.unicodeScalars.last,
              let first = next.unicodeScalars.first else { return false }
        if last.properties.isWhitespace || first.properties.isWhitespace { return false }
        if Self.isCJKScalar(last) || Self.isCJKScalar(first) { return false }
        // Skip the separator if either edge is punctuation that
        // already implies a boundary (e.g. "Hello," + "world").
        let punct = CharacterSet.punctuationCharacters
        if first.value <= 0x10FFFF, punct.contains(first) { return false }
        return true
    }

    private static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        // CJK Unified Ideographs + Extension A + B + C + D + E + F
        if (0x3400...0x4DBF).contains(v) { return true }
        if (0x4E00...0x9FFF).contains(v) { return true }
        if (0x20000...0x2A6DF).contains(v) { return true }
        if (0x2A700...0x2EBEF).contains(v) { return true }
        // Hiragana + Katakana
        if (0x3040...0x30FF).contains(v) { return true }
        // Hangul Syllables + Jamo
        if (0xAC00...0xD7AF).contains(v) { return true }
        if (0x1100...0x11FF).contains(v) { return true }
        // CJK Symbols and Punctuation, Halfwidth and Fullwidth Forms
        if (0x3000...0x303F).contains(v) { return true }
        if (0xFF00...0xFFEF).contains(v) { return true }
        return false
    }

    /// `true` when more than ~30% of the letter-bearing scalars are
    /// CJK. We bias toward CJK because mixed bilingual content
    /// ("接入 Event Hub SDK") still wants Chinese-language output —
    /// a single Latin technical term in an otherwise Chinese sentence
    /// shouldn't flip the entire animation copy to English.
    private static func textIsPredominantlyCJK(_ s: String) -> Bool {
        var cjk = 0
        var latin = 0
        for scalar in s.unicodeScalars {
            if Self.isCJKScalar(scalar) {
                cjk += 1
            } else if scalar.properties.isAlphabetic {
                latin += 1
            }
        }
        let total = cjk + latin
        guard total > 0 else { return false }
        return Double(cjk) / Double(total) >= 0.30
    }

    /// Mark a suggestion as dismissed. Persists so it doesn't come back
    /// on reload. Silently no-ops if the id isn't found (user dismissed
    /// an already-gone suggestion, or id is stale across sessions).
    func dismissBRollSuggestion(id: UUID) {
        // Drop any compose history for this id so a future
        // re-spawned suggestion (Stage-1 may regenerate) starts at
        // attempt=1 with no "previous take" baggage.
        composeAttemptHistory.removeValue(forKey: id)
        guard let store else { return }
        do {
            var manifest = try store.loadManifest()
            var mutated = false
            for mIdx in manifest.media.indices {
                guard var suggestions = manifest.media[mIdx].copilot?.bRollSuggestions else { continue }
                guard let sIdx = suggestions.firstIndex(where: { $0.id == id }) else { continue }
                suggestions[sIdx].isDismissed = true
                manifest.media[mIdx].copilot?.bRollSuggestions = suggestions
                mutated = true
                break
            }
            if mutated {
                try store.saveManifest(manifest)
                Task { await loadRecords() }
            }
        } catch {
            print("⚠️ dismissBRollSuggestion failed: \(error)")
        }
    }

    /// Kick off the LLM-backed B-roll suggestion pass for `recordID`.
    /// Non-fatal: any failure (no OpenAI config, LLM error, empty
    /// transcript) leaves `record.copilot.bRollSuggestions` unchanged.
    /// Safe to call from any flow — the analysis pipeline calls it
    /// automatically, and an agent tool can call it to refresh.
    func refreshBRollSuggestions(
        for recordID: UUID,
        keptTranscript: [TranscriptSegment],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async {
        guard let store, !keptTranscript.isEmpty else { return }
        guard let config = OpenAIConfiguration.fromEnvironment() else {
            // No API key configured → stay silent. The feature is
            // additive; users without a key never paid for it.
            return
        }

        let service = BRollSuggestionService(
            client: OpenAIClient(configuration: config),
            onProgress: onProgress
        )
        let suggestions = await service.suggest(
            keptSegments: keptTranscript,
            sourceVideoID: recordID
        )

        do {
            var manifest = try store.loadManifest()
            guard let idx = manifest.media.firstIndex(where: { $0.id == recordID }) else { return }
            manifest.media[idx].copilot?.bRollSuggestions = suggestions
            try store.saveManifest(manifest)
            await loadRecords()
            if !suggestions.isEmpty {
                bannerMessage = "\(suggestions.count) B-roll suggestion\(suggestions.count == 1 ? "" : "s") ready above the timeline."
            }
        } catch {
            print("⚠️ refreshBRollSuggestions persist failed: \(error)")
        }
    }

    /// Parses a leading emoji from a tool-produced user summary and
    /// maps it to an SF Symbol + tone, returning the remaining text
    /// with the emoji stripped. Keeps tool callsites emoji-free at the
    /// chat-bubble render stage without having to refactor every
    /// AgentToolOutcome call. Unknown or missing prefixes return
    /// (original, nil, nil).
    static func extractLeadingIcon(
        from summary: String
    ) -> (String, String?, EditorChatMessage.IconTone?) {
        // Table of leading tokens we emit from tool sites. Order
        // matters — multi-codepoint tokens like "⚠️" must match before
        // shorter variants.
        let table: [(String, String, EditorChatMessage.IconTone)] = [
            ("⚠️",  "exclamationmark.triangle.fill", .warning),
            ("❌",   "xmark.octagon.fill",            .failure),
            ("✅",   "checkmark.seal.fill",           .success),
            ("⚡",   "bolt.fill",                     .neutral),
            ("✨",   "sparkles",                      .working),
            ("🔍",   "magnifyingglass",               .neutral),
            ("🎬",   "film",                          .neutral),
            ("🎞️", "film.stack",                    .neutral),
            ("🎙️", "waveform",                      .neutral),
            ("🎤",   "mic.fill",                      .neutral),
            ("🔊",   "speaker.wave.2.fill",           .neutral),
            ("🤖",   "sparkles",                      .neutral),
            ("📝",   "square.and.pencil",             .neutral),
            ("📦",   "shippingbox.fill",              .neutral),
            ("🎯",   "target",                        .neutral),
            ("⏳",   "hourglass",                     .neutral),
            ("💡",   "lightbulb.fill",                .neutral),
        ]
        for (token, icon, tone) in table where summary.hasPrefix(token) {
            let tail = summary.dropFirst(token.count)
            let trimmed = tail.drop(while: { $0 == " " })
            return (String(trimmed), icon, tone)
        }
        return (summary, nil, nil)
    }

    /// Pull the subset of a source transcript that overlaps any of the
    /// given kept ranges. Used by the pipeline callsite to hand the
    /// LLM just the sentences that survived the first cut.
    static func transcriptSegmentsFor(
        ranges: [TimeRange],
        transcript: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        transcript.filter { seg in
            ranges.contains { r in
                seg.endSeconds > r.startSeconds && seg.startSeconds < r.endSeconds
            }
        }
    }


    /// Set playback speed for a segment (1.0 = normal, 2.0 = 2x faster).
    func setSegmentSpeed(at index: Int, rate: Double) {
        applySpeed(rate, to: IndexSet(integer: index), label: "Change speed")
    }

    /// Set playback speed for all currently selected segments.
    func setSelectedSegmentsSpeed(_ rate: Double) {
        let indexes = selectedSegmentIndices
        guard !indexes.isEmpty else { return }
        let label = indexes.count == 1
            ? "Change speed"
            : "Change speed for \(indexes.count) segments"
        applySpeed(rate, to: indexes, label: label)
    }

    private func applySpeed(_ rate: Double, to indexes: IndexSet, label: String) {
        let validIndexes = indexes.filter { $0 >= 0 && $0 < timelineSegments.count }
        guard !validIndexes.isEmpty else { return }

        let clamped = max(TimelineSegment.minimumSpeedRate, min(rate, TimelineSegment.maximumSpeedRate))
        let hasChange = validIndexes.contains { abs(timelineSegments[$0].normalizedSpeedRate - clamped) > 0.001 }
        guard hasChange else { return }

        pushRevision(label: label, trigger: .userEdit(description: "speed"))
        for index in validIndexes {
            timelineSegments[index].speedRate = clamped
        }
        rebuildComposition()
    }

    // MARK: - Segment Effects

    /// Rotate the segment by 90° clockwise.
    func rotateSegment(at index: Int) {
        guard index >= 0, index < timelineSegments.count else { return }
        pushRevision(label: "Rotate segment", trigger: .userEdit(description: "rotate"))
        timelineSegments[index].effects.rotation = (timelineSegments[index].effects.rotation + 90) % 360
        rebuildComposition()
    }

    /// Flip the segment horizontally.
    func flipSegmentHorizontal(at index: Int) {
        guard index >= 0, index < timelineSegments.count else { return }
        pushRevision(label: "Flip horizontal", trigger: .userEdit(description: "flip"))
        timelineSegments[index].effects.flipHorizontal.toggle()
        rebuildComposition()
    }

    /// Flip the segment vertically.
    func flipSegmentVertical(at index: Int) {
        guard index >= 0, index < timelineSegments.count else { return }
        pushRevision(label: "Flip vertical", trigger: .userEdit(description: "flip"))
        timelineSegments[index].effects.flipVertical.toggle()
        rebuildComposition()
    }

    /// Set color adjustments for a segment.
    func setSegmentColor(at index: Int, brightness: Double? = nil, contrast: Double? = nil, saturation: Double? = nil) {
        guard index >= 0, index < timelineSegments.count else { return }
        pushRevision(label: "Adjust color", trigger: .userEdit(description: "color"))
        if let b = brightness { timelineSegments[index].effects.brightness = max(-1, min(1, b)) }
        if let c = contrast { timelineSegments[index].effects.contrast = max(0, min(2, c)) }
        if let s = saturation { timelineSegments[index].effects.saturation = max(0, min(2, s)) }
        rebuildComposition()
    }

    /// Set audio fade durations for a segment.
    func setSegmentAudioFade(at index: Int, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        guard index >= 0, index < timelineSegments.count else { return }
        let maxFade = timelineSegments[index].durationSeconds / 2
        pushRevision(label: "Audio fade", trigger: .userEdit(description: "fade"))
        if let fi = fadeIn { timelineSegments[index].effects.audioFadeInDuration = max(0, min(maxFade, fi)) }
        if let fo = fadeOut { timelineSegments[index].effects.audioFadeOutDuration = max(0, min(maxFade, fo)) }
        rebuildComposition()
    }

    /// Reset all effects on a segment to defaults.
    func resetSegmentEffects(at index: Int) {
        guard index >= 0, index < timelineSegments.count else { return }
        guard !timelineSegments[index].effects.isDefault else { return }
        pushRevision(label: "Reset effects", trigger: .userEdit(description: "reset"))
        timelineSegments[index].effects = .default
        rebuildComposition()
    }

    /// Set playback speed rate.
    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        if let player, player.rate != 0 {
            player.rate = Float(rate)
        }
    }

    /// Toggle loop playback on/off.
    func toggleLoop() {
        isLooping.toggle()
        player?.actionAtItemEnd = isLooping ? .none : .pause
        if isLooping {
            installLoopObserver()
        } else {
            removeLoopObserver()
        }
    }

    /// Loop-end observer token. Stored so we can remove the observation
    /// before installing a fresh one — without this, toggling loop or
    /// rebuilding the composition (which swaps `player`) accumulated
    /// observers tied to stale `AVPlayerItem`s and fired multiple
    /// `seek(to: .zero)` + `playImmediately` calls per end-of-item.
    private var loopObserver: NSObjectProtocol?

    private func installLoopObserver() {
        guard isLooping else { return }
        removeLoopObserver()
        guard let item = player?.currentItem else { return }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isLooping else { return }
                self.player?.seek(to: .zero)
                self.player?.playImmediately(atRate: Float(self.playbackRate))
            }
        }
    }

    private func removeLoopObserver() {
        if let token = loopObserver {
            NotificationCenter.default.removeObserver(token)
            loopObserver = nil
        }
    }

    /// Mark the current playhead as in-point.
    func markInPoint(at seconds: Double) {
        inPoint = seconds
        if let outPoint, seconds >= outPoint {
            self.outPoint = nil
        }
    }

    /// Mark the current playhead as out-point.
    func markOutPoint(at seconds: Double) {
        outPoint = seconds
        if let inPoint, seconds <= inPoint {
            self.inPoint = nil
        }
    }

    /// Clear in/out points.
    func clearInOutPoints() {
        inPoint = nil
        outPoint = nil
    }

    /// Insert a segment from in/out marked range.
    func insertFromInOutPoints() {
        guard let inPt = inPoint, let outPt = outPoint, outPt > inPt + 0.2 else { return }
        // Convert composed time to source time if segments exist, otherwise use directly
        let range = TimeRange(startSeconds: inPt, endSeconds: outPt)
        insertManualSegment(range: range, at: timelineSegments.count)
        clearInOutPoints()
    }

    /// Rebuild the player composition from the current segment order.
    /// Clamp every timeline segment's source range into its owning
    /// record's real duration, and drop segments that collapse below
    /// 50ms after clamping.
    ///
    /// Stale / out-of-bounds ranges can sneak in through a few paths —
    /// LLM-generated keep lists built from transcripts with loose
    /// padding, split/trim math that used a pre-proxy duration,
    /// re-importing a shorter source without re-validating the
    /// timeline, etc. CompositionBuilder already skips these at
    /// render time (so playback didn't crash), but the scrubber
    /// shows phantom space for them and the "exceeds source duration"
    /// warning kept firing.
    ///
    /// Called at the top of `rebuildComposition()` so every timeline
    /// mutation funnels the data through the cleanup — this is the
    /// catch-all validator for dirty state already sitting on disk.
    private func sanitizeTimelineSegmentsAgainstSources() {
        guard !timelineSegments.isEmpty else { return }
        let minKeepDuration: Double = 0.05

        var didChange = false
        var droppedIDs: [UUID] = []
        var cleaned: [TimelineSegment] = []
        cleaned.reserveCapacity(timelineSegments.count)

        for var segment in timelineSegments {
            guard let sourceDuration = records.first(where: { $0.id == segment.sourceVideoID })?.analysis?.durationSeconds,
                  sourceDuration > 0 else {
                // No known source duration — leave the segment as-is;
                // CompositionBuilder's own guard will catch truly
                // unresolvable refs at render time.
                cleaned.append(segment)
                continue
            }

            let originalStart = segment.range.startSeconds
            let originalEnd = segment.range.endSeconds
            let clampedStart = max(0, min(sourceDuration, originalStart))
            let clampedEnd = max(clampedStart, min(sourceDuration, originalEnd))

            if clampedEnd - clampedStart < minKeepDuration {
                droppedIDs.append(segment.id)
                didChange = true
                print("🧹 Sanitizer: dropping segment \(segment.id) — range \(originalStart)–\(originalEnd)s collapses inside source duration \(sourceDuration)s")
                continue
            }

            if clampedStart != originalStart || clampedEnd != originalEnd {
                segment.range = TimeRange(startSeconds: clampedStart, endSeconds: clampedEnd)
                didChange = true
                print("🧹 Sanitizer: clamped segment \(segment.id) range \(originalStart)–\(originalEnd)s → \(clampedStart)–\(clampedEnd)s (source duration \(sourceDuration)s)")
            }

            cleaned.append(segment)
        }

        guard didChange else { return }

        timelineSegments = cleaned

        if !droppedIDs.isEmpty {
            for id in droppedIDs {
                selectedSegmentIDs.remove(id)
            }
            if let sel = selectedSegmentID, droppedIDs.contains(sel) {
                selectedSegmentID = selectedSegmentIDs.first
            }
            if timelineSegments.isEmpty {
                clearSegmentSelection()
            } else if selectedSegmentIDs.isEmpty && selectedSegmentID == nil {
                setSingleSelectedSegment(id: timelineSegments[0].id)
            } else {
                reconcileSegmentSelection()
            }
        }
    }

    private func rebuildComposition() {
        sanitizeTimelineSegmentsAgainstSources()
        rebuildComposedSubtitles()
        // Every mutation funnels through here — schedule a debounced
        // disk write so the live timeline (`project.tracks`) survives
        // close+reopen, not just the undo stack's pre-edit snapshots.
        scheduleDebouncedAutosave()
        // Opportunistically scan newly-inserted overlays for presenter
        // cam content. The scanner blocklists IDs it has already
        // analyzed so repeat calls are cheap.
        refreshPiPSuggestions()

        guard let projectRoot else { return }

        guard !timelineSegments.isEmpty else {
            player = nil
            return
        }

        compositionGeneration += 1
        let expectedGeneration = compositionGeneration
        let segments = timelineSegments
        let allRecords = records
        // Include overlay tracks in the preview composition so PiP
        // layouts render live (not just on export). Historically preview
        // only passed `segments:`, leaving overlays invisible until
        // export — this also fixes that pre-existing divergence.
        let overlayTracks = project.overlayTracks
        // Preserve playback position across rebuilds so per-segment edits
        // (rotate, flip, speed, volume…) don't yank the user back to frame 0,
        // which previously made the preview look as though nothing had
        // changed when toggling a transform.
        let previousTime = player?.currentTime() ?? .zero
        let wasPlaying = (player?.rate ?? 0) > 0

        Task {
            do {
                let result = try await CompositionBuilder.build(
                    sourceLookup: { sourceID in
                        let record = allRecords.first { $0.id == sourceID }
                        if let proxyPath = record?.derived.proxyRelativePath {
                            let url = projectRoot.appending(path: proxyPath)
                            return url
                        }
                        if record?.kind != .image {
                            print("🔴 sourceLookup: no proxy for sourceID \(sourceID), records: \(allRecords.map { "\($0.id) proxy=\($0.derived.proxyRelativePath ?? "nil")" })")
                        }
                        return URL(fileURLWithPath: record?.sourcePath ?? "/dev/null")
                    },
                    sourceKind: { sourceID in
                        allRecords.first { $0.id == sourceID }?.kind ?? .video
                    },
                    segments: segments,
                    overlayVideoTracks: overlayTracks,
                    primaryHidden: project.tracks.first(where: { $0.kind == .video })?.isMuted ?? false
                )
                guard expectedGeneration == compositionGeneration else { return }

                let playerItem = AVPlayerItem(asset: result.composition)
                if let vc = result.videoComposition {
                    playerItem.videoComposition = vc
                }
                if let am = result.audioMix {
                    playerItem.audioMix = am
                }

                let newPlayer = AVPlayer(playerItem: playerItem)
                self.player = newPlayer
                // Restore the old playhead so the viewer shows the same moment
                // with the new effects applied (instead of snapping to 0).
                if previousTime.isValid && previousTime.seconds > 0 {
                    await newPlayer.seek(
                        to: previousTime,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
                if wasPlaying {
                    newPlayer.playImmediately(atRate: Float(playbackRate))
                } else if playbackRate != 1.0 {
                    newPlayer.rate = Float(playbackRate)
                }
            } catch {
                let nsErr = error as NSError
                print("🔴 Composition failed: domain=\(nsErr.domain) code=\(nsErr.code) \(nsErr.localizedDescription)")
                print("🔴   userInfo: \(nsErr.userInfo)")
                guard expectedGeneration == compositionGeneration else { return }
                // Fallback: try first segment's source
                if let firstSeg = segments.first,
                   let record = allRecords.first(where: { $0.id == firstSeg.sourceVideoID }),
                   let proxyPath = record.derived.proxyRelativePath {
                    self.player = playbackCore.makePlayer(proxyURL: projectRoot.appending(path: proxyPath))
                }
            }
        }
    }

    private func prewarmVisibleProxies() {
        let urls = ProxyPrewarmPlan.urls(
            records: records,
            selectedRecordID: selectedRecordID,
            projectRoot: projectRoot,
            radius: 1
        )
        playbackCore.prepare(proxyURLs: urls)
    }

    private func clearSelectionAndPlayer() {
        selectedRecordID = nil
        clearSegmentSelection()
        player = nil
    }

    func loadRecords(validateSources: Bool = false) async {
        guard let store else {
            bannerMessage = L("Project store not configured")
            records = []
            clearSelectionAndPlayer()
            return
        }
        
        do {
            // Validate sources first if requested and MediaCore is available
            if validateSources, let mediaCore {
                try mediaCore.validateSources()
            }

            let manifest = try store.loadManifest()
            records = manifest.media
            speakerNames = Self.unpackSpeakerNames(manifest.speakerNames)
            speakerColors = Self.unpackSpeakerColors(manifest.speakerColors)
            speakerLabelSizes = Self.unpackSpeakerLabelSizes(manifest.speakerLabelSizes)

            if let selectedRecordID, records.contains(where: { $0.id == selectedRecordID }) {
                select(recordID: selectedRecordID)
            } else if let firstID = records.first?.id {
                select(recordID: firstID)
            } else {
                clearSelectionAndPlayer()
            }

            // `select()` → `rebuildTimelineSegments()` just rebuilt the
            // timeline from keptRanges + original transcript. If the
            // user had previously made manual edits (subtitle text,
            // split, trim, volume, effects…) those are stored in the
            // live-timeline snapshot on session.json. Replay that
            // snapshot now, once per launch, so those edits survive
            // project reopen. We intentionally do this AFTER the
            // rebuild so the persisted tracks win where they overlap
            // and the keptRanges-derived timeline fills in only when
            // no snapshot exists (fresh project just after analysis).
            if !hasRestoredPersistedTimeline {
                hasRestoredPersistedTimeline = true
                if let persistedTracks = lastAutosavedSession.currentTracks,
                   !persistedTracks.isEmpty {
                    let tracks = persistedTracks.map { $0.toTrack() }
                    project = Project(tracks: tracks)
                    if !project.tracks.contains(where: { $0.kind == .video }) {
                        project.tracks.insert(Project.makePrimaryVideoTrack(), at: 0)
                    }
                    lastAutosavedSegments = timelineSegments
                    reconcileSegmentSelection()
                    rebuildComposition()
                }
            }

            bannerMessage = nil
        } catch {
            bannerMessage = L("Failed to load manifest: %@", error.localizedDescription)
            records = []
            clearSelectionAndPlayer()
        }
    }

    func relinkOriginal(mediaId: UUID, newURL: URL) async {
        guard let mediaCore else {
            bannerMessage = L("MediaCore not configured")
            return
        }

        player = nil

        do {
            try mediaCore.relinkOriginal(mediaId: mediaId, newURL: newURL)
            await loadRecords()
            if records.contains(where: { $0.id == mediaId }) {
                select(recordID: mediaId)
            } else {
                clearSelectionAndPlayer()
            }
        } catch {
            bannerMessage = L("Relink failed: %@", error.localizedDescription)
        }
    }

    /// Public entry point for any user-initiated file import (drag-drop,
    /// open panel). Spawns a child `Task` that the view model owns so a
    /// later `cancelImport(id:)` can reliably interrupt it — including
    /// imports still queued behind the concurrency gate. Returns the
    /// ticket id so the caller can identify which row corresponds to
    /// which dropped URL.
    @discardableResult
    func startImport(url: URL) -> UUID {
        let isImage = mediaDropImageExtensions.contains(url.pathExtension.lowercased())
        let ticket = ImportingFile(name: url.lastPathComponent)
        importingFiles.append(ticket)
        isImporting = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performImport(ticketID: ticket.id, url: url, isImage: isImage)
        }
        importTasks[ticket.id] = task
        return ticket.id
    }

    /// Cancels the in-flight import for the given ticket id. The actual
    /// transcoder cleanup (delete partial proxy, drop optimistic
    /// manifest record) happens inside `MediaCore` when it observes
    /// cancellation; this method just sends the signal.
    func cancelImport(id: UUID) {
        importTasks[id]?.cancel()
    }

    /// Wait until all import tickets that come before `ticketID` in
    /// `importingFiles` (i.e. were started earlier in drop order) have
    /// finished their `performImport` task. Used by the auto-add path
    /// so that the timeline-append step happens in drop order even
    /// when imports complete out of order — otherwise N simultaneous
    /// drops would land on the timeline in finish-time order, which
    /// then becomes first-cut order, which the user didn't choose.
    ///
    /// `await task.value` resolves when the other ticket's
    /// `performImport` body returns (success OR failure), so a failed
    /// earlier import unblocks later ones rather than wedging them.
    /// Cancellation of an earlier import also unblocks later ones
    /// (cancellation propagates and the task body returns Void).
    private func waitForEarlierImportsToFinish(ticketID: UUID) async {
        let myIndex = importingFiles.firstIndex(where: { $0.id == ticketID }) ?? 0
        guard myIndex > 0 else { return }
        // Snapshot earlier ticket IDs once — `importingFiles` mutates
        // as earlier tickets finish (their defer removes themselves).
        let earlier = importingFiles.prefix(myIndex).map(\.id)
        for earlierID in earlier {
            if let task = importTasks[earlierID] {
                await task.value
            }
        }
    }

    private func performImport(ticketID: UUID, url: URL, isImage: Bool) async {
        defer {
            importingFiles.removeAll { $0.id == ticketID }
            importTasks[ticketID] = nil
            isImporting = !importingFiles.isEmpty
        }

        guard let mediaCore else {
            bannerMessage = L("MediaCore or store not configured")
            return
        }

        do {
            let mediaId: UUID
            if isImage {
                mediaId = try await mediaCore.importLocalImage(url: url)
            } else {
                // Forward progress samples back to MainActor and patch
                // the matching ticket so the placeholder row can show a
                // determinate bar + phase label. We capture `ticketID`
                // (a value type) instead of the row itself to avoid
                // staleness issues if `importingFiles` gets re-ordered.
                mediaId = try await mediaCore.importLocalVideo(
                    url: url,
                    progress: { [weak self] phase, progress in
                        Task { @MainActor [weak self] in
                            self?.updateImportProgress(
                                ticketID: ticketID,
                                phase: phase,
                                progress: progress
                            )
                        }
                    }
                )
            }
            selectedRecordID = mediaId
            await loadRecords()
            // Auto-append the freshly imported clip to the end of the
            // V1 timeline as a full-length placeholder. The timeline
            // is the source of truth for "what's in the cut and in
            // what order" — having the clip implicitly available
            // means the user can immediately scrub, reorder, or delete
            // it without having to drag from the library first.
            //
            // **Ordering across concurrent imports.** When the user
            // drops N files at once we get N parallel `performImport`
            // tasks that finish in arbitrary order. To keep timeline
            // order == drop order (which becomes first-cut order), we
            // wait here for all earlier tickets in `importingFiles` to
            // commit to the timeline first. `importingFiles` is
            // appended to in `startImport` on MainActor in drop order,
            // so its prefix gives us the canonical "earlier than me"
            // set. Each task in `importTasks` resolves to Void when
            // its `performImport` returns (after its own auto-add or
            // failure path), so awaiting it cleanly serializes the
            // inserts.
            await waitForEarlierImportsToFinish(ticketID: ticketID)
            // Skipped silently when the record is in any non-ready
            // state (failed proxy, partial analysis, etc.) so failed
            // imports don't litter the timeline. Already-present
            // placeholders for the same source are not deduped — if
            // the user re-imports the same file under a new media ID
            // it gets a second placeholder, which the timeline-driven
            // first-cut model handles correctly.
            if let record = records.first(where: { $0.id == mediaId }),
               record.status == .ready,
               record.kind == .image || (record.analysis?.durationSeconds ?? 0) > 0.1
            {
                insertMediaAsPrimary(
                    mediaID: mediaId,
                    at: timelineSegments.count,
                    revisionTrigger: .importMedia,
                    revisionLabel: "Import clip"
                )
            }
        } catch is CancellationError {
            // User-initiated cancel; MediaCore already cleaned up the
            // partial proxy + optimistic record. No banner needed.
            return
        } catch let error as ImportError {
            bannerMessage = error.errorDescription ?? L("Import failed.")
        } catch {
            bannerMessage = L("Import failed: %@", error.localizedDescription)
        }
    }

    private func updateImportProgress(
        ticketID: UUID,
        phase: ImportPhase,
        progress: Double
    ) {
        guard let index = importingFiles.firstIndex(where: { $0.id == ticketID }) else {
            return
        }
        importingFiles[index].phase = Self.uiPhase(for: phase)
        importingFiles[index].progress = progress
    }

    private static func uiPhase(for phase: ImportPhase) -> ImportingFile.Phase {
        switch phase {
        case .preparing: return .preparing
        case .analyzing: return .analyzing
        case .waiting: return .waiting
        case .transcoding: return .transcoding
        }
    }

    func importLocalVideo(url: URL) async {
        // Synchronous-ish entry point used by tests and any internal
        // caller that wants to await completion. The UI path goes
        // through `startImport(url:)` instead so the Task handle is
        // owned by the view model and `cancelImport` is wired up.
        let ticket = ImportingFile(name: url.lastPathComponent)
        importingFiles.append(ticket)
        isImporting = true
        await performImport(ticketID: ticket.id, url: url, isImage: false)
    }

    /// Import a still image (PNG/JPEG). Unlike video imports, stills
    /// skip proxy transcoding, waveform extraction and the AI analysis
    /// pipeline — the record is created with status `.ready` immediately
    /// and `kind = .image`. The image itself stays on disk at its
    /// original path (no project-copy), matching the video import's
    /// external-source convention.
    func importLocalImage(url: URL) async {
        let ticket = ImportingFile(name: url.lastPathComponent)
        importingFiles.append(ticket)
        isImporting = true
        await performImport(ticketID: ticket.id, url: url, isImage: true)
    }

    /// Generate an AI image via the Cutti relay (FLUX.2-pro) and
    /// import it into the Media Browser. Does NOT touch the timeline —
    /// for the "generate + auto-insert as overlay" flow used by the AI
    /// B-roll suggestions, see `generateAIImageAndInsertOverlay(...)`.
    ///
    /// Returns the imported media ID on success, nil on any failure
    /// (with `bannerMessage` set to a user-facing reason).
    @discardableResult
    func generateAIImageToLibrary(
        prompt: String,
        size: ImageGenerationSize = .square1024
    ) async -> (mediaID: UUID, relativePath: String)? {
        return await generateAIImage(
            prompt: prompt,
            size: size,
            insertAt: nil,
            overlayDuration: 0,
            chatNote: "🎨 Generated image — added to your Media Browser."
        )
    }

    /// Generate an AI image and drop it onto a new overlay track at
    /// `composedTime` for `duration` seconds (default 4 s). Used by the
    /// B-roll suggestion popover's "Generate image" button.
    @discardableResult
    func generateAIImageAndInsertOverlay(
        prompt: String,
        size: ImageGenerationSize = .square1024,
        at composedTime: Double,
        duration: Double = 4.0
    ) async -> (mediaID: UUID, relativePath: String)? {
        return await generateAIImage(
            prompt: prompt,
            size: size,
            insertAt: composedTime,
            overlayDuration: duration,
            chatNote: "🎨 Generated image and inserted at \(String(format: "%.1fs", composedTime)) for \(String(format: "%.1fs", duration))."
        )
    }

    /// Shared implementation for the two `generateAIImage*` entry points.
    /// Keeps the service call, on-disk write, media-library import and
    /// optional overlay insertion in a single place so UI state
    /// (`importingFiles`, `bannerMessage`) always moves consistently.
    private func generateAIImage(
        prompt: String,
        size: ImageGenerationSize,
        insertAt composedTime: Double?,
        overlayDuration: Double,
        chatNote: String? = nil
    ) async -> (mediaID: UUID, relativePath: String)? {
        guard let mediaCore, let store else {
            bannerMessage = L("MediaCore or store not configured")
            return nil
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bannerMessage = L("Prompt is empty.")
            return nil
        }

        // Kickoff bubble so the user sees something happening while the
        // FLUX call is in flight. Flipped to success/failure below; the
        // existing "image ready" bubble (when chatNote != nil) appends
        // right after it so the image itself is still rendered inline.
        let kickoffChatID: UUID? = (chatNote != nil)
            ? beginPresetActionChat(
                userAction: L("⚡ Generate AI image"),
                working: L("Generating image from \"%@\"…", String(trimmed.prefix(60))),
                icon: "photo.badge.plus"
            )
            : nil

        let ticketName = "AI image · \(String(trimmed.prefix(32)))"
        let ticket = ImportingFile(id: UUID(), name: ticketName)
        importingFiles.append(ticket)
        isImporting = true
        defer {
            importingFiles.removeAll { $0.id == ticket.id }
            isImporting = !importingFiles.isEmpty
        }

        // Step 1: hit the relay (off the main actor).
        let png: Data
        do {
            png = try await ImageGenerationService.shared.generate(
                prompt: trimmed,
                size: size
            )
        } catch {
            bannerMessage = L("Image generation failed: %@", error.localizedDescription)
            if let kickoffChatID {
                finishPresetActionChat(
                    id: kickoffChatID,
                    text: L("Image generation failed: %@", error.localizedDescription),
                    tone: .failure,
                    icon: "exclamationmark.triangle.fill"
                )
            }
            return nil
        }

        // Step 2: persist under the project's media/generated/ directory
        // so the file survives across sessions and follows the project
        // folder if the user archives it. (Project rename/move breakage
        // is a pre-existing MediaAsset issue and is out of scope here.)
        let destDir = store.projectRoot.appending(path: "media/generated")
        do {
            try FileManager.default.createDirectory(
                at: destDir,
                withIntermediateDirectories: true
            )
        } catch {
            bannerMessage = L("Could not create media directory: %@", error.localizedDescription)
            if let kickoffChatID {
                finishPresetActionChat(
                    id: kickoffChatID,
                    text: L("Could not create media directory: %@", error.localizedDescription),
                    tone: .failure,
                    icon: "exclamationmark.triangle.fill"
                )
            }
            return nil
        }
        let fileURL = destDir.appending(path: "\(UUID().uuidString).png")
        do {
            try png.write(to: fileURL, options: .atomic)
        } catch {
            bannerMessage = L("Could not save generated image: %@", error.localizedDescription)
            if let kickoffChatID {
                finishPresetActionChat(
                    id: kickoffChatID,
                    text: L("Could not save generated image: %@", error.localizedDescription),
                    tone: .failure,
                    icon: "exclamationmark.triangle.fill"
                )
            }
            return nil
        }

        // Step 3: import into the Media Browser. `importLocalImage`
        // creates a MediaAssetRecord with kind == .image so the timeline
        // insertion path downstream uses the 4-second still convention.
        let mediaID: UUID
        do {
            mediaID = try await mediaCore.importLocalImage(url: fileURL)
        } catch {
            bannerMessage = L("Image import failed: %@", error.localizedDescription)
            if let kickoffChatID {
                finishPresetActionChat(
                    id: kickoffChatID,
                    text: L("Image import failed: %@", error.localizedDescription),
                    tone: .failure,
                    icon: "exclamationmark.triangle.fill"
                )
            }
            return nil
        }
        await loadRecords()

        // Step 4 (optional): drop onto a new overlay track. Goes through
        // the existing `insertBRollOverlay` path so the overlay behaves
        // identically to a manually dragged still — handles, free
        // transform, undo/redo.
        if let composedTime, overlayDuration > 0 {
            insertBRollOverlay(
                mediaID: mediaID,
                at: composedTime,
                duration: overlayDuration
            )
        }

        let relativePath = "media/generated/\(fileURL.lastPathComponent)"

        // Step 5 (optional): emit a chat bubble so the user sees the
        // generated PNG inline — with click-to-zoom and a right-click
        // Save menu. The agent-tool path passes chatNote=nil because
        // it emits its own outcome bubble carrying the same image.
        if let note = chatNote {
            if let kickoffChatID {
                finishPresetActionChat(
                    id: kickoffChatID,
                    text: L("Image ready."),
                    tone: .success,
                    icon: "checkmark.seal.fill"
                )
            }
            let bubble = EditorChatMessage(
                role: .assistant,
                content: note,
                iconSystemName: "photo.artframe",
                iconTone: .success,
                imageAttachmentPath: relativePath
            )
            chatMessages.append(bubble)
            try? await chatStore?.append(bubble)
        }

        return (mediaID, relativePath)
    }

    func deleteRecord(id: UUID) {
        guard let store else {
            bannerMessage = L("Store not configured")
            return
        }

        do {
            var manifest = try store.loadManifest()
            manifest.media.removeAll { $0.id == id }
            try store.saveManifest(manifest)

            // Delete proxy file
            let proxyURL = store.proxyURL(for: id)
            try? FileManager.default.removeItem(at: proxyURL)

            if selectedRecordID == id {
                clearSelectionAndPlayer()
            }

            records = manifest.media
            if let firstID = records.first?.id, selectedRecordID == nil {
                select(recordID: firstID)
            }
        } catch {
            bannerMessage = L("Delete failed: %@", error.localizedDescription)
        }
    }

    // MARK: - AI Analysis

    /// Run the AI analysis pipeline on a single record.
    func analyzeRecord(id: UUID) async {
        guard let store, let analysisPipeline else {
            bannerMessage = L("Analysis pipeline not configured")
            finishAnalysisChatBubble(
                content: L("Analysis pipeline not configured."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }
        guard !isAnalyzing else {
            bannerMessage = L("Analysis already in progress.")
            finishAnalysisChatBubble(
                content: L("Analysis already in progress."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }
        guard let record = records.first(where: { $0.id == id }) else {
            finishAnalysisChatBubble(
                content: L("Clip not found."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }
        guard record.status == .ready else {
            bannerMessage = L("Clip must be ready before analysis.")
            finishAnalysisChatBubble(
                content: L("Clip must be ready before analysis."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }

        // Determine source URL: prefer proxy for faster processing
        let sourceURL: URL
        if let proxyPath = record.derived.proxyRelativePath, let root = projectRoot {
            sourceURL = root.appending(path: proxyPath)
        } else {
            sourceURL = URL(fileURLWithPath: record.sourcePath)
        }

        guard let analysis = record.analysis else {
            bannerMessage = L("Missing media metadata.")
            finishAnalysisChatBubble(
                content: L("Missing media metadata."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }

        // Update status to analyzing
        do {
            var manifest = try store.loadManifest()
            if let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                manifest.media[idx].status = .analyzing
                try store.saveManifest(manifest)
            }
            await loadRecords()
        } catch {
            bannerMessage = L("Failed to update status: %@", error.localizedDescription)
            finishAnalysisChatBubble(
                content: L("Failed to update status: %@", error.localizedDescription),
                icon: "xmark.octagon.fill",
                tone: .failure
            )
            return
        }

        isAnalyzing = true
        bannerMessage = nil

        do {
            let snapshot = try await analysisPipeline.analyze(
                sourceURL: sourceURL,
                analysis: analysis,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.analysisProgress = progress
                        self?.updateAnalysisChatBubble(progress)
                        // Chat live-narration path: when handleAIPrompt
                        // is driving this run, forward phase transitions
                        // into the in-place chat bubble.
                        self?.liveNarrationCallback?(progress.phase)
                    }
                }
            )

            // Persist the copilot snapshot to the manifest
            var manifest = try store.loadManifest()
            if let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                manifest.media[idx].copilot = snapshot
                manifest.media[idx].status = .ready
                try store.saveManifest(manifest)
            }

            isAnalyzing = false
            analysisProgress = nil
            await loadRecords()

            // Re-select to refresh viewer with composition
            if selectedRecordID == id {
                select(recordID: id)
            }

            // Auto-detect speakers as part of the first cut so the
            // transcript shows distinct speakers immediately. Best-
            // effort and silent on failure.
            await runDiarizationDuringFirstCut()

            // Final agent pass: ask the LLM where visual B-roll would
            // reinforce the spoken content. Best-effort — if it fails
            // or the OpenAI config isn't present, we simply skip and
            // the rest of the analysis result is preserved.
            await refreshBRollSuggestions(
                for: id,
                keptTranscript: snapshot.keptRanges.flatMap { ranges in
                    Self.transcriptSegmentsFor(ranges: ranges, transcript: snapshot.transcript ?? [])
                } ?? []
            )

            // Inform user about result
            if let ranges = snapshot.keptRanges, !ranges.isEmpty {
                bannerMessage = nil
                finishAnalysisChatBubble(
                    content: L("Analysis complete — kept %d segments. You can now chat to refine the cut.", ranges.count),
                    icon: "checkmark.seal.fill",
                    tone: .success
                )
            } else {
                bannerMessage = L("AI analysis complete but no edit suggestions were produced. The LLM call may have failed.")
                finishAnalysisChatBubble(
                    content: L("Analysis finished but produced no edit suggestions. The LLM call may have failed."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
        } catch {
            isAnalyzing = false
            analysisProgress = nil
            bannerMessage = L("Analysis failed: %@", error.localizedDescription)
            finishAnalysisChatBubble(
                content: L("Analysis failed: %@", error.localizedDescription),
                icon: "xmark.octagon.fill",
                tone: .failure
            )

            // Revert status to ready
            do {
                var manifest = try store.loadManifest()
                if let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                    manifest.media[idx].status = .ready
                    try store.saveManifest(manifest)
                }
                await loadRecords()
            } catch {
                // Best-effort revert
            }
        }
    }

    /// Analyze the currently selected record.
    func analyzeSelectedRecord() async {
        // Gate every AI entry point on a valid relay session. Local
        // speech transcription runs on-device, so without this check
        // the user could sit through a slow transcribe before we hit
        // the relay 401 on the LLM step — confusing ("Why did it
        // start if I wasn't signed in?"). We'd rather refuse up
        // front with a friendly chat bubble pointing at Settings.
        guard hasRelayCredentials() else {
            beginAnalysisChatBubble(
                userAction: L("One-click first cut"),
                userIcon: "bolt.fill"
            )
            finishAnalysisChatBubble(
                content: L("Please sign in from Settings."),
                icon: "person.crop.circle.badge.exclamationmark",
                tone: .warning
            )
            return
        }

        // The timeline is the source of truth for "what gets cut" —
        // pull the unique video records currently placed on V1 in
        // timeline order, and dispatch off that count. Image
        // placements are excluded (no audio to transcribe). Records in
        // the library but not on the timeline are intentionally
        // skipped.
        let candidates = videoRecordsOnTimeline
        // Surface the One-click first cut flow inside the AI chat so
        // users see the transcribe → scene → audio → LLM phases as a
        // live conversation instead of a detached progress box above
        // the chat. We pre-seed the three parallel local phases in
        // fastest→slowest visual order (audio → scene → transcribe)
        // so the chat log reads predictably even though the tasks
        // actually run concurrently and complete in arbitrary order.
        beginAnalysisChatBubble(
            userAction: L("One-click first cut"),
            userIcon: "bolt.fill",
            preseededPhases: [.analyzingAudio, .analyzingScenes, .transcribing]
        )
        if candidates.count > 1 {
            await analyzeAllRecords()
        } else if let only = candidates.first {
            await analyzeRecord(id: only.id)
        } else {
            // Nothing on the timeline to analyze — point user at the
            // fix (drag a clip from the media library to the timeline).
            finishAnalysisChatBubble(
                content: L("Drag a clip onto the timeline to start the first cut.")
            )
        }
    }

    /// Local-only pipeline that transcribes the clip, trims inter-word
    /// silences via the existing silence/word-gap logic, and keeps every
    /// spoken segment. Skips all LLM passes and B-roll suggestions, so
    /// it's fast, works offline, and burns no relay credits.
    func trimPausesOnSelectedRecord() async {
        let readyRecords = records.filter { $0.status == .ready }
        beginAnalysisChatBubble(
            userAction: L("Trim pauses only"),
            userIcon: "waveform.path"
        )
        if readyRecords.count > 1 {
            for record in readyRecords {
                await trimPausesOnRecord(id: record.id, standalone: false)
            }
            if analysisChatActive {
                finishAnalysisChatBubble(
                    content: L("Trimmed pauses on %d clips. No AI credits used.", readyRecords.count),
                    icon: "checkmark.seal.fill",
                    tone: .success
                )
            }
        } else if let selectedRecordID {
            await trimPausesOnRecord(id: selectedRecordID, standalone: true)
        } else {
            finishAnalysisChatBubble(content: L("No clip ready to trim."))
        }
    }

    /// Trim pauses on a single clip. Pass `standalone = true` to close
    /// the chat bubble with a per-clip summary; pass `false` when the
    /// caller is batching multiple clips and will post its own summary.
    func trimPausesOnRecord(id: UUID, standalone: Bool = true) async {
        guard let store else {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Project not configured."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
            return
        }
        guard !isAnalyzing else {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Another analysis is already in progress."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
            return
        }
        guard let record = records.first(where: { $0.id == id }) else {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Clip not found."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
            return
        }
        guard record.status == .ready else {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Clip must be ready before trimming."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
            return
        }
        guard let analysis = record.analysis else {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Missing media metadata."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
            return
        }

        let sourceURL: URL
        if let proxyPath = record.derived.proxyRelativePath, let root = projectRoot {
            sourceURL = root.appending(path: proxyPath)
        } else {
            sourceURL = URL(fileURLWithPath: record.sourcePath)
        }

        // Flip to analyzing so status chips update and re-entrancy is
        // guarded the same way the LLM path is.
        do {
            var manifest = try store.loadManifest()
            if let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                manifest.media[idx].status = .analyzing
                try store.saveManifest(manifest)
            }
            await loadRecords()
        } catch {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Failed to update status: %@", error.localizedDescription),
                    icon: "xmark.octagon.fill",
                    tone: .failure
                )
            }
            return
        }

        isAnalyzing = true
        bannerMessage = nil

        let orchestrator = AnalysisOrchestrator()
        do {
            let localResult = try await orchestrator.analyze(
                sourceURL: sourceURL,
                analysis: analysis,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.analysisProgress = progress
                        self?.updateAnalysisChatBubble(progress)
                    }
                }
            )

            // All-keep decision — CopilotSnapshotBuilder handles the
            // actual silence trimming (splitInternalSilence +
            // tightenToWordBoundaries + trimSilence) per kept segment.
            let keepAll = LLMEditorService.EditDecision(
                keepIndices: Array(localResult.transcript.indices),
                cuts: [],
                duplicateGroups: []
            )
            let snapshot = CopilotSnapshotBuilder.fromAnalysisAndEdit(
                local: localResult,
                editDecision: keepAll
            )

            var manifest = try store.loadManifest()
            if let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                manifest.media[idx].copilot = snapshot
                manifest.media[idx].status = .ready
                try store.saveManifest(manifest)
            }

            isAnalyzing = false
            analysisProgress = nil
            await loadRecords()

            if selectedRecordID == id {
                select(recordID: id)
            }

            if standalone {
                let rangeCount = snapshot.keptRanges?.count ?? 0
                finishAnalysisChatBubble(
                    content: L("Trimmed pauses — kept %d segments. No AI credits used.", rangeCount),
                    icon: "checkmark.seal.fill",
                    tone: .success
                )
            }
        } catch {
            isAnalyzing = false
            analysisProgress = nil
            // Best-effort revert the analyzing flag so the clip doesn't
            // look stuck.
            if var manifest = try? store.loadManifest(),
               let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                manifest.media[idx].status = .ready
                try? store.saveManifest(manifest)
                await loadRecords()
            }
            bannerMessage = L("Trim pauses failed: %@", error.localizedDescription)
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Trim pauses failed: %@", error.localizedDescription),
                    icon: "xmark.octagon.fill",
                    tone: .failure
                )
            }
        }
    }

    /// Run only the 4-pass LLM cleanup on the selected record (or on
    /// every ready record when multiple are loaded). Skips the B-roll
    /// suggestion pass so users who want visual aids can trigger that
    /// explicitly via the separate "Suggest B-roll & animations"
    /// preset.
    func transcriptCleanupOnSelectedRecord() async {
        guard hasRelayCredentials() else {
            beginAnalysisChatBubble(
                userAction: L("Transcript cleanup"),
                userIcon: "text.badge.minus"
            )
            finishAnalysisChatBubble(
                content: L("Please sign in from Settings."),
                icon: "person.crop.circle.badge.exclamationmark",
                tone: .warning
            )
            return
        }
        let readyRecords = records.filter { $0.status == .ready }
        beginAnalysisChatBubble(
            userAction: L("Transcript cleanup"),
            userIcon: "text.badge.minus"
        )
        if readyRecords.count > 1 {
            for record in readyRecords {
                await transcriptCleanupOnRecord(id: record.id, standalone: false)
            }
            if analysisChatActive {
                finishAnalysisChatBubble(
                    content: L("Transcript cleanup complete across %d clips.", readyRecords.count),
                    icon: "checkmark.seal.fill",
                    tone: .success
                )
            }
        } else if let selectedRecordID {
            await transcriptCleanupOnRecord(id: selectedRecordID, standalone: true)
        } else {
            finishAnalysisChatBubble(content: L("No clip ready for cleanup."))
        }
    }

    /// Transcript cleanup on a single clip. Identical to the full
    /// analysis pipeline except it does NOT chain into the B-roll
    /// suggestion pass afterwards.
    func transcriptCleanupOnRecord(id: UUID, standalone: Bool = true) async {
        guard let store, let analysisPipeline else {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Analysis pipeline not configured."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
            return
        }
        guard !isAnalyzing else {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Another analysis is already in progress."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
            return
        }
        guard let record = records.first(where: { $0.id == id }),
              record.status == .ready,
              let analysis = record.analysis else {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Clip not ready."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
            return
        }

        let sourceURL: URL
        if let proxyPath = record.derived.proxyRelativePath, let root = projectRoot {
            sourceURL = root.appending(path: proxyPath)
        } else {
            sourceURL = URL(fileURLWithPath: record.sourcePath)
        }

        do {
            var manifest = try store.loadManifest()
            if let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                manifest.media[idx].status = .analyzing
                try store.saveManifest(manifest)
            }
            await loadRecords()
        } catch {
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Failed to update status: %@", error.localizedDescription),
                    icon: "xmark.octagon.fill",
                    tone: .failure
                )
            }
            return
        }

        isAnalyzing = true
        bannerMessage = nil

        do {
            let snapshot = try await analysisPipeline.analyze(
                sourceURL: sourceURL,
                analysis: analysis,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.analysisProgress = progress
                        self?.updateAnalysisChatBubble(progress)
                        self?.liveNarrationCallback?(progress.phase)
                    }
                }
            )

            var manifest = try store.loadManifest()
            if let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                manifest.media[idx].copilot = snapshot
                manifest.media[idx].status = .ready
                try store.saveManifest(manifest)
            }

            isAnalyzing = false
            analysisProgress = nil
            await loadRecords()

            if selectedRecordID == id {
                select(recordID: id)
            }

            if standalone {
                if let ranges = snapshot.keptRanges, !ranges.isEmpty {
                    finishAnalysisChatBubble(
                        content: L("Cleanup complete — kept %d segments. Run \"Suggest B-roll & animations\" next if you want visual aids.", ranges.count),
                        icon: "checkmark.seal.fill",
                        tone: .success
                    )
                } else {
                    finishAnalysisChatBubble(
                        content: L("Cleanup finished but produced no edit suggestions."),
                        icon: "exclamationmark.triangle.fill",
                        tone: .warning
                    )
                }
            }
        } catch {
            isAnalyzing = false
            analysisProgress = nil
            if var manifest = try? store.loadManifest(),
               let idx = manifest.media.firstIndex(where: { $0.id == id }) {
                manifest.media[idx].status = .ready
                try? store.saveManifest(manifest)
                await loadRecords()
            }
            bannerMessage = L("Transcript cleanup failed: %@", error.localizedDescription)
            if standalone {
                finishAnalysisChatBubble(
                    content: L("Transcript cleanup failed: %@", error.localizedDescription),
                    icon: "xmark.octagon.fill",
                    tone: .failure
                )
            }
        }
    }

    /// Run only the B-roll / animation suggestion pass on the selected
    /// record's current kept transcript. Requires a previous cleanup
    /// or trim pass so the kept transcript exists.
    func suggestBRollOnSelectedRecord() async {
        guard hasRelayCredentials() else {
            beginAnalysisChatBubble(
                userAction: L("Suggest B-roll & animations"),
                userIcon: "sparkles.rectangle.stack"
            )
            finishAnalysisChatBubble(
                content: L("Please sign in from Settings."),
                icon: "person.crop.circle.badge.exclamationmark",
                tone: .warning
            )
            return
        }
        guard let id = selectedRecordID,
              let record = records.first(where: { $0.id == id }) else {
            beginAnalysisChatBubble(
                userAction: L("Suggest B-roll & animations"),
                userIcon: "sparkles.rectangle.stack"
            )
            finishAnalysisChatBubble(
                content: L("No clip selected."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }
        guard let snapshot = record.copilot,
              let ranges = snapshot.keptRanges, !ranges.isEmpty,
              let transcript = snapshot.transcript, !transcript.isEmpty else {
            beginAnalysisChatBubble(
                userAction: L("Suggest B-roll & animations"),
                userIcon: "sparkles.rectangle.stack"
            )
            finishAnalysisChatBubble(
                content: L("Run \"Trim pauses\" or \"Transcript cleanup\" first — there's no cut for me to analyze yet."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }

        beginAnalysisChatBubble(
            userAction: L("Suggest B-roll & animations"),
            userIcon: "sparkles.rectangle.stack"
        )
        appendAnalysisAssistantLine(
            L("Scanning the cut for visual-aid opportunities…"),
            icon: "sparkles",
            tone: .working,
            persist: true
        )

        let kept = Self.transcriptSegmentsFor(ranges: ranges, transcript: transcript)
        await refreshBRollSuggestions(
            for: id,
            keptTranscript: kept,
            onProgress: { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.appendAnalysisAssistantLine(
                        line,
                        icon: "sparkles",
                        tone: .working,
                        persist: true
                    )
                }
            }
        )

        // Read back the result from the refreshed record so the count
        // reported to the user reflects what actually persisted.
        let count = records.first(where: { $0.id == id })?
            .copilot?.bRollSuggestions?.count ?? 0
        if count > 0 {
            finishAnalysisChatBubble(
                content: L("Ready — %d visual-aid suggestions above the timeline.", count),
                icon: "checkmark.seal.fill",
                tone: .success
            )
        } else {
            finishAnalysisChatBubble(
                content: L("No visual aids suggested for this cut."),
                icon: "checkmark.seal.fill",
                tone: .success
            )
        }
    }

    /// Returns true when the relay has a usable credential to send —
    /// either a signed-in user JWT or a developer dev-token override.
    /// Everything else (empty token, expired JWT that we already cleared)
    /// will 401 at the worker, so we treat it as "not signed in".
    private func hasRelayCredentials() -> Bool {
        if RelaySession.shared.isSignedIn { return true }
        let dev = UserDefaults.standard.string(forKey: "cutti_relay_dev_token") ?? ""
        return !dev.isEmpty
    }

    // MARK: - Chat bubbles for analysis progress

    /// Post the user action line and, when applicable, pre-seed the
    /// parallel-phase bubbles in a stable visual order. Each subsequent
    /// phase transition mutates the matching pre-seeded bubble in
    /// place instead of appending a new one, so the chat log reads
    /// top→bottom in the order the caller wants (typically
    /// fastest→slowest) even though the underlying tasks run in
    /// parallel and complete in any order.
    ///
    /// Callers that don't pre-seed phases get the legacy behaviour:
    /// a generic "Starting AI analysis…" placeholder until the first
    /// phase event arrives.
    private func beginAnalysisChatBubble(
        userAction: String,
        userIcon: String? = nil,
        preseededPhases: [AnalysisPhase] = []
    ) {
        guard !analysisChatActive else { return }
        analysisChatActive = true
        analysisChatSeenPhases = []
        analysisChatPhaseBubbleIDs = [:]

        let userMsg = EditorChatMessage(
            role: .user,
            content: userAction,
            iconSystemName: userIcon,
            iconTone: userIcon == nil ? nil : .neutral
        )
        chatMessages.append(userMsg)
        let store = chatStore
        Task { try? await store?.append(userMsg) }

        if preseededPhases.isEmpty {
            // Workflows that don't pre-seed phases keep the generic
            // header so the chat isn't visually empty between the
            // user action and the first phase event.
            appendAnalysisAssistantLine(
                L("Starting AI analysis…"),
                icon: "play.circle.fill",
                tone: .working,
                persist: true
            )
        } else {
            // Pre-seed each phase as a "Queued" bubble in the
            // caller-requested order. As kickoff/done events arrive
            // they mutate these bubbles in place — the order on
            // screen stays fixed regardless of which parallel task
            // actually finishes first. We deliberately skip the
            // generic "Starting AI analysis…" header here because
            // the seeded bubbles already convey "work has begun".
            for phase in preseededPhases {
                seedAnalysisPhaseBubble(phase)
            }
        }
    }

    /// Append a placeholder bubble for `phase` in the "Queued" state
    /// and record it so future kickoff/done events mutate it instead
    /// of appending a new bubble. Used by `beginAnalysisChatBubble` to
    /// lock in a stable visual order for parallel phases.
    private func seedAnalysisPhaseBubble(_ phase: AnalysisPhase) {
        let (label, icon) = Self.phaseLabelAndIcon(for: phase)
        let statusLine = "\(label) — \(L("Queued"))"
        let line = Self.composeWorkingChatLine(statusLine, phase: phase)
        let bubble = appendAnalysisAssistantBubble(
            line,
            icon: icon,
            tone: .working,
            persist: true
        )
        analysisChatPhaseBubbleIDs[phase] = bubble.id
        analysisChatSeenPhases.insert(phase)
    }

    /// Label + SF Symbol icon for each analysis phase. Centralised so
    /// `seedAnalysisPhaseBubble` (pre-seeding) and
    /// `updateAnalysisChatBubble` (live updates) render the same
    /// thing for the same phase.
    private static func phaseLabelAndIcon(for phase: AnalysisPhase) -> (String, String) {
        switch phase {
        case .queued:          return (L("Queued"), "hourglass")
        case .transcribing:    return (L("Transcribing speech"), "waveform")
        case .analyzingScenes: return (L("Analyzing scenes"), "film")
        case .analyzingAudio:  return (L("Analyzing audio"), "speaker.wave.2.fill")
        case .requestingAI:    return (L("Asking AI to plan cuts"), "sparkles")
        case .complete:        return (L("Local analysis complete"), "checkmark.seal.fill")
        case .failed:          return (L("Analysis failed"), "xmark.octagon.fill")
        }
    }

    /// Drive the streaming analysis log in the chat panel. Each phase
    /// gets exactly one bubble: a kickoff event appends it (or
    /// mutates the pre-seeded one) with a spinner and a `"Phase —
    /// Started"` label, and the matching `isPhaseComplete` event
    /// later mutates that same bubble in place (text → `"Phase —
    /// Done in 10.6s"`, tone → checkmark, or failure-x when the task
    /// threw). Because transcribe/scene/audio run in parallel,
    /// multiple spinners can be alive simultaneously — each one
    /// resolves independently when its own done event arrives.
    private func updateAnalysisChatBubble(_ progress: AnalysisProgress) {
        guard analysisChatActive else { return }

        // [diag-2026-05-16] Whenever an "Apple Speech" string flows
        // into the chat bubble, dump the source — we're chasing a bug
        // where this appears mid-flight while the Qwen sidecar is
        // still healthy. Catches the path regardless of which view-
        // model entry point produced the progress event.
        if progress.detail.contains("Apple Speech") {
            let stack = Thread.callStackSymbols.dropFirst().prefix(20).joined(separator: "\n     ")
            print("💬 [chat.bubble.APPLE_SPEECH] phase=\(progress.phase) detail=\(progress.detail) STACK:\n     \(stack)")
        }

        let (label, kickoffIcon) = Self.phaseLabelAndIcon(for: progress.phase)
        let detail = progress.detail.trimmingCharacters(in: .whitespacesAndNewlines)

        if progress.isPhaseComplete {
            // Resolve this phase's existing spinner bubble in place.
            // No hint suffix here — "Done in 10m 46s" already tells the
            // user how long it took.
            let isFailure = detail.lowercased().hasPrefix("failed")
            let resolvedIcon = isFailure ? "xmark.octagon.fill" : "checkmark.circle.fill"
            let resolvedTone: EditorChatMessage.IconTone = isFailure ? .failure : .success
            let line = detail.isEmpty ? label : "\(label) — \(detail)"
            if let bubbleID = analysisChatPhaseBubbleIDs[progress.phase] {
                mutateAssistantBubble(
                    id: bubbleID,
                    content: line,
                    icon: resolvedIcon,
                    tone: resolvedTone
                )
                analysisChatPhaseBubbleIDs.removeValue(forKey: progress.phase)
                analysisChatSeenPhases.remove(progress.phase)
            } else {
                // No prior kickoff (shouldn't happen but be defensive):
                // append a one-shot resolved bubble so the user still
                // sees the outcome.
                appendAnalysisAssistantLine(line, icon: resolvedIcon, tone: resolvedTone, persist: true)
            }
            return
        }

        // Kickoff or intermediate update for a phase. If the bubble
        // already exists (either from pre-seeding or a previous
        // event), mutate it in place; otherwise append a new bubble.
        if analysisChatSeenPhases.contains(progress.phase) {
            guard let bubbleID = analysisChatPhaseBubbleIDs[progress.phase] else { return }
            let statusLine = detail.isEmpty ? label : "\(label) — \(detail)"
            let line = Self.composeWorkingChatLine(statusLine, phase: progress.phase)
            mutateAssistantBubble(id: bubbleID, content: line, icon: nil, tone: nil)
            return
        }
        analysisChatSeenPhases.insert(progress.phase)

        let kickoffTone: EditorChatMessage.IconTone
        switch progress.phase {
        case .complete: kickoffTone = .success
        case .failed:   kickoffTone = .failure
        case .queued:   kickoffTone = .neutral
        default:        kickoffTone = .working
        }

        let statusLine = detail.isEmpty ? label : "\(label) — \(detail)"
        let line = Self.composeWorkingChatLine(statusLine, phase: progress.phase)
        let bubble = appendAnalysisAssistantBubble(
            line,
            icon: kickoffIcon,
            tone: kickoffTone,
            persist: true
        )
        analysisChatPhaseBubbleIDs[progress.phase] = bubble.id
    }

    /// Append a phase-specific hint underneath the status line for the
    /// long-running phases. Transcribe and scene analysis both scale
    /// with the source video's length **and** quality (resolution,
    /// codec complexity, audio busyness), so a 60-minute 4K HEVC clip
    /// can take an order of magnitude longer than a 5-minute 1080p
    /// one. Surfacing that expectation in the bubble keeps users from
    /// assuming the app froze when transcribe sits at "chunk 7 / 41"
    /// for several minutes. The hint is rendered on its own line
    /// below the status so the dynamic "chunk x / y · m s elapsed"
    /// updates remain easy to read.
    private static func composeWorkingChatLine(
        _ statusLine: String,
        phase: AnalysisPhase
    ) -> String {
        guard let hint = workingPhaseHint(for: phase) else { return statusLine }
        return "\(statusLine)\n\(hint)"
    }

    private static func workingPhaseHint(for phase: AnalysisPhase) -> String? {
        switch phase {
        case .transcribing:
            // Transcribe time scales with audio length (which equals
            // video length for any clip with sound). Video resolution
            // is irrelevant here — the sidecar only sees the
            // extracted 16 kHz mono WAV.
            return L("⏳ This step's duration depends on the video's length.")
        case .analyzingScenes:
            // Scene analysis walks the decoded video frames, so
            // resolution / codec complexity matters as well as
            // length — a 4K HEVC clip is much slower than a 1080p
            // ProRes one of the same length.
            return L("⏳ This step's duration depends on the video's length and quality.")
        default:
            return nil
        }
    }

    /// Append the final summary bubble and close out the session.
    private func finishAnalysisChatBubble(
        content: String,
        icon: String? = nil,
        tone: EditorChatMessage.IconTone? = nil
    ) {
        guard analysisChatActive else { return }
        analysisChatActive = false
        // Any phase bubble still showing a spinner is now stale —
        // resolve to a checkmark so the log is in a consistent
        // post-run state.
        for bubbleID in analysisChatPhaseBubbleIDs.values {
            mutateAssistantBubbleIcon(id: bubbleID, icon: "checkmark.circle.fill", tone: .success)
        }
        analysisChatPhaseBubbleIDs = [:]
        analysisChatSeenPhases = []
        // Promote the original "Starting AI analysis…" header too.
        resolveStaleWorkingLines(persist: true)
        appendAnalysisAssistantLine(content, icon: icon, tone: tone, persist: true)
    }

    private func appendAnalysisAssistantLine(
        _ content: String,
        icon: String? = nil,
        tone: EditorChatMessage.IconTone? = nil,
        persist: Bool
    ) {
        _ = appendAnalysisAssistantBubble(content, icon: icon, tone: tone, persist: persist)
    }

    /// Append a new assistant bubble and return it so callers can keep
    /// its id around (used by the analysis log to mutate phase
    /// bubbles in place when their done event arrives). When an
    /// analysis is currently active we skip the
    /// `resolveStaleWorkingLines` sweep — multiple `.working`
    /// bubbles legitimately coexist while transcribe/scene/audio run
    /// in parallel, and demoting them on every append would erase
    /// the live spinners. `finishAnalysisChatBubble` runs the sweep
    /// once at the end of the run instead.
    @discardableResult
    private func appendAnalysisAssistantBubble(
        _ content: String,
        icon: String? = nil,
        tone: EditorChatMessage.IconTone? = nil,
        persist: Bool
    ) -> EditorChatMessage {
        if !analysisChatActive {
            resolveStaleWorkingLines(persist: persist)
        }

        // [diag-2026-05-16] Same diagnostic as mutateAssistantBubble —
        // catch any *newly-appended* bubble that contains "Apple
        // Speech" so we know whether the mid-flight surprise comes
        // from a fresh append (different sub-bug) or an in-place
        // rewrite of an existing transcribe bubble.
        if content.contains("Apple Speech") {
            let stack = Thread.callStackSymbols.dropFirst().prefix(20).joined(separator: "\n     ")
            print("💬 [bubble.append.APPLE_SPEECH] content=\(content) STACK:\n     \(stack)")
        }

        let msg = EditorChatMessage(
            role: .assistant,
            content: content,
            iconSystemName: icon,
            iconTone: tone
        )
        chatMessages.append(msg)
        if persist {
            let store = chatStore
            Task { try? await store?.append(msg) }
        }
        return msg
    }

    /// Update an existing assistant bubble's content/icon/tone in
    /// place. Used by the analysis log to turn `"Analyzing audio —
    /// Started"` into `"Analyzing audio — Done in 10.6s"` (with a
    /// checkmark) the moment that phase's done event arrives, rather
    /// than appending a separate completion line. `nil` for icon or
    /// tone leaves the existing value untouched (so a heartbeat
    /// detail refresh keeps the spinner).
    private func mutateAssistantBubble(
        id: UUID,
        content: String?,
        icon: String?,
        tone: EditorChatMessage.IconTone?
    ) {
        guard let idx = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        // [diag-2026-05-16] If a bubble ever gets rewritten to contain
        // "Apple Speech" text, log the source — this is the lowest-
        // level mutation point, so catching it here means we see
        // EVERY path that produces this string (including paths that
        // bypass updateAnalysisChatBubble entirely).
        if let content, content.contains("Apple Speech") {
            let stack = Thread.callStackSymbols.dropFirst().prefix(20).joined(separator: "\n     ")
            print("💬 [bubble.mutate.APPLE_SPEECH] id=\(id) content=\(content) STACK:\n     \(stack)")
        }
        if let content { chatMessages[idx].content = content }
        if let icon { chatMessages[idx].iconSystemName = icon }
        if let tone { chatMessages[idx].iconTone = tone }
        persistChatRewrite()
    }

    /// Convenience variant for the "stale spinner cleanup" path that
    /// only needs to flip icon + tone, not the content text.
    private func mutateAssistantBubbleIcon(
        id: UUID,
        icon: String,
        tone: EditorChatMessage.IconTone
    ) {
        mutateAssistantBubble(id: id, content: nil, icon: icon, tone: tone)
    }

    /// Best-effort rewrite of the persisted chat file so in-place
    /// mutations (e.g. flipping a phase spinner to a checkmark)
    /// survive relaunch. Called from `mutateAssistantBubble`.
    private func persistChatRewrite() {
        guard let store = chatStore else { return }
        let snapshot = chatMessages
        Task { try? await store.replace(with: snapshot) }
    }

    /// Demote every lingering `.working` assistant bubble (except the
    /// one we're about to append, and except the live-narration
    /// bubble — that one is heartbeat-driven and represents the
    /// *current* phase, not a stale past one) into a `.success`
    /// checkmark so the chat log never shows a spinner on a phase
    /// that has visibly passed. Also persists the mutation when a
    /// chat store is bound.
    private func resolveStaleWorkingLines(persist: Bool) {
        var didMutate = false
        for i in chatMessages.indices {
            guard chatMessages[i].role == .assistant,
                  chatMessages[i].iconTone == .working,
                  !chatMessages[i].isLiveNarration
            else { continue }
            chatMessages[i].iconTone = .success
            chatMessages[i].iconSystemName = "checkmark.circle.fill"
            didMutate = true
        }
        guard didMutate, persist, let store = chatStore else { return }
        // Best-effort rewrite — the persisted chat file is authoritative
        // across relaunches so a mid-session crash shouldn't leave
        // stale spinners baked into history.
        let snapshot = chatMessages
        Task { try? await store.replace(with: snapshot) }
    }

    // MARK: - Workflow-preset kickoff bubbles
    //
    // Several "⚡ shortcut" AI workflows (chapter bar, Auto-PiP, image
    // generation, etc.) bypass the chat agent loop entirely — they just
    // kick off a deterministic pipeline. Before these helpers existed,
    // the only feedback was a toast in `bannerMessage`, so a user who
    // hit ⌘⇧3 or clicked a preset saw nothing in the AI chat panel and
    // couldn't tell the feature had actually run. These two functions
    // let each preset entry-point post a single "user action + working"
    // bubble pair, and then flip the working bubble to success/failure
    // when the pipeline finishes. Keep them in sync with the analysis-
    // chat pattern so stale-spinner cleanup (`resolveStaleWorkingLines`)
    // applies consistently.

    /// Post a synthetic user bubble (what feature was triggered) plus
    /// a live "working" assistant bubble; returns the working bubble's
    /// id so the caller can `finishPresetActionChat` it when the
    /// pipeline finishes. Safe to call from the main actor only.
    @discardableResult
    func beginPresetActionChat(
        userAction: String,
        working: String,
        icon: String = "sparkles"
    ) -> UUID {
        // Any in-flight working bubble from a previous preset is done
        // the moment we start a new one — flip it to the checkmark.
        resolveStaleWorkingLines(persist: true)

        let userMsg = EditorChatMessage(
            role: .user,
            content: userAction,
            iconSystemName: "bolt.fill",
            iconTone: .neutral
        )
        chatMessages.append(userMsg)
        let store = chatStore
        Task { try? await store?.append(userMsg) }

        let live = EditorChatMessage(
            role: .assistant,
            content: working,
            iconSystemName: icon,
            iconTone: .working
        )
        chatMessages.append(live)
        Task { try? await store?.append(live) }
        return live.id
    }

    /// Flip the working bubble created by `beginPresetActionChat` to a
    /// terminal state. No-ops if the bubble has already been removed
    /// (defensive — nothing else should mutate it).
    func finishPresetActionChat(
        id: UUID,
        text: String,
        tone: EditorChatMessage.IconTone,
        icon: String
    ) {
        guard let idx = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[idx].content = text
        chatMessages[idx].iconTone = tone
        chatMessages[idx].iconSystemName = icon
        let snapshot = chatMessages
        let store = chatStore
        Task { try? await store?.replace(with: snapshot) }
    }

    /// Analyze video clips currently on the timeline using a unified
    /// LLM decision across all of them. Transcribes each video
    /// independently, merges transcripts in **timeline order**, then
    /// makes one LLM call so it can detect cross-video duplicates.
    ///
    /// The timeline (not the media library) decides which clips
    /// participate, in what order, and which clips are excluded —
    /// records that exist in the library but were dragged off the
    /// timeline (or never dragged on) are intentionally skipped.
    /// Already-analyzed records (with a non-nil `copilot` snapshot) are
    /// left as-is to avoid re-billing the LLM for clips the user
    /// already ran through.
    ///
    /// Image placements on the timeline are excluded — they have no
    /// audio track to transcribe.
    func analyzeAllRecords() async {
        guard let store, let analysisPipeline else {
            bannerMessage = L("Analysis pipeline not configured")
            finishAnalysisChatBubble(
                content: L("Analysis pipeline not configured."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }
        guard !isAnalyzing else {
            bannerMessage = L("Analysis already in progress.")
            finishAnalysisChatBubble(
                content: L("Analysis already in progress."),
                icon: "exclamationmark.triangle.fill",
                tone: .warning
            )
            return
        }

        // Walk the timeline once, in display order, and collect the
        // first-occurrence list of source video IDs that need work.
        // A record is a candidate iff it's currently on the timeline
        // (videoRecordsOnTimeline already enforces video-only +
        // dedup-by-source) AND ready AND not already analyzed by a
        // real First Cut. Records whose only `copilot` is the
        // transcribe-only stub written by `transcribeForDiarization`
        // (识别说话人) are still candidates — that snapshot exists only
        // to surface a transcript, not a real cut.
        let orderedRecords = videoRecordsOnTimeline.filter {
            $0.status == .ready && ($0.copilot == nil || $0.copilot?.isTranscribeOnly == true)
        }

        // If everything on the timeline is already analyzed (or there's
        // nothing transcribable), just rebuild from existing snapshots
        // and bail early — no LLM call.
        if orderedRecords.isEmpty {
            rebuildTimelineSegments()
            rebuildComposition()
            finishAnalysisChatBubble(
                content: L("ℹ️ All clips were already analyzed. Rebuilt the timeline from existing cuts.")
            )
            return
        }

        isAnalyzing = true
        bannerMessage = nil

        do {
            // Step 1: Transcribe each video independently (sequential for the local ASR engine's memory budget)
            var perVideoLocal: [(record: MediaAssetRecord, result: LocalAnalysisResult)] = []
            let totalClips = orderedRecords.count

            for (i, record) in orderedRecords.enumerated() {
                let sourceURL: URL
                if let proxyPath = record.derived.proxyRelativePath, let root = projectRoot {
                    sourceURL = root.appending(path: proxyPath)
                } else {
                    sourceURL = URL(fileURLWithPath: record.sourcePath)
                }

                guard let analysis = record.analysis else { continue }

                let localResult = try await analysisPipeline.orchestrator.analyze(
                    sourceURL: sourceURL,
                    analysis: analysis,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            let aggregated = AnalysisProgress(
                                phase: progress.phase,
                                fractionComplete: (Double(i) + progress.fractionComplete) / Double(totalClips) * 0.6,
                                detail: L("Clip %d/%d: %@", i + 1, totalClips, progress.detail)
                            )
                            self?.analysisProgress = aggregated
                            self?.updateAnalysisChatBubble(aggregated)
                            // Chat live-narration path — forwarded
                            // per-clip so each transition updates the
                            // in-place bubble.
                            self?.liveNarrationCallback?(progress.phase)
                        }
                    }
                )

                perVideoLocal.append((record: record, result: localResult))
            }

            // Step 2: Merge all transcripts with source tagging
            var mergedTranscript: [TranscriptSegment] = []
            var mergedRawWords: [TranscriptSegment] = []

            for (record, localResult) in perVideoLocal {
                // Tag each segment with its source video ID
                let tagged = localResult.transcript.map { seg in
                    TranscriptSegment(
                        startSeconds: seg.startSeconds,
                        endSeconds: seg.endSeconds,
                        text: seg.text,
                        sourceVideoID: record.id
                    )
                }
                mergedTranscript.append(contentsOf: tagged)

                let taggedWords = localResult.rawWordTranscript.map { seg in
                    TranscriptSegment(
                        startSeconds: seg.startSeconds,
                        endSeconds: seg.endSeconds,
                        text: seg.text,
                        sourceVideoID: record.id
                    )
                }
                mergedRawWords.append(contentsOf: taggedWords)
            }

            // Step 3: Unified LLM call across all videos
            let llmProgress = AnalysisProgress(
                phase: .requestingAI,
                fractionComplete: 0.7,
                detail: L("AI analyzing %d segments across %d clips…", mergedTranscript.count, totalClips)
            )
            analysisProgress = llmProgress
            updateAnalysisChatBubble(llmProgress)
            liveNarrationCallback?(.requestingAI)

            let config = OpenAIConfiguration.fromEnvironment()
            var editDecision: LLMEditorService.EditDecision?

            if let config, !mergedTranscript.isEmpty {
                let client = OpenAIClient(configuration: config)
                let llmEditor = LLMEditorService(client: client)

                // Build source name lookup for LLM context
                var sourceNames: [UUID: String] = [:]
                for (i, (record, _)) in perVideoLocal.enumerated() {
                    let fileName = record.sourcePath.components(separatedBy: "/").last ?? "Clip \(i + 1)"
                    let name = "Clip\(i + 1):\(fileName)"
                    sourceNames[record.id] = name
                }

                do {
                    editDecision = try await llmEditor.selectSegments(mergedTranscript, sourceNames: sourceNames)

                    // Log
                    if let ed = editDecision {
                        print("\n📋 === Unified AI Edit Decision (\(totalClips) clips) ===")
                        print("✅ KEEP (\(ed.keepIndices.count) segments):")
                        for idx in ed.keepIndices.sorted() {
                            if idx < mergedTranscript.count {
                                let seg = mergedTranscript[idx]
                                let srcLabel = perVideoLocal.first(where: { $0.record.id == seg.sourceVideoID })
                                    .map { $0.record.sourcePath.components(separatedBy: "/").last ?? "?" } ?? "?"
                                print("  [\(idx)] [\(srcLabel)] \(String(format: "%.1f", seg.startSeconds))s–\(String(format: "%.1f", seg.endSeconds))s: \(seg.text)")
                            }
                        }
                        print("\n❌ CUT (\(ed.cuts.count) segments)")
                        print("========================\n")
                    }
                } catch {
                    print("⚠️ LLM editor failed: \(error)")
                }
            }

            // Step 4: Build per-record snapshots from the unified decision
            for (record, localResult) in perVideoLocal {
                // Find which merged indices belong to this record
                let recordKeepIndices: [Int]
                let recordCuts: [LLMEditorService.EditDecision.Cut]

                if let ed = editDecision {
                    // Map global indices back to per-record transcript indices
                    let globalIndicesForRecord = mergedTranscript.enumerated()
                        .filter { $0.element.sourceVideoID == record.id }
                        .map { $0.offset }

                    let localTranscriptCount = localResult.transcript.count
                    var localKeep: [Int] = []
                    var localCuts: [LLMEditorService.EditDecision.Cut] = []

                    for (localIdx, globalIdx) in globalIndicesForRecord.enumerated() {
                        guard localIdx < localTranscriptCount else { continue }
                        if ed.keepIndices.contains(globalIdx) {
                            localKeep.append(localIdx)
                        } else if let cut = ed.cuts.first(where: { $0.index == globalIdx }) {
                            localCuts.append(LLMEditorService.EditDecision.Cut(index: localIdx, reason: cut.reason))
                        }
                    }

                    recordKeepIndices = localKeep
                    recordCuts = localCuts
                } else {
                    // No LLM: keep all
                    recordKeepIndices = Array(0..<localResult.transcript.count)
                    recordCuts = []
                }

                let perRecordDecision = LLMEditorService.EditDecision(
                    keepIndices: recordKeepIndices,
                    cuts: recordCuts
                )

                let snapshot = CopilotSnapshotBuilder.fromAnalysisAndEdit(
                    local: localResult,
                    editDecision: perRecordDecision
                )

                var manifest = try store.loadManifest()
                if let idx = manifest.media.firstIndex(where: { $0.id == record.id }) {
                    manifest.media[idx].copilot = snapshot
                    manifest.media[idx].status = .ready
                    try store.saveManifest(manifest)
                }
            }

            await loadRecords()
            rebuildTimelineSegments()

            // Auto-detect speakers as part of the first cut so the
            // transcript shows distinct speakers immediately. Best-
            // effort and silent on failure; happens before the
            // success bubble so the line "Identifying speakers"
            // appears in the chat trail above the final summary.
            await runDiarizationDuringFirstCut()

            isAnalyzing = false
            analysisProgress = nil

            if !timelineSegments.isEmpty {
                rebuildComposition()
                bannerMessage = nil
                finishAnalysisChatBubble(
                    content: L("Analysis complete — kept %d segments across %d clips. You can now chat to refine the cut.", timelineSegments.count, totalClips),
                    icon: "checkmark.seal.fill",
                    tone: .success
                )
            } else {
                bannerMessage = L("AI analysis complete but no segments were kept.")
                finishAnalysisChatBubble(
                    content: L("Analysis finished but no segments were kept."),
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning
                )
            }
        } catch {
            isAnalyzing = false
            analysisProgress = nil
            bannerMessage = L("Analysis failed: %@", error.localizedDescription)
            finishAnalysisChatBubble(
                content: L("Analysis failed: %@", error.localizedDescription),
                icon: "xmark.octagon.fill",
                tone: .failure
            )
        }
    }

    /// Handle a user prompt from the AI command bar.
    func handleAIPrompt(_ prompt: String, displayAs: String? = nil) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Reentry guard. Workflow-preset plain-clicks now auto-send
        // (rather than fill the composer), so a quick double-click on
        // a preset row — or an accidental ⌘⇧2/⌘⇧3 double-press —
        // could otherwise spawn parallel agent loops sharing the same
        // viewmodel state. The manual chat composer's `sendMessage`
        // path doesn't have a built-in gate either, so this also
        // hardens that flow.
        guard !isChatProcessing else { return }

        // Always echo the user's own prompt into the chat log first —
        // before any guards — so the user sees their message appear
        // even on the "timeline still empty, kick off analysis first"
        // path that used to silently swallow the prompt.
        //
        // `displayAs` lets internal callers (e.g. "Generate animation
        // from B-roll suggestion") show the user only their own
        // editable slice while the full scaffolded instruction still
        // goes to the LLM via `content`.
        let trimmedDisplay = displayAs?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMsg = EditorChatMessage(
            role: .user,
            content: trimmed,
            displayContent: (trimmedDisplay?.isEmpty == false) ? trimmedDisplay : nil
        )
        chatMessages.append(userMsg)
        try? await chatStore?.append(userMsg)

        isChatProcessing = true

        // Spawn a single live-narration bubble that will walk the
        // user through the whole journey — analysis phases (if we
        // need to analyse first) and then each tool-call step of the
        // agent loop. `runAgentLoop` adopts this id so it updates in
        // place instead of spawning a second bubble.
        let isEnglish = Self.currentAppLanguageIsEnglish()
        let needsAnalysis = timelineSegments.isEmpty && revisions.isEmpty
        let liveBubbleID = UUID()
        let initialLive = needsAnalysis
            ? (isEnglish ? "Analyzing your clips…" : "正在分析素材")
            : (isEnglish ? "Thinking…" : "我在想一下")
        let liveBubble = EditorChatMessage(
            id: liveBubbleID,
            role: .assistant,
            content: initialLive,
            iconTone: .working,
            isLiveNarration: true
        )
        chatMessages.append(liveBubble)

        // If there is neither a timeline nor restore checkpoints yet,
        // analyse first and narrate each phase into the same live
        // bubble. Failure → lock the bubble to a failure state and
        // bail out (no agent loop runs).
        if needsAnalysis {
            // Phase-start hook: every time the pipeline enters a new
            // phase, swap the bubble text AND start a fresh heartbeat
            // for that phase so the line rotates every ~2s during the
            // long underlying work (transcription is the main offender).
            liveNarrationCallback = { [weak self] phase in
                guard let self else { return }
                let phrases = Self.heartbeatPhrases(forPhase: phase, english: isEnglish)
                self.heartbeatStart(bubbleID: liveBubbleID, phrases: phrases)
            }

            let candidates = videoRecordsOnTimeline
            if candidates.count > 1 {
                await analyzeAllRecords()
            } else if let only = candidates.first {
                await analyzeRecord(id: only.id)
            } else {
                // Nothing on the timeline yet — lock the bubble with
                // a polite failure line and stop. The user has to
                // drag a clip from the library to the timeline (or
                // import one, which auto-appends) before chat can
                // edit anything.
                liveNarrationCallback = nil
                lockLiveNarrationAsFailure(
                    id: liveBubbleID,
                    text: isEnglish
                        ? "Drag a clip onto the timeline first, then I can edit."
                        : "请先把素材拖到时间线上，我才能开始剪。"
                )
                isChatProcessing = false
                return
            }
            liveNarrationCallback = nil
            heartbeatCancel()

            // If analysis didn't produce a timeline the agent has
            // nothing to edit. Lock the live bubble as failure and
            // stop — don't run the agent loop on an empty timeline.
            if timelineSegments.isEmpty {
                lockLiveNarrationAsFailure(
                    id: liveBubbleID,
                    text: isEnglish
                        ? "Analysis finished but no segments were kept."
                        : "分析完了但没留下可用片段，再检查下素材吧。"
                )
                isChatProcessing = false
                return
            }

            // Move the narration into the edit phase so the user
            // feels the hand-off without an awkward pause.
            updateLiveNarration(
                id: liveBubbleID,
                text: isEnglish ? "Planning the edit…" : "准备开剪"
            )
        }

        // Build context for the LLM
        let segmentsSummary: String
        if timelineSegments.isEmpty {
            segmentsSummary = "No timeline segments currently loaded."
        } else {
            segmentsSummary = timelineSegments.enumerated().map { i, seg in
                let srcName = records.first(where: { $0.id == seg.sourceVideoID })?.sourcePath.components(separatedBy: "/").last ?? "?"
                return "  [\(i)] id=\(seg.id.uuidString) [\(srcName)] \(String(format: "%.1f", seg.range.startSeconds))s–\(String(format: "%.1f", seg.range.endSeconds))s (\(String(format: "%.1f", seg.durationSeconds))s): \(seg.text.prefix(80))"
            }.joined(separator: "\n")
        }

        let composedContext = composedIndex.agentContext(
            sourceNames: Dictionary(uniqueKeysWithValues: records.map { r in
                (r.id, r.sourcePath.components(separatedBy: "/").last ?? r.id.uuidString.prefix(8).description)
            })
        )
        let restoreCheckpoints = availableRestoreCheckpoints(limit: 12)
        let restoreCheckpointSummary = restoreCheckpointContext(limit: 12)

        // BYOK users opted out of the Cutti Cloud subscription stack,
        // including the cloud Remotion renderer and the proprietary
        // animation skill pack. Strip the animation-related tool
        // descriptions so the LLM doesn't suggest, plan, or even know
        // about features the user can't invoke. The hard runtime gates
        // (`makeOverlayCache`, `executeAgentToolCall` provider check)
        // catch malicious / fabricated calls; this prompt edit just
        // keeps the well-behaved path quiet.
        let animationToolBullets: String
        if CuttiSettings.aiProvider() == .custom {
            animationToolBullets = ""
        } else {
            animationToolBullets = """

        - generate_overlay: 渲染 Remotion 模板（章节标题卡等动画 overlay）并落到 overlay 轨。用于做"章节标题/小节卡片"这类动效，不是用来插已导入的视频素材。\(RemotionOverlayCatalog.systemPromptDescription)
        - update_overlay_props: 修改已存在 AI overlay 的 props（比如改标题文字、换主题色）。只改动 props，segment 的 id / 位置 / 时长都保持不变。需要 segment_id（overlay segment 的 UUID）和 props_patch（JSON 对象，与现有 props 合并）。
        """
        }
        let animationSkillBullet: String
        if CuttiSettings.aiProvider() == .custom {
            animationSkillBullet = ""
        } else {
            animationSkillBullet = """

        - list_animation_rules / read_animation_rule: 内部 Remotion 动画 skill。先 list 拿目录（rules / style-guide / templates / plugins / workflow），再 read 你需要的那一篇。常用入口：`rules/cutti-staging`（入场/hold/出场节奏、stagger、parallax）、`rules/cutti-templates`（house style + 模板路由表）、`rules/cutti-constraints`（Remotion 硬约束、calculateMetadata clamp）、`rules/cutti-fonts`（字体目录）、`rules/cutti-checklist`（合并前自检），通用条目：`rules/animations`、`rules/measuring-text`、`rules/transparent-videos` 等。**用户直接问"show me the animation guide / 动画方法论 / 你是怎么做动画的 / 哪种模板合适 / 怎么安排节奏"等**：先 list_animation_rules，再 read 对应条目把内容拿回来再回答。**自己做决策时**（选模板、算 item atSeconds、拿不准 house style）：read 相关条目作为参考，再产出 generate_overlay。不需要用户确认。
        """
        }

        let systemPrompt = """
        你是一个AI视频剪辑助手。你必须把用户的自然语言编辑指令翻译成结构化 timeline 动作，或者在需要时恢复之前的 checkpoint。你可以多步调用工具——先用查询工具收集信息，再用 edit_timeline 提交修改。

        ## 当前时间线状态
        总时长: \(String(format: "%.1f", composedIndex.totalDuration))s
        片段数: \(timelineSegments.count)

        ## 片段列表（按时间线顺序）
        \(segmentsSummary)

        ## 合成时间线索引
        \(composedContext)

        ## 可恢复的 checkpoint（最新在前）
        \(restoreCheckpointSummary)

        ## 可用工具
        - edit_timeline: 改时间轴或字幕（详见 schema）
        - restore_checkpoint: 恢复历史快照
        - insert_broll: 在主轨上叠加 B-roll / 空镜（需要已导入素材的 media_id）\(animationToolBullets)
        - generate_image: 用 FLUX 文生图生成一张静态图（JPG/PNG）。用户描述想要"一张 XX 图 / 一张照片 / 一张插画 / 背景图"时用这个工具；不要用来做动态标题卡（那是 generate_overlay）。如果用户只说"生成一张图"但没告诉你画什么，应该先用普通回复问清楚再调；prompt 参数传英文详细描述。可选参数 composed_time：给了就把图当 4 秒 overlay 插到那个位置，不给就只放进 Media Browser 让用户自己拖。
        - insert_crossfade: 给两段相邻 segment 加交叉淡入淡出（from_segment_id, to_segment_id, duration）
        - find_filler_words: 找填充词（uh / 嗯 / 啊 等），返回每条 cue 的 composed-time
        - find_by_transcript: 按字幕文本子串搜索
        - get_timeline_summary: 获取整体统计
        - get_segment_detail: 查单个 / 多个 segment 的详细状态（volume, speed, fade, 颜色, speaker …）
        - score_hook_candidates: 在所有原始素材里给"开场金句 / 冷开 hook"打分排序，返回 top-K 候选（含 length / position / anti-filler / energy 子分数与 1 行理由）。当用户希望 AI 自主挑选而非自己指明那一句时使用（"AI 自己挑句开场金句""帮我挑个 hook""加个开场钩子"）。本工具只读，不会改时间线；要把候选真正放到开头，再调 add_hook_teaser。**用户已经指明了某段（"把 pricing 那段放开头"）就用 find_by_transcript，不要用本工具。** 在选定范围（chat 上方有附件 chip）下被禁用——需要先取消附件。
        - add_hook_teaser: 把 score_hook_candidates 选出的某条候选作为冷开金句插到时间线最前面。参数从用户挑中的那条候选拿（source_video_id / source_start / source_end）。**永远只产生 Pending proposal，从不自动应用**——即便处于 Auto-Apply 模式也一样。生成后必须等用户点 Apply 才能继续；同一轮里不要再发别的破坏性编辑。如果用户接着要 Quote overlay 或 SFX，等他点 Apply 之后再单独调 generate_overlay 等工具。在选定范围下被禁用。
        - find_black_frames: 找画面接近黑屏的时间段（掉帧/盖镜头/渐黑）
        - find_empty_frames: 找没有人脸的时间段（用于 B-roll 替补 / 剪空镜）
        - find_scene_changes: 找画面剧烈变化的切点（建议自然剪辑点）
        - set_segment_volume: 调单段音量（0.0 静音 ~ 2.0 放大）
        - audio_ducking: 让 BGM 在说话时降到 duck_level（默认全体 audio 轨）
        - normalize_loudness: 把成片整体响度归一到 target_db（默认 -16 dB）
        - get_frame_at: 采样 composed_time 处的一张 JPEG 缩略图，用于画面类判断
        - detect_speakers: 基于停顿做说话人分段
        - find_by_speaker: 列出某个 speaker_id 的全部字幕 cue
        - mute_speaker: 把某个 speaker 主导的 segment 静音（或走确认后删除）
        - suggest_title: 产出 3 个候选标题（不会修改项目）
        - suggest_chapters: 产出 N 个章节点（不会修改项目）
        - run_first_cut: 跑完整 AI 第一刀流水线（转写 → 镜头/音频分析 → 4 趟 LLM 清理），自动删静音/重复/半截话。慢（转写为主）。会推一个 checkpoint，所以可以 restore 回来。\(animationSkillBullet)

        ## 规则
        - 默认所有时间都指"最终成片时间线"，不是源视频时间。
        - 用户说"第2分钟到第3分钟"时，换算成 start_time=120, end_time=180。
        - 明确的时间范围删除，优先用 delete_range；变速用 set_speed_range。
        - 调单段音量用 set_segment_volume；整体响度归一用 normalize_loudness；BGM 让位说话用 audio_ducking。
        - 要改某个 segment 的属性前，先用 get_segment_detail 查当前值，避免盲改。
        - 画面类问题（构图 / 画质 / 是否空镜）用 get_frame_at 抽帧再判断，不要靠想象。
        - 涉及说话人（某人说的 / 谁在发言）先 detect_speakers 再 find_by_speaker / mute_speaker。
        - **诊断 / 查询工具返回空或 not-ready 时，不要自动升级到更重的工具去满足它**。例：find_by_transcript / find_by_speaker / find_filler_words 无结果，不要自动转录或重剪；mute_speaker 找不到目标 segment 也是同样道理。这种情况下停止 tool 循环，用自然语言告诉用户为什么做不了、并询问是否愿意运行那个更重的步骤（比如先做 First Cut）。**用户没明确点头之前一律不能调 run_first_cut / run_full_analysis 这类会重写整个时间线的工具。** detect_speakers 自己会在没有转录时先做最小转录再识别，不要替它去 run_first_cut。
        - 用户要求"删掉所有 uh / 嗯 / 啊"这类按内容批量操作时，先调用 find_filler_words 拿到具体 cue 列表，再用 delete_range 按 composed_start..composed_end 一条条删除（或合并临近的）。
        - 用户用"我说到 X 的那段"指代时，先 find_by_transcript 找到 cue。
        - 用户问"我现在的剪辑多长 / 哪段最啰嗦"等粗略问题，先 get_timeline_summary。
        - 用户给出**模糊的"帮我剪一下 / 自动剪 / 整理一下 / 清一清"**这类整体性请求时，调用 `run_first_cut` 让 AI 流水线自动出第一刀；不要自己用 delete_range 一段段拼。
        - 不要凭空捏造数量；要给具体计数前先查询。
        - 用户要求"撤销 / undo / 回到上一步"时，调用 restore_checkpoint，优先使用 checkpoint_index=0。
        - 用户说"把 X 那段放到开头/结尾/挪到 Y 前面"这类重排需求时,先用 find_by_transcript 定位目标 segment_id,再 get_timeline_summary 拿到当前全部 segment_id 顺序,然后用 edit_timeline.reorder_segments 提交完整重排后的 ID 列表(必须涵盖每一个现有 segment,不多不少)。
        - 工具返回 preflight_failed 时，按 issues 中的 message 修正参数后重试一次；两次还失败就说明原因。
        - 只对明确可执行的请求调用工具；不要返回纯解释文字（**例外见下方"复合请求 & 能力边界"**）。
        - explanation 要简短直接。

        ## 复合请求 & 能力边界（重要）
        你运行在一个 **multi-step agent loop** 里：每一轮你可以返回**一个或多个并行 tool_calls**，系统会执行它们并把结果喂回给你，你再决定下一步。最多可以连续跑 15 个 step 才必须收尾。一旦你返回**没有 tool_calls** 的回复，loop 在做一次自检后结束（见下方"自检机制"）。

        - **第一步先做计划**：在 explanation 或内部推理里把用户请求拆成所有子意图（"双语字幕" = ① 翻译每条 cue ② 开启 bilingual 样式 ③ 设置 placement / size_ratio）。扫一遍 `## 可用工具`，标注每个子意图是有工具 / 缺工具。
        - **每一步只调实际需要的 tool_calls**，能并行的就并行，必须串行依赖前一步结果的就一步一步来。**不要**为了凑数硬塞工具。
        - **计划没跑完之前，绝对不能返回没有 tool_calls 的回复**——那会导致 loop 提前终止，用户只看到一半的成果。
        - 所有能做的子意图都执行完后，才返回最终的纯文本回复收尾 loop。
        - **每个 tool_call 都会产生独立的 batch / commit，用户会在 chat 里看到一串 Apply 单元——这是预期行为，不是问题**。不要为了"只给用户一个 Apply"而省略后续步骤。

        ### 部分能力缺失的处理
        - **部分**子意图缺工具：在第一步的 explanation 里**明确说明**"X 做不了因为目前没有对应工具，能做的是 Y"，然后**继续把 Y 的所有步骤跑完**（可能跨多个 agent step），全部跑完后再收尾。**不要**只发文字什么都不动；也**不要**默默只做 Y 然后说"完成"假装请求被满足。
        - **全部**子意图都缺工具：本轮直接返回纯文本说明 + 询问替代方案，不调用任何工具。
        - **禁止**为了让请求看起来被满足而挑一个相邻工具糊弄用户（例如：用户要翻译却只调字号、用户要变速却调音量）。

        ## 双语字幕（bilingual subtitles）
        当用户要求双语字幕（如"中英双语"/"中文放英文下面"/"给我加一行中文翻译"/"加个英文翻译"）时，**必须按顺序调用两步工具**：
        1. `translate_subtitles`：生成指定 `target_locale` 的译文。默认 `force=false`，只翻译尚未包含该语言译文的 cue，保证可重复安全调用。
        2. `edit_timeline` 的 `set_subtitle_style`：设置 `bilingual=true` 并给出 `bilingual_secondary_locale`（与上一步的 `target_locale` 保持一致），按需附带 `bilingual_placement`（`below` = 译文在下，`above` = 译文在上）、`bilingual_secondary_size_ratio`（0.4–1.0，通常 0.7–0.8 让译文略小）。
        两步**顺序不能颠倒**、**不能只做其一**：只翻译不开样式，UI 仍然单行；只开样式不翻译，副行永远空白。
        常见的 `target_locale`：`zh-Hans`（简中）、`zh-Hant`（繁中）、`en-US`、`ja`、`ko`、`es`、`fr`、`de`。

        ## 示例
        - "删掉 2:10 到 2:45" → edit_timeline.delete_range(start_time: 130, end_time: 165)
        - "把所有 uh 删掉" → 1) find_filler_words → 2) edit_timeline.delete_range 多条
        - "把 5:00 到 5:20 调成 1.5 倍速" → set_speed_range(start_time: 300, end_time: 320, rate: 1.5)
        - "把我讲 pricing 那段放到开头做 intro" → 1) find_by_transcript("pricing") 拿到 segment_id → 2) get_timeline_summary 拿到全部 segment_ids → 3) edit_timeline.reorder_segments(segment_ids: [pricing_id, ...其余保持原顺序])
        - "AI 自己挑一句最有冲击力的开场金句放开头" → 1) score_hook_candidates(top_k: 5) → 2) 用候选清单（含 reason）问用户挑哪一条 → 3) add_hook_teaser(source_video_id, source_start, source_end)（始终是 Pending proposal，等用户点 Apply）
        - "撤销上一步" → restore_checkpoint(checkpoint_index: 0)
        - "帮我剪一下 / 给我自动剪个第一版" → run_first_cut()
        - "我又导了几个素材，重新出一版第一刀" → run_first_cut()
        - "我想要中英文字幕，中文小一点放英文下面" → 1) translate_subtitles(target_locale: "zh-Hans") → 2) edit_timeline.set_subtitle_style(bilingual: true, bilingual_secondary_locale: "zh-Hans", bilingual_placement: "below", bilingual_secondary_size_ratio: 0.75)
        - "把这句字幕里的'重要'标红加粗" → emphasize_words(cue_id: "...", words: ["重要"], style: {weight: "bold", text_color: "#FF3B30"})
        - "所有字幕里的'okay'改成黄色高亮" → 先 find_by_transcript("okay") 拿到 cue_ids → 每个 cue 调一次 emphasize_words(cue_id: ..., words: ["okay"], style: {highlight_background: "#FFD60033"})
        - "清掉这句的字幕样式" → emphasize_words(cue_id: "...", clear_all: true)
        """

        // If the user has dragged segments onto the composer, append a
        // strict "attached scope" override. Times in the user prompt are
        // then interpreted as segment-local / virtual time, and the LLM
        // is required to translate them to composed time via the mapping
        // table below before calling any tool.
        let scope = chatAttachmentScope
        let scopedSystemPrompt: String
        if !scope.isEmpty {
            let mappingLines = scope.entries.enumerated().map { idx, e in
                let srcName: String
                if let sid = timelineSegments.first(where: { $0.id == e.segmentID })?.sourceVideoID,
                   let r = records.first(where: { $0.id == sid }) {
                    srcName = r.sourcePath.components(separatedBy: "/").last ?? "?"
                } else {
                    srcName = "?"
                }
                return String(
                    format: "  [%d] virtual %.2fs–%.2fs  ↔  composed %.2fs–%.2fs (segment %@, from %@)",
                    idx,
                    e.virtualStart, e.virtualEnd,
                    e.composedStart, e.composedEnd,
                    e.segmentID.uuidString,
                    srcName
                )
            }.joined(separator: "\n")

            let scopeBlock = """

            ## ⚠️ ATTACHED SCOPE (严格独占，覆盖前面所有规则)
            用户已在 AI 聊天窗口附加了 \(scope.entries.count) 个 segment。你现在**只能**操作这些 segment，不得改动时间线上的其它任何内容。

            ### 虚拟时间线
            总时长: \(String(format: "%.2f", scope.virtualDuration))s（多个 segment 按附加顺序首尾相接，形成一条连续的虚拟时间线）

            用户在 prompt 中提到的时间一律是 **虚拟时间（segment-local，从 0 开始）**，不是 composed 时间。
            例：若用户说"删 2 秒到 5 秒"，指的是虚拟时间 [2s, 5s]。

            ### 虚拟 ↔ composed 映射（调用工具前必须翻译）
            \(mappingLines)

            ### 翻译规则
            - 对工具调用传入的任何 time 参数，把虚拟时间 v 翻译成 composed 时间 c：
              找到包含 v 的条目（entry.virtualStart ≤ v ≤ entry.virtualEnd），
              然后 c = entry.composedStart + (v - entry.virtualStart)。
            - 如果虚拟范围跨越多个 entry，拆成多次工具调用，每次一个 entry。
            - 所有 find_* 查询工具返回的是 composed 时间；在向用户汇报时，把 composed 时间反向翻译回虚拟时间再展示。
            - 严禁操作超出虚拟时间线 [0, \(String(format: "%.2f", scope.virtualDuration))s] 的范围；用户请求落在外面时，礼貌拒绝并说明"该时间超出附加范围"。
            - 片段列表和合成时间线索引里**仅**以下 segment 对你可见：\(scope.entries.map { $0.segmentID.uuidString }.joined(separator: ", "))。其它 segment 视作不存在。
            """
            scopedSystemPrompt = systemPrompt + scopeBlock
        } else {
            scopedSystemPrompt = systemPrompt
        }

        // Append a live-narration directive so the model emits short,
        // casual status lines between tool calls. These are surfaced to
        // the user in an in-place "live" chat bubble; the substantive
        // reply still lands in the final turn without tool calls.
        let narrationDirective = Self.liveNarrationSystemDirective()
        let narratedSystemPrompt = scopedSystemPrompt + "\n\n" + narrationDirective

        // Build chat history for context
        let recentHistory = chatMessages.suffix(10).map { msg -> ChatMessage in
            switch msg.role {
            case .user: return .user(msg.content)
            case .assistant: return .assistant(msg.content)
            case .system: return .system(msg.content)
            }
        }

        // Call LLM with edit_timeline tool
        guard let config = OpenAIConfiguration.fromEnvironment() else {
            lockLiveNarrationAsFailure(
                id: liveBubbleID,
                text: isEnglish
                    ? "OpenAI API not configured. Open Settings to add a key."
                    : "还没配置 OpenAI 接入，先在设置里加上 Key。"
            )
            let errMsg = EditorChatMessage(
                role: .assistant,
                content: "OpenAI API not configured. Please check settings.",
                iconSystemName: "exclamationmark.triangle.fill",
                iconTone: .warning
            )
            chatMessages.append(errMsg)
            isChatProcessing = false
            return
        }

        let client = OpenAIClient(configuration: config)

        do {
            var messages: [ChatMessage] = [.system(narratedSystemPrompt)]
            messages.append(contentsOf: recentHistory)

            let tools = Self.agentToolDefinitions(for: CuttiSettings.aiProvider())

            try await runAgentLoop(
                client: client,
                tools: tools,
                messages: &messages,
                userMessageID: userMsg.id,
                maxSteps: 15,
                existingLiveBubbleID: liveBubbleID
            )
        } catch {
            let display: String
            if let oaiError = error as? OpenAIClientError {
                display = oaiError.displayMessage
            } else {
                display = error.localizedDescription
            }
            let errMsg = EditorChatMessage(
                role: .assistant,
                content: display,
                iconSystemName: "exclamationmark.triangle.fill",
                iconTone: .warning
            )
            chatMessages.append(errMsg)
            try? await chatStore?.append(errMsg)
        }

        isChatProcessing = false
    }

    /// Drive the LLM through a multi-step tool-calling loop. After each
    /// assistant turn that contains tool calls, execute them, append the
    /// results to the running conversation, and call the LLM again until it
    /// stops calling tools (or `maxSteps` is reached).
    ///
    /// `messages` is mutated in place so the conversation accumulates across
    /// the loop. Per-tool side effects (timeline mutations, restores) push
    /// their own revisions, and a chat bubble is appended for each step so
    /// the user sees the Agent's reasoning trace.
    private func runAgentLoop(
        client: OpenAIClient,
        tools: [ToolDefinition],
        messages: inout [ChatMessage],
        userMessageID: UUID,
        maxSteps: Int,
        existingLiveBubbleID: UUID? = nil
    ) async throws {
        // Reuse an externally-supplied live bubble when one exists
        // (chat path where analysis was run first into the same
        // bubble), otherwise spawn a fresh one. Either way the
        // bubble's id is stable for the duration of this turn.
        let isEnglish = Self.currentAppLanguageIsEnglish()
        let liveBubbleID: UUID
        if let existingLiveBubbleID {
            liveBubbleID = existingLiveBubbleID
        } else {
            liveBubbleID = UUID()
            let initialNarration = isEnglish ? "Thinking…" : "我在想一下"
            let liveBubble = EditorChatMessage(
                id: liveBubbleID,
                role: .assistant,
                content: initialNarration,
                iconTone: .working,
                isLiveNarration: true
            )
            chatMessages.append(liveBubble)
            // Live bubble intentionally not persisted until it locks —
            // we don't want in-progress narration to bleed into
            // relaunches.
        }

        // Defensive cleanup: if anything below throws, the outer catch
        // in `handleAIPrompt` shows an error bubble, but the live
        // bubble would be left spinning forever. Remove it on error
        // path so the chat log doesn't get stuck with a ghost spinner.
        do {
            try await runAgentLoopBody(
                client: client,
                tools: tools,
                messages: &messages,
                userMessageID: userMessageID,
                maxSteps: maxSteps,
                liveBubbleID: liveBubbleID,
                isEnglish: isEnglish
            )
        } catch {
            heartbeatCancel()
            removeLiveNarration(id: liveBubbleID)
            throw error
        }
    }

    /// Inner loop body so we can wrap it in a cleanup-on-throw do/catch
    /// without messing with the top-level spinner bookkeeping.
    private func runAgentLoopBody(
        client: OpenAIClient,
        tools: [ToolDefinition],
        messages: inout [ChatMessage],
        userMessageID: UUID,
        maxSteps: Int,
        liveBubbleID: UUID,
        isEnglish: Bool
    ) async throws {
        // Per-turn bookkeeping so we can honestly label the terminal
        // live-narration bubble. Used by `lockLiveNarrationHonestly`
        // below to decide success vs "awaiting your review" vs
        // "partially applied".
        var emittedProposalThisTurn = false
        var emittedCommitThisTurn = false
        // Reflection is the safety net for compound requests: when the
        // model returns no tool_calls after doing some work, we ask it
        // ONCE more "compare what you did to the original ask, fill any
        // gaps". Without this, gpt-5.4-mini routinely stops after the
        // first sub-intent of a 3-intent request and declares victory.
        // Single-shot — never re-reflect, otherwise pure-text turns
        // would loop forever.
        var hasReflectedThisTurn = false

        for step in 0..<maxSteps {
            // Phase-START narration for the LLM round itself. Even
            // the first `chatCompletion` can take 5–10s with many
            // tools registered; a heartbeat keeps the bubble moving
            // while the LLM is thinking about what to call next.
            let thinkingPhrases: [String]
            if step == 0 {
                thinkingPhrases = isEnglish
                    ? ["Planning the edit…", "Looking at your timeline…", "Picking the right tool…"]
                    : ["准备开剪", "看下时间线", "挑合适的工具"]
            } else {
                thinkingPhrases = isEnglish
                    ? ["Thinking about the next step…", "Reading the tool result…", "Deciding what's next…"]
                    : ["想下一步", "看刚才的结果", "决定下一步怎么剪"]
            }
            heartbeatStart(bubbleID: liveBubbleID, phrases: thinkingPhrases)

            let response = try await client.chatCompletion(
                messages: messages,
                tools: tools,
                temperature: 0.3,
                task: .agent
            )
            heartbeatCancel()

            if response.toolCalls.isEmpty {
                // Reflection safety net: if the model is trying to
                // terminate after doing real work, force it to re-read
                // the user's original ask and verify every sub-intent
                // got covered. Catches the gpt-5.4-mini failure mode
                // of stopping after the first sub-intent of a compound
                // request. One-shot per turn (never recurse — pure
                // text replies and "no, really, I'm done" responses
                // would otherwise loop forever).
                let didWorkThisTurn = emittedProposalThisTurn || emittedCommitThisTurn
                let stepsRemaining = maxSteps - step - 1
                if didWorkThisTurn && !hasReflectedThisTurn && stepsRemaining > 0 {
                    hasReflectedThisTurn = true
                    // Echo the model's would-be terminal text back into
                    // history so the next turn can see its own state-
                    // ment, then push the reflection user message.
                    if let terminalContent = response.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !terminalContent.isEmpty {
                        messages.append(ChatMessage(
                            role: "assistant",
                            content: terminalContent,
                            toolCalls: nil,
                            toolCallId: nil
                        ))
                    }
                    let reflectionPrompt = isEnglish
                        ? """
                        Self-check before you finish: re-read the user's ORIGINAL message at the top of this turn and list every distinct sub-intent it contains. For each sub-intent, did the tool calls you made so far actually cover it?

                        - If ANY sub-intent is missing, only partially done, or you skipped it because you weren't sure — emit the needed tool_calls RIGHT NOW to finish it. Don't ask permission, don't apologize, just do it.
                        - If a sub-intent genuinely cannot be done with the available tools, that's fine — but say so explicitly in your terminal text reply, don't silently drop it.
                        - If everything is genuinely covered, reply with normal text (no tool_calls) and the loop ends.

                        This is your one and only reflection check; after this you cannot self-correct again this turn.
                        """
                        : """
                        收尾前自检：回到这一轮**最开始**那条用户消息，列出它包含的每一个独立子意图。对照你刚才调过的 tool_calls，每一项有没有真的做？

                        - 如果**有任何**子意图没做、只做了一半、或者你因为不确定而跳过了——**现在**就 emit 需要的 tool_calls 把它做完，不用问、不用道歉，直接做。
                        - 如果某个子意图确实没有对应工具能做，没关系——但要在最后的文本回复里**明确说**，不要悄悄丢掉。
                        - 如果确实全部都做完了，正常回复纯文本（不带 tool_calls），loop 自然结束。

                        这是你这一轮**唯一一次**自检机会，过了这次就不能再补做了。
                        """
                    messages.append(.user(reflectionPrompt))
                    continue
                }

                // Terminal turn: pick an honest lock state based on
                // what actually happened this turn + whether the
                // model's own terminal text hedged about completeness.
                let textResponse = response.content
                    ?? (step == 0
                        ? (isEnglish
                            ? "I'll help you edit. Could you be more specific?"
                            : "我来帮你剪，能再说具体点吗？")
                        : (isEnglish ? "Done." : "完成。"))
                lockLiveNarrationHonestly(
                    id: liveBubbleID,
                    emittedProposal: emittedProposalThisTurn,
                    emittedCommit: emittedCommitThisTurn,
                    terminalText: textResponse,
                    isEnglish: isEnglish
                )
                let aiMsg = EditorChatMessage(role: .assistant, content: textResponse)
                chatMessages.append(aiMsg)
                try? await chatStore?.append(aiMsg)
                return
            }

            // Echo the assistant's tool-call request into the running
            // conversation so the next LLM turn can reference its own call.
            messages.append(ChatMessage(
                role: "assistant",
                content: response.content,
                toolCalls: response.toolCalls,
                toolCallId: nil
            ))

            for toolCall in response.toolCalls {
                // Phase-START for THIS tool: rewrite the bubble with a
                // line specific to what's about to run, and fire a
                // heartbeat for the slow tools so a 20s image-gen /
                // overlay render doesn't look frozen.
                let toolNarration = Self.narrationLine(
                    modelText: response.content,
                    nextToolName: toolCall.function.name,
                    english: isEnglish
                )
                let toolPhrases = Self.toolHeartbeatPhrases(
                    for: toolCall.function.name,
                    leadLine: toolNarration,
                    english: isEnglish
                )
                heartbeatStart(bubbleID: liveBubbleID, phrases: toolPhrases)

                let result = await executeAgentToolCall(
                    toolCall,
                    userMessageID: userMessageID
                )
                heartbeatCancel()
                // Track per-turn outcome shape so the terminal lock
                // can label itself honestly. A proposal is a deferred
                // edit (manual mode); a checkpoint implies work was
                // actually committed (auto-apply, restore, etc.).
                if result.proposedBatchID != nil {
                    emittedProposalThisTurn = true
                } else if result.checkpointID != nil {
                    emittedCommitThisTurn = true
                }
                // Feed the JSON result back to the LLM.
                messages.append(.tool(
                    callId: toolCall.id,
                    content: result.resultJSON
                ))
                // And surface a human-readable trace in the chat UI.
                // Keep the live-narration bubble at the tail — insert
                // trace bubbles just *before* it so the spinner stays
                // visually last while work is ongoing.
                if let userSummary = result.userSummary {
                    let (cleanContent, icon, tone) = Self.extractLeadingIcon(from: userSummary)
                    let bubble = EditorChatMessage(
                        role: .assistant,
                        content: cleanContent,
                        checkpointID: result.checkpointID,
                        proposedBatchID: result.proposedBatchID,
                        iconSystemName: icon,
                        iconTone: tone,
                        imageAttachmentPath: result.imageAttachmentPath
                    )
                    if let liveIdx = chatMessages.firstIndex(where: { $0.id == liveBubbleID }) {
                        chatMessages.insert(bubble, at: liveIdx)
                    } else {
                        chatMessages.append(bubble)
                    }
                    try? await chatStore?.append(bubble)
                    // Tools that posted their own progress bubbles
                    // (e.g. transcribeForDiarization → "Transcribing
                    // for speaker detection…") never get a chance to
                    // finalize them — the agent loop bypasses
                    // `appendAnalysisAssistantLine` for the
                    // userSummary trace. Demote any straggling
                    // `.working` bubbles here so the user doesn't
                    // see a phantom spinner sitting next to the
                    // tool's success line.
                    resolveStaleWorkingLines(persist: true)
                }
            }
        }

        // Max-steps cap: lock the live bubble honestly. If the turn
        // produced only a proposal or hedging text, don't pretend the
        // work is Done — the cap message that follows is already a
        // warning so consistency matters.
        lockLiveNarrationHonestly(
            id: liveBubbleID,
            emittedProposal: emittedProposalThisTurn,
            emittedCommit: emittedCommitThisTurn,
            terminalText: "",
            isEnglish: isEnglish
        )
        let cap = EditorChatMessage(
            role: .assistant,
            content: isEnglish
                ? "Stopped after \(maxSteps) Agent steps to prevent runaway loops. Send another message if you want me to keep going."
                : "跑了 \(maxSteps) 步先停一下，避免死循环。想继续的话再发一条就行。",
            iconSystemName: "exclamationmark.triangle.fill",
            iconTone: .warning
        )
        chatMessages.append(cap)
        try? await chatStore?.append(cap)
    }

    // MARK: - Live narration helpers

    /// Update the content of the in-place "live" narration bubble for
    /// the current agent turn. Silently no-ops if the bubble has been
    /// removed (defensive — outer caller can't have dropped it but
    /// history compaction could in theory).
    private func updateLiveNarration(id: UUID, text: String) {
        guard let idx = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[idx].content = text
        chatMessages[idx].iconTone = .working
    }

    /// Remove the live-narration bubble entirely. Used by the error
    /// path when the agent loop throws mid-turn — we don't want a
    /// perpetual spinner hanging next to the error bubble the outer
    /// catch block appends.
    private func removeLiveNarration(id: UUID) {
        heartbeatCancel()
        chatMessages.removeAll { $0.id == id }
    }

    /// Freeze the live bubble into a `.failure` warning state. Used
    /// when analysis bailed out, so the user sees a red dot instead
    /// of an infinite spinner.
    private func lockLiveNarrationAsFailure(id: UUID, text: String) {
        heartbeatCancel()
        guard let idx = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[idx].content = text
        chatMessages[idx].iconTone = .failure
        chatMessages[idx].iconSystemName = "exclamationmark.triangle.fill"
        let snapshot = chatMessages
        let store = chatStore
        Task { try? await store?.replace(with: snapshot) }
    }

    /// Start a heartbeat that rewrites the live bubble every ~2s
    /// while a long phase (transcription, scene analysis, slow tool
    /// call) is running. `phrases` is cycled through so the bubble
    /// never looks frozen. Cancels any previous heartbeat. Safe to
    /// call even if the bubble has been removed — the task exits on
    /// next tick.
    private func heartbeatStart(bubbleID: UUID, phrases: [String]) {
        heartbeatCancel()
        guard !phrases.isEmpty else { return }
        let first = phrases[0]
        updateLiveNarration(id: bubbleID, text: first)
        liveNarrationHeartbeat = Task { @MainActor [weak self] in
            var i = 1
            while !Task.isCancelled {
                // Beat interval — short enough that even a 2-3s phase
                // shows at least one rewrite, long enough that the
                // user reads each line before it flips.
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                // Bubble removed or locked? stop beating.
                guard let idx = self.chatMessages.firstIndex(where: { $0.id == bubbleID }),
                      self.chatMessages[idx].iconTone == .working
                else { return }
                let phrase = phrases[i % phrases.count]
                self.updateLiveNarration(id: bubbleID, text: phrase)
                i += 1
            }
        }
    }

    /// Cancel the running heartbeat, if any. Idempotent.
    ///
    /// Note: this does NOT await the old task. In the common case the
    /// cancelled task is sleeping and exits on its next tick. A
    /// freshly-started heartbeat may briefly race against the dying
    /// one, but both write to the same bubble with strictly newer
    /// content, so the worst case is one extra phrase flicker — not a
    /// correctness issue.
    private func heartbeatCancel() {
        liveNarrationHeartbeat?.cancel()
        liveNarrationHeartbeat = nil
    }

    /// Map an `AnalysisPhase` start event to a short live-bubble line
    /// in the user's editor language. Called from
    /// `liveNarrationCallback` every time the pipeline enters a new
    /// phase. For slow phases (transcribing / scene analysis) this
    /// also kicks off a heartbeat so the text changes every ~2s —
    /// the local ASR engine and AVFoundation don't expose fine-grained progress,
    /// so the rotation is what keeps the bubble feeling alive.
    static func analysisPhaseNarration(phase: AnalysisPhase, english: Bool) -> String {
        if english {
            switch phase {
            case .queued:           return "Queued…"
            case .transcribing:     return "Transcribing audio…"
            case .analyzingScenes:  return "Analyzing scenes…"
            case .analyzingAudio:   return "Checking audio…"
            case .requestingAI:     return "Asking AI to plan cuts…"
            case .complete:         return "Analysis done"
            case .failed:           return "Analysis failed"
            }
        }
        switch phase {
        case .queued:           return "排队中"
        case .transcribing:     return "正在转写语音"
        case .analyzingScenes:  return "正在识别画面"
        case .analyzingAudio:   return "正在检查音频"
        case .requestingAI:     return "AI 正在挑片段"
        case .complete:         return "分析完成"
        case .failed:           return "分析失败"
        }
    }

    /// Rotating heartbeat phrases for a long phase — cycled by the
    /// heartbeat task every ~2s so the user always sees movement.
    /// Kept short, casual, and in-scope so they read like natural
    /// progress updates rather than filler.
    static func heartbeatPhrases(
        forPhase phase: AnalysisPhase,
        english: Bool
    ) -> [String] {
        if english {
            switch phase {
            case .transcribing:
                return [
                    "Transcribing audio…",
                    "Still transcribing…",
                    "Reading the speech…",
                    "Almost there on transcription…"
                ]
            case .analyzingScenes:
                return [
                    "Analyzing scenes…",
                    "Scanning the footage…",
                    "Looking at the visuals…"
                ]
            case .analyzingAudio:
                return [
                    "Checking audio…",
                    "Reading loudness…",
                    "Finding silences…"
                ]
            case .requestingAI:
                return [
                    "Asking AI to plan cuts…",
                    "AI is thinking…",
                    "Picking the best takes…"
                ]
            default:
                return [analysisPhaseNarration(phase: phase, english: true)]
            }
        }
        switch phase {
        case .transcribing:
            return [
                "正在转写语音",
                "还在转写",
                "听清每一句话",
                "马上就转完了"
            ]
        case .analyzingScenes:
            return [
                "正在识别画面",
                "看一下镜头",
                "扫描画面内容"
            ]
        case .analyzingAudio:
            return [
                "正在检查音频",
                "读响度",
                "找静音段"
            ]
        case .requestingAI:
            return [
                "AI 正在挑片段",
                "AI 思考中",
                "挑出最好的那几段"
            ]
        default:
            return [analysisPhaseNarration(phase: phase, english: false)]
        }
    }

    /// Freeze the live bubble to a `.success` "完成" state and persist
    /// it. Called exactly once per turn — on the terminal LLM response
    /// or when the max-step cap trips.
    private func lockLiveNarration(id: UUID, finalText: String) {
        heartbeatCancel()
        guard let idx = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[idx].content = finalText
        chatMessages[idx].iconTone = .success
        chatMessages[idx].iconSystemName = "checkmark.circle.fill"
        // Now that the bubble is stable we persist a snapshot so the
        // locked "完成" line shows up on relaunch alongside the real
        // reply that follows.
        let snapshot = chatMessages
        let store = chatStore
        Task { try? await store?.replace(with: snapshot) }
    }

    /// Like `lockLiveNarration` but chooses between success / pending /
    /// partial depending on what actually happened this turn.
    /// - If the agent only emitted a proposal (no direct commits), the
    ///   work isn't "Done" — it's waiting for the user to Apply.
    /// - If the agent's own terminal text hedges about completeness
    ///   ("仅调整了样式", "only adjusted the style", etc.) demote to a
    ///   warning-toned "部分完成". This covers the classic half-job
    ///   bilingual case — the model flipped `subtitle_style.bilingual`
    ///   but forgot to run `translate_subtitles` first, so the preview
    ///   still shows a single line. The fallback is also the guard
    ///   against future "style without content" mismatches.
    private func lockLiveNarrationHonestly(
        id: UUID,
        emittedProposal: Bool,
        emittedCommit: Bool,
        terminalText: String,
        isEnglish: Bool
    ) {
        heartbeatCancel()
        guard let idx = chatMessages.firstIndex(where: { $0.id == id }) else { return }

        let partialFromText = Self.looksLikePartialCompletion(terminalText, english: isEnglish)
        let proposalOnly = emittedProposal && !emittedCommit
        let didNothing = !emittedProposal && !emittedCommit

        if didNothing {
            // Pure-text reply (greeting, clarifying question, "I can't do
            // that"). Showing a green "Done" / "完成" status above it would
            // be a lie — nothing was actually completed. Drop the live
            // bubble entirely; the assistant's text reply that gets
            // appended right after carries the whole message.
            chatMessages.remove(at: idx)
            let snapshot = chatMessages
            let store = chatStore
            Task { try? await store?.replace(with: snapshot) }
            return
        }

        if proposalOnly {
            chatMessages[idx].content = isEnglish ? "Awaiting your review" : "等你确认"
            chatMessages[idx].iconTone = .warning
            chatMessages[idx].iconSystemName = "hourglass"
        } else if partialFromText {
            chatMessages[idx].content = isEnglish ? "Partially applied" : "部分完成"
            chatMessages[idx].iconTone = .warning
            chatMessages[idx].iconSystemName = "exclamationmark.triangle.fill"
        } else {
            chatMessages[idx].content = isEnglish ? "Done" : "完成"
            chatMessages[idx].iconTone = .success
            chatMessages[idx].iconSystemName = "checkmark.circle.fill"
        }

        let snapshot = chatMessages
        let store = chatStore
        Task { try? await store?.replace(with: snapshot) }
    }

    /// Heuristic "the model is telling us it didn't fully satisfy the
    /// ask" detector. We intentionally only match fairly unambiguous
    /// phrasings — false positives turn every Done into a warning.
    static func looksLikePartialCompletion(_ text: String, english: Bool) -> Bool {
        let lower = text.lowercased()
        // Chinese hedge phrases the model emits when it knows it only
        // did part of the ask — lifted from real agent transcripts.
        let zhNeedles = [
            "还在待", "待你确认", "等你确认", "等待确认",
            "只是把", "只把", "仅仅", "仅调", "仅做了", "只做了",
            "没有实现", "没能实现", "无法实现",
            "没有这个工具", "没有相应工具", "没有对应工具",
            "不支持", "暂不支持",
            "部分完成", "只完成了一部分",
            "如果你愿意，我可以",
            "需要你确认"
        ]
        let enNeedles = [
            "still pending", "awaiting your", "waiting for you",
            "only adjusted", "only changed", "only did",
            "not yet supported", "not supported",
            "don't have a tool", "don't have that tool", "no tool for",
            "partially applied", "part of what you asked"
        ]
        for n in zhNeedles where text.contains(n) { return true }
        for n in enNeedles where lower.contains(n) { return true }
        return false
    }

    /// Read whether the AI prompt / chat copy should default to English.
    /// Driven by the user's interface-language preference
    /// (`uiLanguageKey`); when that is `system`, falls through to
    /// `Locale.current`. Source-audio language is detected separately
    /// by the speech engine and has no influence here.
    static func currentAppLanguageIsEnglish() -> Bool {
        let raw = UserDefaults.standard.string(forKey: CuttiSettings.uiLanguageKey)
            ?? CuttiSettings.uiLanguageSystem
        switch raw {
        case CuttiSettings.uiLanguageEnglish:
            return true
        case CuttiSettings.uiLanguageChinese:
            return false
        default:
            // System: trust the OS-resolved primary language.
            let code = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"
            return code == "en"
        }
    }

    /// Pick a short, casual one-liner for the live bubble. Prefers
    /// the model's own `response.content` (trimmed, single line) and
    /// falls back to a per-tool hardcoded phrase so the bubble never
    /// goes blank.
    static func narrationLine(
        modelText: String?,
        nextToolName: String?,
        english: Bool
    ) -> String {
        if let raw = modelText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            // Collapse to first non-empty line and trim to a sane length.
            let firstLine = raw
                .split(whereSeparator: { $0.isNewline })
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? raw
            if !firstLine.isEmpty {
                let cap = english ? 60 : 24
                if firstLine.count > cap {
                    return String(firstLine.prefix(cap)) + "…"
                }
                return firstLine
            }
        }
        return fallbackNarration(for: nextToolName, english: english)
    }

    /// Hardcoded per-tool fallback phrases. Kept ≤12 Chinese chars /
    /// ≤6 English words so they read like a live status ticker.
    static func fallbackNarration(for tool: String?, english: Bool) -> String {
        guard let tool else {
            return english ? "Working on it…" : "处理中"
        }
        if english {
            switch tool {
            case "edit_timeline":        return "Editing the timeline…"
            case "restore_checkpoint":   return "Restoring checkpoint…"
            case "insert_broll":         return "Placing B-roll…"
            case "generate_overlay":     return "Rendering overlay…"
            case "update_overlay_props": return "Tweaking overlay…"
            case "generate_image":       return "Generating image…"
            case "insert_crossfade":     return "Adding crossfade…"
            case "find_filler_words":    return "Scanning for fillers…"
            case "find_by_transcript":   return "Searching transcript…"
            case "get_timeline_summary": return "Reading the timeline…"
            case "get_segment_detail":   return "Inspecting segment…"
            case "score_hook_candidates": return "Scoring hook candidates…"
            case "add_hook_teaser":       return "Preparing opening hook…"
            case "find_black_frames":    return "Looking for black frames…"
            case "find_empty_frames":    return "Looking for empty shots…"
            case "find_scene_changes":   return "Finding scene cuts…"
            case "auto_pip":             return "Planning PiP…"
            case "suggest_broll":        return "Suggesting B-roll…"
            case "set_segment_volume":   return "Adjusting volume…"
            case "audio_ducking":        return "Ducking audio…"
            case "normalize_loudness":   return "Leveling loudness…"
            case "get_frame_at":         return "Grabbing a frame…"
            case "detect_speakers":      return "Detecting speakers…"
            case "find_by_speaker":      return "Finding speaker cues…"
            case "mute_speaker":         return "Muting speaker…"
            case "suggest_title":        return "Drafting titles…"
            case "suggest_chapters":     return "Drafting chapters…"
            case "translate_subtitles":  return "Translating subtitles…"
            case "emphasize_words":      return "Emphasizing words…"
            case "run_first_cut":        return "Running the AI first cut…"
            case "list_animation_rules": return "Listing the animation skill…"
            case "read_animation_rule":  return "Reading the animation skill…"
            default:                     return "Working on it…"
            }
        }
        switch tool {
        case "edit_timeline":        return "正在剪切"
        case "restore_checkpoint":   return "回到之前那版"
        case "insert_broll":         return "放一段 B-roll"
        case "generate_overlay":     return "做动效标题中"
        case "update_overlay_props": return "调整 overlay"
        case "generate_image":       return "生成图片中"
        case "insert_crossfade":     return "加转场中"
        case "find_filler_words":    return "扫填充词"
        case "find_by_transcript":   return "在字幕里找"
        case "get_timeline_summary": return "看下时间线"
        case "get_segment_detail":   return "查下片段"
        case "score_hook_candidates": return "给开场金句打分"
        case "add_hook_teaser":       return "把开场金句放到开头"
        case "find_black_frames":    return "找黑场"
        case "find_empty_frames":    return "找空镜"
        case "find_scene_changes":   return "找镜头切点"
        case "auto_pip":             return "规划画中画"
        case "suggest_broll":        return "推荐空镜"
        case "set_segment_volume":   return "调音量"
        case "audio_ducking":        return "给 BGM 让路"
        case "normalize_loudness":   return "平整响度"
        case "get_frame_at":         return "抽张画面看看"
        case "detect_speakers":      return "识别说话人"
        case "find_by_speaker":      return "找这个人的话"
        case "mute_speaker":         return "给他静音"
        case "suggest_title":        return "想几个标题"
        case "suggest_chapters":     return "拆下章节"
        case "translate_subtitles":  return "翻译字幕中"
        case "emphasize_words":      return "给字幕标重点"
        case "run_first_cut":        return "做第一刀剪辑中"
        case "list_animation_rules": return "翻一下动画手册目录"
        case "read_animation_rule":  return "翻一下动画手册"
        default:                     return "处理中"
        }
    }

    /// Rotating phrases cycled on the live bubble while a single tool
    /// call is executing. `leadLine` is whatever we already put in the
    /// bubble at tool-start (model narration or the per-tool fallback);
    /// subsequent rotations keep the tone alive so the user sees
    /// movement during 5–30s generations (image, overlay, chapter).
    static func toolHeartbeatPhrases(
        for tool: String,
        leadLine: String,
        english: Bool
    ) -> [String] {
        let followups: [String]
        if english {
            switch tool {
            case "generate_image":
                followups = ["Still rendering…", "Almost there…", "Fine-tuning details…"]
            case "generate_overlay":
                followups = ["Rendering overlay…", "Exporting ProRes…", "Almost done…"]
            case "update_overlay_props":
                followups = ["Applying changes…"]
            case "suggest_chapters", "suggest_title", "suggest_broll":
                followups = ["AI is drafting…", "Almost ready…"]
            case "detect_speakers":
                followups = ["Listening to speakers…", "Tagging voices…"]
            case "auto_pip":
                followups = ["Planning PiP placement…"]
            case "normalize_loudness", "audio_ducking":
                followups = ["Adjusting audio…"]
            case "edit_timeline":
                followups = ["Editing the timeline…", "Applying cuts…"]
            case "run_first_cut":
                followups = ["Transcribing speech…", "Analyzing scenes…", "Picking the best takes…", "Stitching the first cut…"]
            default:
                followups = ["Working on it…"]
            }
        } else {
            switch tool {
            case "generate_image":
                followups = ["还在生成图片", "马上好", "细节在打磨"]
            case "generate_overlay":
                followups = ["正在渲染动效", "导出 ProRes 中", "快好了"]
            case "update_overlay_props":
                followups = ["改 overlay 中"]
            case "suggest_chapters", "suggest_title", "suggest_broll":
                followups = ["AI 起草中", "快给你"]
            case "detect_speakers":
                followups = ["在听谁在说", "标注声纹"]
            case "auto_pip":
                followups = ["规划画中画"]
            case "normalize_loudness", "audio_ducking":
                followups = ["调整音频"]
            case "edit_timeline":
                followups = ["正在剪切", "落刀中"]
            case "run_first_cut":
                followups = ["听一下逐字稿", "看下镜头", "挑最好的镜头", "拼第一刀"]
            default:
                followups = ["处理中"]
            }
        }
        return [leadLine] + followups
    }

    /// The system-prompt paragraph appended to every chat agent turn so
    /// the model narrates each step in short casual one-liners instead
    /// of going silent between tool calls. The narration we pick is the
    /// model's own intermediate `content`, not a separate field.
    static func liveNarrationSystemDirective() -> String {
        """
        ## 实时叙述（重要）
        你每一轮调用工具前，都在 assistant 消息的 `content` 字段写**一句**非常短的进度旁白，告诉用户你当前在做什么。规则：
        - 用用户正在使用的编辑器语言（中文 或 English），与逐字稿无关，由系统决定；若不确定，默认中文。
        - 中文 ≤ 12 个字；英文 ≤ 6 个词。
        - 口语、轻松，不要正式；不要带标点花哨符号；不要 emoji；不要 Markdown。
        - 内容要具体（"正在剪切"、"字幕生成中"、"在找填充词"），不要空话（"好的"、"稍等"）。
        - **不要**在 content 里讲结果、讲理由、列步骤——那些放到最后不带 tool_call 的总结那一轮再写。
        - 最后一轮（你不再调用工具时）正常写你的完整回复，不受这条规则限制。
        """
    }

    private struct AgentToolOutcome {
        let resultJSON: String
        let userSummary: String?
        let checkpointID: UUID?
        /// When non-nil this outcome is a manual-mode proposal and the
        /// user-facing bubble should render as an Apply/Reject card
        /// bound to this proposal id.
        let proposedBatchID: UUID?
        /// Optional inline image attachment (path relative to project
        /// root). Used by `generate_image` so the generated PNG shows
        /// up in the chat bubble, not just as a text confirmation.
        let imageAttachmentPath: String?

        init(
            resultJSON: String,
            userSummary: String?,
            checkpointID: UUID?,
            proposedBatchID: UUID? = nil,
            imageAttachmentPath: String? = nil
        ) {
            self.resultJSON = resultJSON
            self.userSummary = userSummary
            self.checkpointID = checkpointID
            self.proposedBatchID = proposedBatchID
            self.imageAttachmentPath = imageAttachmentPath
        }
    }

    private struct EditTimelineToolResult: Codable {
        let applied: Int
        let skipped: Int
        let explanation: String
        /// Human-readable issues the executor surfaced while applying
        /// the batch (e.g. "bilingual enabled without a secondary
        /// locale"). Encoded so the LLM can read them and either
        /// correct on the next turn or tell the user why a silent-skip
        /// happened. Defaults to empty for backwards compatibility.
        var warnings: [String] = []
    }

    private struct InsertBRollToolResult: Codable {
        let ok: Bool
        let overlayTracks: Int
        let at: Double
        let duration: Double
    }

    /// JSON shape returned by the `add_hook_teaser` tool. Encoded via
    /// `AgentToolJSON.encode` and surfaced to the model as a `tool`
    /// message. The fields are deliberately verbose so the model
    /// understands the proposal is *pending* and that it must wait for
    /// the user to click Apply before chaining more destructive edits.
    private struct AddHookTeaserToolResult: Codable {
        let status: String
        let durationSeconds: Double
        let requiresUserConfirmation: Bool
        let nextSteps: String

        enum CodingKeys: String, CodingKey {
            case status
            case durationSeconds = "duration_seconds"
            case requiresUserConfirmation = "requires_user_confirmation"
            case nextSteps = "next_steps"
        }
    }

    /// Resolve (and cache-if-missing) a VisualIndex per unique
    /// sourceVideoID referenced by the current timeline. First call on a
    /// fresh project runs `VisualAnalysisService.analyze` per source —
    /// can take multiple seconds per clip. Subsequent calls read the
    /// cached `media/visual_index/<id>.json`. Missing / unreadable
    /// sources are skipped silently so the Agent still gets partial
    /// coverage instead of erroring out.
    private func loadOrBuildVisualIndices() async -> [UUID: VisualIndex] {
        guard let projectRoot else { return [:] }
        let sourceIDs = Set(timelineSegments.map { $0.sourceVideoID })
        var out: [UUID: VisualIndex] = [:]
        for sourceID in sourceIDs {
            if let cached = VisualIndexStore.load(projectRoot: projectRoot, videoID: sourceID) {
                out[sourceID] = cached
                continue
            }
            guard let record = records.first(where: { $0.id == sourceID }) else { continue }
            let url = URL(fileURLWithPath: record.sourcePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            do {
                let index = try await VisualAnalysisService.analyze(asset: asset)
                try? VisualIndexStore.save(index, projectRoot: projectRoot, videoID: sourceID)
                out[sourceID] = index
            } catch {
                print("🔴 VisualAnalysis failed for \(sourceID): \(error)")
            }
        }
        return out
    }

    /// Build the tool catalog the agent loop sends to the LLM. Filters
    /// out animation/overlay tools when the user is on BYOK so the LLM
    /// (a) doesn't see, (b) can't legitimately invoke, the cloud-only
    /// animation pipeline. The runtime gate in `executeAgentToolCall`
    /// also rejects fabricated tool calls for these names — see
    /// `byokBlockedToolNames` and the rubber-duck note about malicious
    /// BYOK providers returning hidden tool calls.
    static func agentToolDefinitions(for provider: AIProviderPreference) -> [ToolDefinition] {
        var tools: [ToolDefinition] = [
            AIAction.editTimelineToolDefinition,
            RestoreCheckpointRequest.toolDefinition,
            InsertBRollRequest.toolDefinition,
            GenerateOverlayRequest.toolDefinition,
            AnimationSkill.listToolDefinition,
            AnimationSkill.readToolDefinition,
            UpdateOverlayPropsRequest.toolDefinition,
            GenerateImageRequest.toolDefinition,
            CreativeAction.insertCrossfadeToolDefinition,
            AgentQuery.findFillerWordsTool,
            AgentQuery.findByTranscriptTool,
            AgentQuery.getTimelineSummaryTool,
            AgentQuery.getSegmentDetailTool,
            AgentHook.scoreHookCandidatesTool,
            AgentHook.addHookTeaserTool,
            VisualAgentQuery.findBlackFramesTool,
            VisualAgentQuery.findEmptyFramesTool,
            VisualAgentQuery.findSceneChangesTool,
            VisualAgentQuery.autoPiPTool,
            SetSegmentVolumeRequest.toolDefinition,
            AudioDuckingRequest.toolDefinition,
            NormalizeLoudnessRequest.toolDefinition,
            GetFrameAtRequest.toolDefinition,
            DetectSpeakersRequest.toolDefinition,
            FindBySpeakerRequest.toolDefinition,
            MuteSpeakerRequest.toolDefinition,
            TranslateSubtitlesRequest.toolDefinition,
            EmphasizeWordsRequest.toolDefinition,
            SuggestTitleRequest.toolDefinition,
            SuggestChaptersRequest.toolDefinition,
            SuggestBRollRequest.toolDefinition,
            RunFirstCutRequest.toolDefinition
        ]
        if provider == .custom {
            tools.removeAll { Self.byokBlockedToolNames.contains($0.function.name) }
        }
        return tools
    }

    /// Tool names that BYOK users cannot invoke. Source of truth for
    /// both the tools-catalog filter and the runtime authorization
    /// check in `executeAgentToolCall`.
    static let byokBlockedToolNames: Set<String> = [
        "generate_overlay",
        "update_overlay_props",
        "list_animation_rules",
        "read_animation_rule"
    ]

    /// Execute a single LLM-issued tool call. Mutating tools (edit_timeline,
    /// restore_checkpoint) apply immediately; query tools return data for the
    /// LLM to read on the next step.
    private func executeAgentToolCall(
        _ toolCall: ToolCall,
        userMessageID: UUID
    ) async -> AgentToolOutcome {
        let argsData = toolCall.function.arguments.data(using: .utf8) ?? Data()
        let args = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any] ?? [:]

        // High-signal trace so users can verify in the Xcode/Console
        // log which tools the agent actually picked. Keep args raw but
        // truncated — full payloads (props_json etc.) can be 10s of KB
        // and would drown the console.
        let argsPreview: String = {
            let raw = toolCall.function.arguments
            return raw.count <= 240 ? raw : String(raw.prefix(240)) + "…"
        }()
        print("🤖 [agent.tool] name=\(toolCall.function.name) args=\(argsPreview)")

        // Runtime authorization for BYOK. Even though the tools catalog
        // we send up-front already excludes animation tools when the
        // user is on `.custom`, a malicious or sloppy BYOK provider can
        // still return fabricated `tool_calls` for them. Reject early
        // before we touch any animation skill content (which would leak
        // proprietary markdown to the BYOK endpoint via the next-turn
        // tool result) or hit `makeOverlayCache` (already gated, but
        // belt-and-suspenders).
        if CuttiSettings.aiProvider() == .custom,
           Self.byokBlockedToolNames.contains(toolCall.function.name) {
            let banner = L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud.")
            bannerMessage = banner
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encodeError("animation_unavailable_in_byok"),
                userSummary: banner,
                checkpointID: nil
            )
        }

        switch toolCall.function.name {
        case "edit_timeline":
            guard let rawBatch = AIAction.parseBatch(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid edit_timeline arguments"),
                    userSummary: "⚠️ Invalid edit_timeline arguments",
                    checkpointID: nil
                )
            }

            // Pre-flight validation — catch unknown segment IDs,
            // out-of-range speed / volume, inverted ranges, … BEFORE
            // we touch the executor. Structured issues are fed back
            // to the LLM so it can correct on the next turn.
            // `knownSourceVideoIDs` lets the validator reject
            // `insert_source_clip` calls that reference a UUID outside
            // the project library — without this the LLM could
            // hallucinate an ID and the segment would later render as
            // black-frame missing-media.
            let validation = AIActionValidator.validate(
                batch: rawBatch,
                segments: timelineSegments,
                knownSourceVideoIDs: Set(records.map(\.id))
            )
            if validation.hasErrors {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let payload: [String: Any] = [
                    "error": "preflight_failed",
                    "message": "\(validation.errors.count) action(s) failed validation. Fix and retry.",
                    "issues": validation.errors.map { [
                        "action_index": $0.actionIndex,
                        "code": $0.code,
                        "message": $0.message
                    ] },
                    "warnings": validation.warnings.map { [
                        "action_index": $0.actionIndex,
                        "code": $0.code,
                        "message": $0.message
                    ] }
                ]
                let json = (try? JSONSerialization.data(withJSONObject: payload))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"preflight_failed\"}"
                let bullets = validation.errors.prefix(5).map { "• \($0.message)" }.joined(separator: "\n")
                return AgentToolOutcome(
                    resultJSON: json,
                    userSummary: "⚠️ Pre-flight rejected \(validation.errors.count) action(s):\n\(bullets)",
                    checkpointID: nil
                )
            }

            // If the user has attached segments, filter the batch down
            // to actions that fall entirely inside the attached scope.
            // Anything the LLM tried to run outside the scope is
            // rejected with a user-visible note.
            let filtered = ScopeGuard.filter(
                batch: rawBatch,
                scope: chatAttachmentScope,
                segments: timelineSegments
            )
            if filtered.didFilter {
                let desc = ScopeGuard.describeRejections(filtered.rejected)
                let msg = EditorChatMessage(
                    role: .system,
                    content: "⚠️ Attached scope: rejected \(filtered.rejected.count) out-of-scope action(s) (\(desc))"
                )
                chatMessages.append(msg)
                Task { try? await chatStore?.append(msg) }
            }
            let batch = filtered.kept
            if batch.actions.isEmpty {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError(
                        "All actions were rejected because they fall outside the attached scope. Translate user times from virtual to composed using the mapping table and stay within the attached range."
                    ),
                    userSummary: "⚠️ All proposed edits were outside the attached scope",
                    checkpointID: nil
                )
            }

            // Always dry-run first: the executor is pure so this is
            // cheap and lets us build a diff either way.
            let result = AIActionExecutor.apply(
                batch: batch,
                to: timelineSegments,
                baseSubtitleStyle: subtitleStyle,
                transcriptLookup: { ranges, sourceID in
                    self.subtitleEntries(for: ranges, sourceVideoID: sourceID)
                }
            )

            switch agentMode {
            case .autoApply:
                return commitAgentBatch(
                    batch: batch,
                    dryRun: result,
                    userMessageID: userMessageID
                )

            case .manual:
                let proposal = ProposedBatch.make(
                    toolCallID: toolCall.id,
                    batch: batch,
                    before: timelineSegments,
                    dryRun: result
                )
                pendingProposals.insert(proposal, at: 0)

                // Build a short preview bubble — the card UI reads
                // the proposal via `proposedBatchID`, but a plain
                // content string is still useful for voice-over /
                // accessibility and for the persisted chat log.
                let preview = batch.userFacingSummary
                let warningLines = result.warnings.map { "⚠️ \($0)" }.joined(separator: "\n")
                let bubble = """
                📝 \(batch.explanation.isEmpty ? "Pending edit" : batch.explanation)
                \(preview.isEmpty ? "" : "\(preview)\n")\(proposal.previewAppliedCount) action(s) proposed\(proposal.previewSkippedCount > 0 ? ", \(proposal.previewSkippedCount) would skip" : "")\(warningLines.isEmpty ? "" : "\n\(warningLines)")
                """

                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encode(EditTimelineToolResult(
                        applied: 0,
                        skipped: result.skippedCount,
                        explanation: "Proposed — waiting for user to Apply/Reject. Do not propose more destructive edits until resolved.",
                        warnings: result.warnings
                    )),
                    userSummary: bubble,
                    checkpointID: nil,
                    proposedBatchID: proposal.id
                )
            }

        case "find_black_frames":
            let indices = await loadOrBuildVisualIndices()
            let matches = VisualAgentQuery.findBlackFrames(segments: timelineSegments, indices: indices)
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(["matches": matches]),
                userSummary: matches.isEmpty ? nil : "🔍 Found \(matches.count) black-frame cue(s).",
                checkpointID: nil
            )

        case "find_empty_frames":
            let indices = await loadOrBuildVisualIndices()
            let matches = VisualAgentQuery.findEmptyFrames(segments: timelineSegments, indices: indices)
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(["matches": matches]),
                userSummary: matches.isEmpty ? nil : "🔍 Found \(matches.count) empty-frame cue(s).",
                checkpointID: nil
            )

        case "find_scene_changes":
            let indices = await loadOrBuildVisualIndices()
            let matches = VisualAgentQuery.findSceneChanges(segments: timelineSegments, indices: indices)
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(["matches": matches]),
                userSummary: matches.isEmpty ? nil : "🔍 Found \(matches.count) scene-change point(s).",
                checkpointID: nil
            )

        case "insert_crossfade":
            guard let action = CreativeAction.parseInsertCrossfade(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid insert_crossfade arguments. Need from_segment_id, to_segment_id (UUIDs), duration."),
                    userSummary: "⚠️ Invalid insert_crossfade arguments",
                    checkpointID: nil
                )
            }
            guard let plan = CreativeActionMapper.plan(crossfade: action, in: timelineSegments) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Segments must be adjacent in the current timeline. Re-check IDs via get_timeline_summary if unsure."),
                    userSummary: "⚠️ Crossfade requires two adjacent segments.",
                    checkpointID: nil
                )
            }
            let newSegments = CreativeActionMapper.apply(crossfade: plan, to: timelineSegments)
            let label = "Crossfade segments (\(String(format: "%.2fs", plan.duration)))"
            pushRevision(label: label, trigger: .aiAction(messageID: userMessageID))
            project.primarySegments = newSegments
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(InsertBRollToolResult(
                    ok: true,
                    overlayTracks: project.overlayTracks.count,
                    at: Double(plan.fromSegmentIndex),
                    duration: plan.duration
                )),
                userSummary: "🎬 Crossfaded segments \(plan.fromSegmentIndex) → \(plan.toSegmentIndex) over \(String(format: "%.2fs", plan.duration)).",
                checkpointID: revisions.last?.id
            )

        case "insert_broll":
            guard let request = InsertBRollRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid insert_broll arguments. Need composed_time, media_id (UUID of imported asset), duration."),
                    userSummary: "⚠️ Invalid insert_broll arguments",
                    checkpointID: nil
                )
            }
            guard records.contains(where: { $0.id == request.mediaID }) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("media_id \(request.mediaID.uuidString) is not an imported asset. Call this only with IDs the user has already imported."),
                    userSummary: "⚠️ B-roll source not found — import the clip first.",
                    checkpointID: nil
                )
            }

            let nextProject: Project
            do {
                nextProject = try CreativeActionExecutor.apply(
                    request.asCreativeAction,
                    to: project,
                    mediaDuration: { _ in nil }
                )
            } catch {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("insert_broll failed: \(error.localizedDescription)"),
                    userSummary: "⚠️ Couldn't insert B-roll: \(error.localizedDescription)",
                    checkpointID: nil
                )
            }

            // Snapshot current state then apply. insert_broll is additive
            // (never destroys primary content) so we auto-apply regardless
            // of agentMode — undo is always one restore_checkpoint away.
            let label = "Insert B-roll at \(String(format: "%.1fs", request.composedTime)) (\(String(format: "%.1fs", request.duration)))"
            pushRevision(label: label, trigger: .aiAction(messageID: userMessageID))
            project = nextProject
            let checkpointID = revisions.last?.id

            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(InsertBRollToolResult(
                    ok: true,
                    overlayTracks: project.overlayTracks.count,
                    at: request.composedTime,
                    duration: request.duration
                )),
                userSummary: "🎞️ Added B-roll overlay at \(String(format: "%.1fs", request.composedTime)) for \(String(format: "%.1fs", request.duration)).",
                checkpointID: checkpointID
            )

        case "generate_overlay":
            guard let request = GenerateOverlayRequest.parse(from: args) else {
                print("🎬 [overlay] dispatch: PARSE FAILED — generate_overlay args malformed")
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid generate_overlay arguments. Need template_id (string), props_json (JSON string matching the template schema), composed_time (number). Optional: duration_seconds."),
                    userSummary: "⚠️ Invalid generate_overlay arguments",
                    checkpointID: nil
                )
            }
            guard RemotionOverlayCatalog.supportedTemplateIDs.contains(request.templateID) else {
                print("🎬 [overlay] dispatch: UNKNOWN TEMPLATE \(request.templateID) — supported: \(RemotionOverlayCatalog.supportedTemplateIDs.joined(separator: ","))")
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Unknown template_id '\(request.templateID)'. Supported: \(RemotionOverlayCatalog.supportedTemplateIDs.joined(separator: ", "))."),
                    userSummary: "⚠️ Unknown overlay template \(request.templateID)",
                    checkpointID: nil
                )
            }
            // Attachment-scope guard: when the user dragged one or more
            // segments into the chat, the overlay's [composed_time,
            // composed_time + duration] window must be fully contained
            // in the attachment's composed ranges. Mirrors how
            // ScopeGuard filters AIAction batches.
            let overlayScope = chatAttachmentScope
            if !overlayScope.isEmpty {
                let overlayStart = request.composedTime
                let overlayEnd = request.composedTime + request.durationSeconds
                if !overlayScope.containsComposedRange(start: overlayStart, end: overlayEnd) {
                    print("🎬 [overlay] dispatch: SCOPE REJECT \(overlayStart)s..\(overlayEnd)s not in attached scope")
                    return AgentToolOutcome(
                        resultJSON: AgentToolJSON.encodeError(
                            "composed_time \(String(format: "%.2f", overlayStart))s + duration \(String(format: "%.2f", request.durationSeconds))s falls outside the attached scope. Only composed times inside the attached segments' composed ranges are allowed. Virtual timeline length is \(String(format: "%.2f", overlayScope.virtualDuration))s — translate the virtual time to composed using the mapping in the system prompt and try again."
                        ),
                        userSummary: "⚠️ Overlay request rejected: outside attached scope",
                        checkpointID: nil
                    )
                }
            }
            // Anchor-duration validation: when a suggestion-driven
            // overlay kicked off this agent turn, SequenceSteps must
            // run for roughly the speaker's anchor window (that's the
            // whole point — syncing visuals to the speaker's cadence).
            // Reject obviously-too-short sequence overlays so the agent
            // retries with a duration that matches. Other templates
            // (ChapterTitle / TitleCard / Quote etc.) are legitimately
            // tight, so they're excluded from this check.
            if let anchor = pendingOverlayAnchor, anchor.expiresAt > Date() {
                let anchorDur = anchor.anchorDurationSeconds
                if request.templateID == "SequenceSteps" && anchorDur > 4 {
                    let requiredMin = max(3.0, anchorDur * 0.6)
                    if request.durationSeconds < requiredMin {
                        let targetClamped = min(anchorDur, 30.0)
                        return AgentToolOutcome(
                            resultJSON: AgentToolJSON.encodeError(
                                "durationSeconds=\(String(format: "%.1f", request.durationSeconds)) is too short for this SequenceSteps overlay. The speaker's anchor window is \(String(format: "%.1f", anchorDur))s and the sequence animation must span it end-to-end so each item syncs with the words. Retry with durationSeconds ≈ \(String(format: "%.1f", targetClamped)) and keep the same items / atSeconds values."
                            ),
                            userSummary: "⚠️ Overlay rejected: duration shorter than speaker's anchor",
                            checkpointID: nil
                        )
                    }
                }
            }

            // Snapshot BEFORE the overlay lands so `restore_checkpoint`
            // can rewind past this creative action the same way it does
            // for `insert_broll`.
            let overlayLabel = "Generate \(request.templateID) overlay at \(String(format: "%.1fs", request.composedTime))"
            pushRevision(label: overlayLabel, trigger: .aiAction(messageID: userMessageID))
            let overlayCheckpointID = revisions.last?.id

            let overlayError = await generateOverlay(
                templateID: request.templateID,
                propsJSON: request.propsJSON,
                durationSeconds: request.durationSeconds,
                at: request.composedTime
            )

            // Render / insert failed — report the exact error back to the
            // agent so it can surface a truthful message (and optionally
            // retry). Do NOT claim success when nothing landed on v2.
            if let overlayError {
                let reason = overlayError.localizedDescription
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Animation render failed: \(reason)"),
                    userSummary: "⚠️ 动画生成失败：\(reason)",
                    checkpointID: nil
                )
            }

            // Success path — clear the anchor context so unrelated
            // follow-up generate_overlay calls aren't retroactively
            // held to this anchor's duration.
            pendingOverlayAnchor = nil

            return AgentToolOutcome(
                resultJSON: "{\"ok\":true,\"template_id\":\"\(request.templateID)\",\"composed_time\":\(request.composedTime),\"duration_seconds\":\(request.durationSeconds)}",
                userSummary: "✨ Rendered \(request.templateID) overlay at \(String(format: "%.1fs", request.composedTime)) for \(String(format: "%.1fs", request.durationSeconds)).",
                checkpointID: overlayCheckpointID
            )

        case "list_animation_rules":
            // Read-only TOC of the bundled animation skill. No side
            // effects, no checkpoint, no scope constraints. The agent
            // calls this to discover what rules / style-guide /
            // templates / plugins / workflow docs are available; it
            // then follows up with `read_animation_rule` for the
            // ones it actually needs.
            let entries = AnimationSkill.allEntries
            let serialized: [[String: String]] = entries.map { entry in
                ["name": entry.name, "summary": entry.summary]
            }
            let payload: [String: Any] = [
                "ok": true,
                "count": entries.count,
                "entries": serialized,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "{\"ok\":true,\"count\":\(entries.count)}"
            return AgentToolOutcome(
                resultJSON: json,
                userSummary: "📚 Listed animation skill (\(entries.count) entries)",
                checkpointID: nil
            )

        case "read_animation_rule":
            // Read-only fetch of one bundled markdown file. No side
            // effects, no checkpoint. Strips the YAML front matter so
            // the agent sees clean prose.
            guard let request = AnimationSkill.ReadRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("read_animation_rule needs a `name` (e.g. `rules/cutti-staging`). Call `list_animation_rules` first if you don't know the names."),
                    userSummary: nil,
                    checkpointID: nil
                )
            }
            guard let raw = AnimationSkill.content(for: request.name) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("No animation skill entry named `\(request.name)`. Call `list_animation_rules` to see valid names."),
                    userSummary: nil,
                    checkpointID: nil
                )
            }
            let cleaned = AnimationSkill.stripFrontMatter(raw)
            let payload: [String: Any] = [
                "ok": true,
                "name": request.name,
                "content": cleaned,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "{\"ok\":true,\"name\":\"\(request.name)\"}"
            return AgentToolOutcome(
                resultJSON: json,
                userSummary: "📖 Read animation skill: \(request.name)",
                checkpointID: nil
            )

        case "generate_image":
            guard let request = GenerateImageRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid generate_image arguments. Need prompt (string). Optional: size (landscape|portrait|square), composed_time (number), duration_seconds (number)."),
                    userSummary: "⚠️ Invalid generate_image arguments",
                    checkpointID: nil
                )
            }

            // Attachment scope: if the user pinned segments AND asked for
            // auto-insert, the overlay window must sit inside the scope.
            // Freeform (no composed_time) is always allowed — the image
            // only reaches the Media Browser.
            if let at = request.insertAt {
                let scope = chatAttachmentScope
                if !scope.isEmpty {
                    let end = at + request.durationSeconds
                    if !scope.containsComposedRange(start: at, end: end) {
                        return AgentToolOutcome(
                            resultJSON: AgentToolJSON.encodeError(
                                "composed_time \(String(format: "%.2f", at))s + duration \(String(format: "%.2f", request.durationSeconds))s falls outside the attached scope."
                            ),
                            userSummary: "⚠️ Image insert rejected: outside attached scope",
                            checkpointID: nil
                        )
                    }
                }
            }

            // Snapshot BEFORE the overlay lands so `restore_checkpoint`
            // can rewind; only snapshot when we're actually mutating the
            // timeline (insertAt != nil). Freeform imports already show
            // up in undo via the media-library revision.
            var imageCheckpointID: UUID? = nil
            if let at = request.insertAt {
                pushRevision(
                    label: "Generate image at \(String(format: "%.1fs", at))",
                    trigger: .aiAction(messageID: userMessageID)
                )
                imageCheckpointID = revisions.last?.id
            }

            let generatedMediaID: UUID?
            let generatedRelPath: String?
            // Call the private impl directly with `chatNote: nil` so we
            // don't emit a duplicate chat bubble — the agent runner
            // already emits one from `userSummary` below (with the
            // image attachment path plumbed through AgentToolOutcome).
            let result = await generateAIImage(
                prompt: request.prompt,
                size: request.size,
                insertAt: request.insertAt,
                overlayDuration: request.insertAt == nil ? 0 : request.durationSeconds,
                chatNote: nil
            )
            generatedMediaID = result?.mediaID
            generatedRelPath = result?.relativePath

            guard let mediaID = generatedMediaID else {
                // `generateAIImage` surfaces the actual failure via
                // `bannerMessage`; forward whatever's current.
                let reason = bannerMessage ?? "Image generation failed."
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError(reason),
                    userSummary: "⚠️ \(reason)",
                    checkpointID: nil
                )
            }

            if let at = request.insertAt {
                return AgentToolOutcome(
                    resultJSON: "{\"ok\":true,\"media_id\":\"\(mediaID.uuidString)\",\"composed_time\":\(at),\"duration_seconds\":\(request.durationSeconds)}",
                    userSummary: "🎨 Generated image and inserted at \(String(format: "%.1fs", at)) for \(String(format: "%.1fs", request.durationSeconds)).",
                    checkpointID: imageCheckpointID,
                    imageAttachmentPath: generatedRelPath
                )
            } else {
                return AgentToolOutcome(
                    resultJSON: "{\"ok\":true,\"media_id\":\"\(mediaID.uuidString)\",\"inserted\":false}",
                    userSummary: "🎨 Generated image — added to your Media Browser.",
                    checkpointID: nil,
                    imageAttachmentPath: generatedRelPath
                )
            }

        case "update_overlay_props":
            guard let request = UpdateOverlayPropsRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid update_overlay_props arguments. Need segment_id (UUID string) and props_patch (JSON object)."),
                    userSummary: "⚠️ Invalid update_overlay_props arguments",
                    checkpointID: nil
                )
            }
            // Parse the patch as a dictionary once for the VM merge path.
            guard let patchData = request.propsPatchJSON.data(using: .utf8),
                  let patchDict = (try? JSONSerialization.jsonObject(with: patchData)) as? [String: Any]
            else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("props_patch must be a JSON object."),
                    userSummary: "⚠️ Invalid update_overlay_props arguments",
                    checkpointID: nil
                )
            }
            // Attachment-scope guard: reject updates targeting segments
            // outside the attached set. Mirrors ScopeGuard's policy for
            // id-based AIActions.
            let updateScope = chatAttachmentScope
            if !updateScope.isEmpty {
                let attachedIDs = Set(updateScope.entries.map(\.segmentID))
                if !attachedIDs.contains(request.segmentID) {
                    return AgentToolOutcome(
                        resultJSON: AgentToolJSON.encodeError(
                            "segment_id \(request.segmentID.uuidString) is not in the attached scope. Only overlays on the attached segments can be edited. Attached segment ids: \(updateScope.entries.map { $0.segmentID.uuidString }.joined(separator: ", "))."
                        ),
                        userSummary: "⚠️ Overlay edit rejected: segment not in attached scope",
                        checkpointID: nil
                    )
                }
            }

            let label = "Update overlay props for \(request.segmentID.uuidString.prefix(8))"
            pushRevision(label: String(label), trigger: .aiAction(messageID: userMessageID))
            let updateCheckpointID = revisions.last?.id

            await updateOverlayProps(segmentID: request.segmentID, propsPatch: patchDict)

            if let banner = bannerMessage, banner.contains("Overlay") {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError(banner),
                    userSummary: "⚠️ \(banner)",
                    checkpointID: nil
                )
            }

            return AgentToolOutcome(
                resultJSON: "{\"ok\":true,\"segment_id\":\"\(request.segmentID.uuidString)\"}",
                userSummary: "✏️ Updated overlay props",
                checkpointID: updateCheckpointID
            )

        case "get_frame_at":
            guard let request = GetFrameAtRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid get_frame_at arguments. Need composed_time (number)."),
                    userSummary: "⚠️ Invalid get_frame_at arguments",
                    checkpointID: nil
                )
            }
            let sourceURLs: [UUID: URL] = Dictionary(uniqueKeysWithValues: records.map {
                ($0.id, URL(fileURLWithPath: $0.sourcePath))
            })
            guard let sample = await AgentFrameSampler.sample(
                composedTime: request.composedTime,
                segments: timelineSegments,
                sourceURLByID: sourceURLs,
                maxDimension: request.maxDimension
            ) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Could not sample frame at \(request.composedTime)s — time may be outside the timeline or source is missing."),
                    userSummary: "⚠️ Could not sample frame at \(String(format: "%.2fs", request.composedTime)).",
                    checkpointID: nil
                )
            }
            let base64 = sample.jpegData.base64EncodedString()
            // Subtitle cue that covers this instant (if any).
            let cue = composedSubtitles.first { $0.startSeconds <= request.composedTime && request.composedTime < $0.endSeconds }
            let cueText = cue?.text ?? ""
            // NOTE: We DO NOT feed the base64 blob into messages (context
            // budget blow-up). Instead, we return small metadata + a
            // truncated preview so the LLM knows the call succeeded, and
            // attach the JPEG to the chat panel as a side-effect so the
            // user can inspect it. A future refactor can route this
            // through a multi-modal content message when the provider
            // supports it directly.
            let payload: [String: Any] = [
                "ok": true,
                "composed_time": request.composedTime,
                "source_time": sample.sourceTime,
                "segment_id": sample.segmentID.uuidString,
                "subtitle_text": cueText,
                "jpeg_bytes": sample.jpegData.count,
                "jpeg_preview_b64_head": String(base64.prefix(64))
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return AgentToolOutcome(
                resultJSON: json,
                userSummary: "🖼 Sampled frame at \(String(format: "%.2fs", request.composedTime))\(cueText.isEmpty ? "" : " — caption: \"\(cueText)\"")",
                checkpointID: nil
            )

        case "set_segment_volume":
            guard let request = SetSegmentVolumeRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid set_segment_volume arguments. Need segment_id (UUID) and level (number 0…2)."),
                    userSummary: "⚠️ Invalid set_segment_volume arguments",
                    checkpointID: nil
                )
            }
            guard let idx = timelineSegments.firstIndex(where: { $0.id == request.segmentID }) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("segment_id \(request.segmentID.uuidString) is not in the current timeline."),
                    userSummary: "⚠️ Volume target segment not found.",
                    checkpointID: nil
                )
            }
            let previous = timelineSegments[idx].volumeLevel
            if abs(previous - request.level) < 0.001 {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encode(["ok": true, "unchanged": true]),
                    userSummary: "🔊 Volume already at \(Int(request.level * 100))%.",
                    checkpointID: nil
                )
            }
            pushRevision(
                label: "Set segment volume to \(Int(request.level * 100))%",
                trigger: .aiAction(messageID: userMessageID)
            )
            var segs = timelineSegments
            segs[idx].volumeLevel = request.level
            timelineSegments = segs
            rebuildComposition()
            return AgentToolOutcome(
                resultJSON: "{\"ok\":true,\"previous_level\":\(previous),\"new_level\":\(request.level)}",
                userSummary: "🔊 Set segment volume to \(Int(request.level * 100))%.",
                checkpointID: revisions.last?.id
            )

        case "audio_ducking":
            guard let request = AudioDuckingRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid audio_ducking arguments. Need duck_level (number 0…1); track_id optional."),
                    userSummary: "⚠️ Invalid audio_ducking arguments",
                    checkpointID: nil
                )
            }
            let targets: [UUID]
            if let trackID = request.trackID {
                guard project.audioTracks.contains(where: { $0.id == trackID }) else {
                    return AgentToolOutcome(
                        resultJSON: AgentToolJSON.encodeError("track_id \(trackID.uuidString) is not a BGM track."),
                        userSummary: "⚠️ BGM track not found.",
                        checkpointID: nil
                    )
                }
                targets = [trackID]
            } else {
                targets = project.audioTracks.map(\.id)
            }
            if targets.isEmpty {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("No BGM tracks to duck. Import audio first."),
                    userSummary: "⚠️ No BGM to duck.",
                    checkpointID: nil
                )
            }
            for id in targets { setAuxTrackVolume(id: id, volume: request.duckLevel) }
            return AgentToolOutcome(
                resultJSON: "{\"ok\":true,\"ducked_tracks\":\(targets.count),\"duck_level\":\(request.duckLevel)}",
                userSummary: "🎧 Ducked \(targets.count) BGM track(s) to \(Int(request.duckLevel * 100))%.",
                checkpointID: revisions.last?.id
            )

        case "normalize_loudness":
            let request = NormalizeLoudnessRequest.parse(from: args)
            await normalizeLoudness(targetDB: request.targetDB)
            return AgentToolOutcome(
                resultJSON: "{\"ok\":true,\"target_db\":\(request.targetDB)}",
                userSummary: "🎚 Normalized loudness to \(Int(request.targetDB)) dB.",
                checkpointID: revisions.last?.id
            )

        case "auto_pip":
            let overlayCount = project.overlayTracks.reduce(0) { $0 + $1.segments.count }
            guard overlayCount > 0 else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("No overlay clips on the timeline yet. Insert an overlay (e.g. via insert_broll or the Import Media shelf) first, then call auto_pip."),
                    userSummary: "⚠️ Auto PiP: no overlay clips on the timeline.",
                    checkpointID: nil
                )
            }
            let before = revisions.last?.id
            let result = await runAutoPiPAnalysis()
            struct AutoPiPToolResult: Codable {
                let ok: Bool
                let attempted: Int
                let applied: Int
                let applied_overlay_ids: [String]
            }
            let payload = AutoPiPToolResult(
                ok: true,
                attempted: result.attempted,
                applied: result.applied,
                applied_overlay_ids: result.appliedIDs.map(\.uuidString)
            )
            let summary: String
            if result.attempted == 0 {
                summary = "🪟 Auto PiP: every overlay already has a Picture-in-Picture layout — nothing to do."
            } else if result.applied == 0 {
                summary = "🪟 Auto PiP: analyzed \(result.attempted) overlay\(result.attempted == 1 ? "" : "s"), none looked like a presenter cam."
            } else {
                summary = "🪟 Auto PiP: placed \(result.applied) of \(result.attempted) overlay\(result.attempted == 1 ? "" : "s") as corner Picture-in-Picture."
            }
            // Only surface a checkpoint if the run actually mutated
            // the project (setPiPLayout pushes revisions).
            let after = revisions.last?.id
            let checkpointID = (result.applied > 0 && after != before) ? after : nil
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(payload),
                userSummary: summary,
                checkpointID: checkpointID
            )

        case "suggest_broll":
            let request = SuggestBRollRequest.parse(from: args)
            let manifest = (try? store?.loadManifest()) ?? nil
            let targetIDs: [UUID]
            if let id = request.sourceVideoID {
                targetIDs = [id]
            } else {
                // Cover every unique source referenced by the current cut.
                targetIDs = Array(Set(timelineSegments.map(\.sourceVideoID)))
            }
            var total = 0
            for id in targetIDs {
                guard
                    let record = manifest?.media.first(where: { $0.id == id }),
                    let snapshot = record.copilot,
                    let transcript = snapshot.transcript,
                    let ranges = snapshot.keptRanges
                else { continue }
                let kept = Self.transcriptSegmentsFor(ranges: ranges, transcript: transcript)
                await refreshBRollSuggestions(for: id, keptTranscript: kept)
                if let refreshed = (try? store?.loadManifest())?.media.first(where: { $0.id == id })?.copilot?.bRollSuggestions {
                    total += refreshed.filter { !$0.isDismissed }.count
                }
            }
            return AgentToolOutcome(
                resultJSON: "{\"ok\":true,\"suggestion_count\":\(total)}",
                userSummary: total == 0
                    ? "No new B-roll suggestions."
                    : "🎯 \(total) B-roll suggestion\(total == 1 ? "" : "s") above the timeline.",
                checkpointID: nil
            )

        case "translate_subtitles":
            guard let request = TranslateSubtitlesRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid translate_subtitles arguments. Need target_locale (BCP-47 string). Optional: cue_ids (array of UUIDs), force (bool)."),
                    userSummary: "⚠️ Invalid translate_subtitles arguments",
                    checkpointID: nil
                )
            }
            guard let config = OpenAIConfiguration.fromEnvironment() else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("OpenAI not configured — cannot translate."),
                    userSummary: "⚠️ Translation needs an OpenAI key configured.",
                    checkpointID: nil
                )
            }

            // Build the work list. For every primary-track subtitle
            // cue: skip (a) when the cue is not in the caller's
            // `cueIDs` subset, (b) when it already has a translation
            // for the target locale and `force` is false.
            //
            // NOTE: we deliberately do **not** persist segment/entry
            // *indices* here. `engine.translate` awaits the network for
            // tens of seconds; during that window other tools or UI
            // edits can insert/delete cues, split segments, or reorder
            // the timeline. Writing back by index would mean either
            // crashing (index out of bounds) or — worse — writing A's
            // translation onto B's cue. We key by `cueID` and look up
            // the owning segment/entry again on the main actor after
            // the await returns.
            struct CueInputSnapshot {
                let id: UUID
                let text: String
            }
            var candidates: [CueInputSnapshot] = []
            var skippedExisting = 0
            let subset: Set<UUID>? = request.cueIDs.map(Set.init)
            for seg in timelineSegments {
                for entry in seg.subtitles {
                    let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let subset, !subset.contains(entry.id) { continue }
                    if !request.force,
                       let existing = entry.translations[request.targetLocale]?
                           .trimmingCharacters(in: .whitespacesAndNewlines),
                       !existing.isEmpty {
                        skippedExisting += 1
                        continue
                    }
                    candidates.append(CueInputSnapshot(
                        id: entry.id,
                        text: trimmed
                    ))
                }
            }

            // Nothing to do — common path when the user asks for the
            // same locale twice. Emit a clean no-op.
            if candidates.isEmpty {
                let payload = TranslateSubtitlesToolResult(
                    ok: true,
                    locale: request.targetLocale,
                    attempted: 0,
                    translated: 0,
                    skipped: skippedExisting,
                    failedCueIDs: []
                )
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encode(payload),
                    userSummary: skippedExisting > 0
                        ? "🌐 \(request.targetLocale): every cue already has a translation (\(skippedExisting) skipped)."
                        : "🌐 No subtitle cues to translate.",
                    checkpointID: nil
                )
            }

            let client = OpenAIClient(configuration: config)
            let engine = SubtitleTranslationEngine(client: client)

            let isEnglish = Self.currentAppLanguageIsEnglish()
            let locale = request.targetLocale
            let inputs = candidates.map {
                SubtitleTranslationEngine.CueInput(id: $0.id, text: $0.text)
            }
            let totalToTranslate = candidates.count
            let outcome = await engine.translate(
                cues: inputs,
                into: request.targetLocale,
                onBatchComplete: { [weak self] done, total in
                    await MainActor.run {
                        guard let self else { return }
                        // Rewrite the current live-narration bubble with
                        // a translation-specific status line. We don't
                        // mint a new bubble — reuses whatever one the
                        // agent loop already spawned for this turn.
                        if let idx = self.chatMessages.lastIndex(where: { $0.isLiveNarration }) {
                            let line = isEnglish
                                ? "Translating \(done) of \(total) subtitle cues → \(locale)…"
                                : "正在翻译字幕 \(done)/\(total) 条 → \(locale)…"
                            self.chatMessages[idx].content = line
                            self.chatMessages[idx].iconTone = .working
                        }
                    }
                }
            )

            // Re-resolve each cue by UUID on the freshly read
            // `timelineSegments` — the snapshot we built before the
            // await may be stale. Cues that no longer exist
            // (user deleted them during translation) are silently
            // dropped; cues that moved between segments are written
            // in their new home. This is the only safe behavior given
            // segments can be split/merged/reordered during the await.
            let merge = mergeSubtitleTranslations(
                into: timelineSegments,
                translations: outcome.translations,
                locale: request.targetLocale
            )
            let mutated = merge.segments
            let writeCount = merge.writeCount
            let missingDuringAwait = merge.missingCount

            // Only snapshot + commit when we actually have writes.
            // Pushing a revision when writeCount == 0 (every batch
            // failed, or every cue vanished mid-await) would leave a
            // blank "Translate subtitles → X" checkpoint in history
            // that undo would step through for no reason.
            var checkpointID: UUID? = nil
            if writeCount > 0 {
                pushRevision(
                    label: "Translate subtitles → \(request.targetLocale)",
                    trigger: .aiAction(messageID: userMessageID)
                )
                checkpointID = revisions.last?.id
                timelineSegments = mutated
                rebuildComposedSubtitles()
            }

            let payload = TranslateSubtitlesToolResult(
                ok: true,
                locale: request.targetLocale,
                attempted: totalToTranslate,
                translated: writeCount,
                skipped: skippedExisting,
                failedCueIDs: outcome.failedIDs.map(\.uuidString)
            )
            let summary: String
            var summaryParts: [String] = []
            if writeCount > 0 {
                summaryParts.append("🌐 Translated \(writeCount)/\(totalToTranslate) → \(request.targetLocale)")
            } else {
                summaryParts.append("🌐 0/\(totalToTranslate) translated → \(request.targetLocale)")
            }
            if !outcome.failedIDs.isEmpty {
                summaryParts.append("\(outcome.failedIDs.count) cue(s) failed — retry later or translate them manually")
            }
            if missingDuringAwait > 0 {
                summaryParts.append("\(missingDuringAwait) cue(s) removed before write-back")
            }
            summary = summaryParts.joined(separator: ". ") + "."
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(payload),
                userSummary: summary,
                checkpointID: checkpointID
            )

        case "emphasize_words":
            guard let request = EmphasizeWordsRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid emphasize_words arguments. Need cue_id or at_time; plus either clear_all=true, or a non-empty style with words / utf16_ranges."),
                    userSummary: "⚠️ Invalid emphasize_words arguments",
                    checkpointID: nil
                )
            }

            // Resolve target cue: explicit id first, then at_time → the
            // cue active at that playhead moment. We look inside
            // `timelineSegments` rather than `composedSubtitles` because
            // the VM API wants the underlying SubtitleEntry.id.
            func lookupCueText(_ id: UUID) -> String? {
                for seg in timelineSegments {
                    if let hit = seg.subtitles.first(where: { $0.id == id }) {
                        return hit.text
                    }
                }
                return nil
            }

            let targetCueID: UUID?
            let cueText: String?
            if let explicitID = request.cueID,
               let text = lookupCueText(explicitID) {
                targetCueID = explicitID
                cueText = text
            } else if let t = request.atTime,
                      let composed = composedSubtitles.first(where: {
                          t >= $0.startSeconds && t < $0.endSeconds
                      }),
                      let text = lookupCueText(composed.id) {
                targetCueID = composed.id
                cueText = text
            } else {
                targetCueID = nil
                cueText = nil
            }

            guard let cueID = targetCueID, let text = cueText else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Subtitle cue not found for cue_id / at_time."),
                    userSummary: "⚠️ Cue not found.",
                    checkpointID: nil
                )
            }

            if request.clearAll {
                let ok = clearEmphasisOnSubtitle(cueID: cueID)
                let payload = EmphasizeWordsToolResult(
                    ok: ok,
                    cueID: cueID.uuidString,
                    rangesApplied: 0,
                    wordsMatched: [],
                    wordsNotFound: [],
                    cleared: ok
                )
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encode(payload),
                    userSummary: ok
                        ? "✏️ Cleared emphasis on cue."
                        : "Cue had no emphasis to clear.",
                    checkpointID: ok ? revisions.last?.id : nil
                )
            }

            // Build the range list. `words` → substring search;
            // `utf16_ranges` are taken as-is (clamped by the VM).
            let matchResult = EmphasizeWordsMatcher.resolve(
                words: request.words,
                inCueText: text
            )
            var allRanges = matchResult.ranges
            allRanges.append(contentsOf: request.utf16Ranges)

            if allRanges.isEmpty {
                let payload = EmphasizeWordsToolResult(
                    ok: false,
                    cueID: cueID.uuidString,
                    rangesApplied: 0,
                    wordsMatched: matchResult.wordsMatched,
                    wordsNotFound: matchResult.wordsNotFound,
                    cleared: false
                )
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encode(payload),
                    userSummary: request.words.isEmpty
                        ? "⚠️ No ranges supplied."
                        : "⚠️ None of the requested words were found in the cue.",
                    checkpointID: nil
                )
            }

            let applied = applyEmphasisToSubtitle(
                cueID: cueID,
                utf16Ranges: allRanges,
                patch: request.style,
                replace: request.replace
            )

            let payload = EmphasizeWordsToolResult(
                ok: applied,
                cueID: cueID.uuidString,
                rangesApplied: applied ? allRanges.count : 0,
                wordsMatched: matchResult.wordsMatched,
                wordsNotFound: matchResult.wordsNotFound,
                cleared: false
            )
            let summaryText: String
            if applied {
                var parts: [String] = ["✏️ Emphasized \(allRanges.count) range(s)"]
                if !matchResult.wordsNotFound.isEmpty {
                    parts.append("missing: \(matchResult.wordsNotFound.joined(separator: ", "))")
                }
                summaryText = parts.joined(separator: " — ") + "."
            } else {
                summaryText = "⚠️ Failed to apply emphasis (ranges out of bounds?)."
            }
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(payload),
                userSummary: summaryText,
                checkpointID: applied ? revisions.last?.id : nil
            )

        case "detect_speakers":
            let request = DetectSpeakersRequest.parse(from: args)
            // detect_speakers is a self-sufficient feature: if the
            // timeline has no transcript yet (fresh import, user
            // clicked "Detect speakers" as their first action), run a
            // minimal transcribe-only path and then diarize. We
            // intentionally do NOT escalate to run_first_cut here —
            // that would recut the user's video without consent. See
            // commits 41af14e + this commit for the history.
            if composedSubtitles.isEmpty {
                let transcribed = await transcribeForDiarization()
                if !transcribed || composedSubtitles.isEmpty {
                    return AgentToolOutcome(
                        resultJSON: AgentToolJSON.encodeError(
                            "transcription_failed: detect_speakers tried to transcribe the timeline first "
                            + "but the local transcription pipeline failed (no audio? proxy missing?). "
                            + "DO NOT call run_first_cut, run_full_analysis, or any other cutting tool to recover — "
                            + "stop the tool loop and ask the user to verify the clip has audio."
                        ),
                        userSummary: "⚠️ 自动转录失败，无法识别说话人。",
                        checkpointID: nil
                    )
                }
            }
            await autoDetectSpeakers(
                pauseThreshold: request.pauseThreshold,
                speakerCount: request.speakerCount
            )
            let distinct = Set(timelineSegments.flatMap { $0.subtitles.compactMap(\.speakerID) })
            return AgentToolOutcome(
                resultJSON: "{\"ok\":true,\"detected_speakers\":\(distinct.count),\"pause_threshold\":\(request.pauseThreshold)}",
                userSummary: "🗣 Detected \(distinct.count) speaker(s).",
                checkpointID: revisions.last?.id
            )

        case "find_by_speaker":
            guard let request = FindBySpeakerRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid find_by_speaker arguments. Need speaker_id (int)."),
                    userSummary: "⚠️ Invalid find_by_speaker arguments",
                    checkpointID: nil
                )
            }
            let matches = AgentSpeakerQuery.findBySpeaker(
                speakerID: request.speakerID,
                in: timelineSegments
            )
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(["matches": matches]),
                userSummary: matches.isEmpty
                    ? "No cues found for speaker \(request.speakerID). Run detect_speakers first."
                    : "🗣 Speaker \(request.speakerID) → \(matches.count) cue(s).",
                checkpointID: nil
            )

        case "mute_speaker":
            guard let request = MuteSpeakerRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid mute_speaker arguments. Need speaker_id (int)."),
                    userSummary: "⚠️ Invalid mute_speaker arguments",
                    checkpointID: nil
                )
            }
            let targetIDs = AgentSpeakerQuery.segmentsDominatedBy(
                speakerID: request.speakerID,
                in: timelineSegments
            )
            if targetIDs.isEmpty {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("No segments dominated by speaker \(request.speakerID). Call detect_speakers first or pick a different speaker_id."),
                    userSummary: "⚠️ No segments for speaker \(request.speakerID).",
                    checkpointID: nil
                )
            }
            if request.muteAudioOnly {
                pushRevision(
                    label: "Mute speaker \(request.speakerID) on \(targetIDs.count) segment(s)",
                    trigger: .aiAction(messageID: userMessageID)
                )
                var segs = timelineSegments
                for i in segs.indices where targetIDs.contains(segs[i].id) {
                    segs[i].volumeLevel = 0
                }
                timelineSegments = segs
                rebuildComposition()
                return AgentToolOutcome(
                    resultJSON: "{\"ok\":true,\"muted\":\(targetIDs.count),\"speaker_id\":\(request.speakerID)}",
                    userSummary: "🔇 Muted speaker \(request.speakerID) on \(targetIDs.count) segment(s).",
                    checkpointID: revisions.last?.id
                )
            } else {
                // Route through edit_timeline so the user gets the
                // usual manual-mode Apply/Reject gate on destructive
                // edits. We synthesize a batch of deleteSegment
                // actions.
                let batch = AIActionBatch(
                    actions: targetIDs.map { .deleteSegment(id: $0) },
                    explanation: "Delete \(targetIDs.count) segment(s) dominated by speaker \(request.speakerID)"
                )
                let result = AIActionExecutor.apply(
                    batch: batch,
                    to: timelineSegments,
                    baseSubtitleStyle: subtitleStyle,
                    transcriptLookup: { ranges, sourceID in
                        self.subtitleEntries(for: ranges, sourceVideoID: sourceID)
                    }
                )
                switch agentMode {
                case .autoApply:
                    return commitAgentBatch(
                        batch: batch,
                        dryRun: result,
                        userMessageID: userMessageID
                    )
                case .manual:
                    let proposal = ProposedBatch.make(
                        toolCallID: toolCall.id,
                        batch: batch,
                        before: timelineSegments,
                        dryRun: result
                    )
                    pendingProposals.insert(proposal, at: 0)
                    let bubble = "📝 Pending: delete \(targetIDs.count) segment(s) for speaker \(request.speakerID)"
                    return AgentToolOutcome(
                        resultJSON: "{\"ok\":true,\"proposed\":\(targetIDs.count),\"speaker_id\":\(request.speakerID)}",
                        userSummary: bubble,
                        checkpointID: nil,
                        proposedBatchID: proposal.id
                    )
                }
            }

        case "suggest_title":
            let request = SuggestTitleRequest.parse(from: args)
            let bundle = AgentGenerativeInput.transcript(
                from: timelineSegments,
                language: request.language
            )
            let payload: [String: Any] = [
                "max_length": request.maxLength,
                "language": request.language,
                "transcript_cue_count": bundle.cues.count,
                "total_duration_seconds": bundle.totalDurationSeconds,
                "transcript_excerpt": bundle.cues.prefix(60).map(\.text).joined(separator: " "),
                "instruction": "Produce 3 title candidates (≤\(request.maxLength) chars each). Output them in the next assistant message as a numbered list. Titles should reflect the transcript — do not invent topics."
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return AgentToolOutcome(
                resultJSON: json,
                userSummary: nil,
                checkpointID: nil
            )

        case "suggest_chapters":
            let request = SuggestChaptersRequest.parse(from: args)
            let bundle = AgentGenerativeInput.transcript(
                from: timelineSegments,
                language: request.language
            )
            let payload: [String: Any] = [
                "target_count": request.targetCount,
                "language": request.language,
                "total_duration_seconds": bundle.totalDurationSeconds,
                "cues": bundle.cues.prefix(150).map { cue in
                    [
                        "start": cue.start,
                        "end": cue.end,
                        "text": cue.text
                    ] as [String: Any]
                },
                "instruction": "Partition the timeline into ~\(request.targetCount) chapters. In the next assistant message, output JSON-like lines like `HH:MM:SS — Chapter label` sorted by start time. Labels ≤ 32 chars, based on what is actually said, no filler."
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return AgentToolOutcome(
                resultJSON: json,
                userSummary: nil,
                checkpointID: nil
            )

        case "restore_checkpoint":
            guard let request = RestoreCheckpointRequest.parse(from: args) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid restore_checkpoint arguments"),
                    userSummary: "⚠️ Invalid restore_checkpoint arguments",
                    checkpointID: nil
                )
            }

            let restoreCheckpoints = availableRestoreCheckpoints(limit: 12)
            guard let targetRevision = request.resolveCheckpoint(
                from: restoreCheckpoints,
                allRevisions: revisions
            ) else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Checkpoint not found"),
                    userSummary: "⚠️ I couldn't find that checkpoint in the available history.",
                    checkpointID: nil
                )
            }

            restoreRevision(id: targetRevision.id)
            let reasonLine = (request.reason?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : "\n\($0)" } ?? ""
            let responseText = "↩️ Restored checkpoint: \(targetRevision.label)\(reasonLine)"
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(["restored": targetRevision.label]),
                userSummary: responseText,
                checkpointID: revisions.last?.id
            )

        case "find_filler_words":
            let extra = (args["extra_terms"] as? [String]) ?? []
            let terms = AgentDefaults.fillerWords + extra
            let matches = AgentQuery.findFillerWords(in: timelineSegments, fillerTerms: terms)
            let summary = "🔍 Found \(matches.count) filler-word cue(s)."
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(["matches": matches]),
                userSummary: summary,
                checkpointID: nil
            )

        case "find_by_transcript":
            guard let query = args["query"] as? String, !query.isEmpty else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Missing query"),
                    userSummary: nil,
                    checkpointID: nil
                )
            }
            let matches = AgentQuery.findByTranscript(query: query, in: timelineSegments)
            let summary = "🔍 \"\(query)\" → \(matches.count) match(es)."
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(["matches": matches]),
                userSummary: summary,
                checkpointID: nil
            )

        case "get_timeline_summary":
            let names = Dictionary(uniqueKeysWithValues: records.map { r in
                (r.id, r.sourcePath.components(separatedBy: "/").last ?? r.id.uuidString.prefix(8).description)
            })
            let summary = AgentQuery.summarize(segments: timelineSegments, sourceNamesByID: names)
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(summary),
                userSummary: nil, // silent — usually a precursor to another tool
                checkpointID: nil
            )

        case "get_segment_detail":
            let rawIDs = (args["segment_ids"] as? [String]) ?? []
            let uuids = rawIDs.compactMap(UUID.init(uuidString:))
            let names = Dictionary(uniqueKeysWithValues: records.map { r in
                (r.id, r.sourcePath.components(separatedBy: "/").last ?? r.id.uuidString.prefix(8).description)
            })
            // Cap at 40 segments per call to protect context budget.
            let cap = 40
            let allDetails = AgentQuery.segmentDetails(
                timelineSegments,
                ids: uuids,
                sourceNamesByID: names
            )
            let truncated = allDetails.count > cap
            let payload: [String: Any] = [
                "segments": AgentToolJSON.encode(Array(allDetails.prefix(cap))),
                "truncated": truncated,
                "total": allDetails.count
            ]
            // Re-encode as JSON (the "segments" value is already a JSON
            // string — emit as an embedded array).
            let segmentsJSON = AgentToolJSON.encode(Array(allDetails.prefix(cap)))
            let out = "{\"segments\":\(segmentsJSON),\"truncated\":\(truncated),\"total\":\(allDetails.count)}"
            _ = payload
            return AgentToolOutcome(
                resultJSON: out,
                userSummary: nil,
                checkpointID: nil
            )

        case "score_hook_candidates":
            // Reject in scoped chat: scope means the user has narrowed the
            // agent to specific segments / ranges, so scanning every source
            // for an unrelated hook violates that intent and would produce
            // candidates that `insertSourceClip` (PR 2) will refuse anyway.
            if !chatAttachmentScope.isEmpty {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("score_hook_candidates needs the full project — detach the scope chips above the chat box and try again."),
                    userSummary: "⚠️ 选定范围下不能跨素材找开场金句，先取消上方附件再试。",
                    checkpointID: nil
                )
            }
            // top_k now means FINAL count after stage-2 rerank. Default 5
            // (was 20 in PR 3 before the rerank existed). Stage-1 internally
            // pulls a larger pool so the LLM has something to rerank.
            let topKRaw = (args["top_k"] as? Int) ?? Int((args["top_k"] as? Double) ?? 5)
            let finalCount = max(1, min(20, topKRaw))
            let stage1Pool = max(20, finalCount * 4)
            let minDuration = (args["min_duration"] as? Double) ?? 2.5
            let maxDuration = (args["max_duration"] as? Double) ?? 10.0
            let idealDuration = (args["ideal_duration"] as? Double) ?? 5.0
            let bounds = HookCandidateScorer.Bounds(
                minDuration: minDuration,
                maxDuration: maxDuration,
                idealDuration: idealDuration
            )
            guard bounds.isValid else {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("Invalid bounds: require 0 < min_duration ≤ ideal_duration ≤ max_duration."),
                    userSummary: "⚠️ 时长参数不合法（min ≤ ideal ≤ max）",
                    checkpointID: nil
                )
            }
            let sources = AgentHook.collectSources(from: records)
            let extraTerms = (args["extra_filler_terms"] as? [String]) ?? []
            let (stage1Candidates, stats) = HookCandidateScorer.scoreSources(
                sources,
                fillerTerms: AgentDefaults.fillerWords + extraTerms,
                bounds: bounds,
                topK: stage1Pool
            )
            // Stage-2 LLM rerank. Skipped silently when the LLM client
            // can't be configured (BYOK without key); falls back to
            // stage-1 ordering on parse / network / timeout failure.
            let rerankResult: HookCandidateRerankEngine.Result
            if stage1Candidates.count >= 2,
               let config = OpenAIConfiguration.fromEnvironment() {
                let engine = HookCandidateRerankEngine(client: OpenAIClient(configuration: config))
                rerankResult = await engine.rerank(stageOne: stage1Candidates, topK: finalCount)
            } else {
                rerankResult = HookCandidateRerankEngine.Result(
                    candidates: Array(stage1Candidates.prefix(finalCount)),
                    status: .skipped
                )
            }
            let summary: String
            if rerankResult.candidates.isEmpty {
                if stats.sourcesScanned == 0 {
                    summary = "🎯 还没有可分析的素材"
                } else if stats.sourcesWithoutTranscript == stats.sourcesScanned {
                    summary = "🎯 没有可用转录 — 先 First Cut 或转录后再试"
                } else {
                    summary = "🎯 没找到合适的开场金句候选"
                }
            } else {
                let suffix: String
                switch rerankResult.status {
                case .ok:       suffix = "（AI 已挑选）"
                case .fallback: suffix = "（AI 暂不可用，仅启发式排序）"
                case .skipped:  suffix = ""
                }
                summary = "🎯 找到 \(rerankResult.candidates.count) 条开场金句候选\(suffix)"
            }
            // PR 7: persist the latest shortlist as `.highlight` markers
            // on each source recording's copilot snapshot so downstream
            // UIs (Highlights panel etc.) can read the candidate set
            // directly from the manifest. PR 8 narrowed the replacement
            // semantics to AI-origin markers only — manual-origin
            // highlights that the user saved by hand are preserved
            // through every rerun.
            //
            // The save path re-loads the manifest and merges into the
            // *fresh* on-disk snapshot rather than overwriting with the
            // pre-rerank `records` capture, so any concurrent analysis
            // writes that landed while the rerank LLM was running don't
            // get clobbered.
            let markerUpdates = AgentHook.computeHighlightMarkerUpdates(
                candidates: rerankResult.candidates,
                records: records
            )
            if !markerUpdates.isEmpty, let store {
                do {
                    var manifest = try store.loadManifest()
                    for update in markerUpdates {
                        guard let idx = manifest.media.firstIndex(where: { $0.id == update.recordID }) else { continue }
                        guard var snapshot = manifest.media[idx].copilot else { continue }
                        // Drop only AI-origin `.highlight` markers; keep manual
                        // user-saved highlights and every other marker kind.
                        snapshot.markers = snapshot.markers.filter {
                            !($0.kind == .highlight && $0.origin == .ai)
                        } + update.newHighlights
                        manifest.media[idx].copilot = snapshot
                    }
                    try store.saveManifest(manifest)
                    await loadRecords()
                } catch {
                    print("⚠️ score_hook_candidates marker persist failed: \(error)")
                }
            }
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encode(AgentHook.Result(
                    candidates: rerankResult.candidates,
                    stats: stats,
                    rerankStatus: rerankResult.status.rawValue
                )),
                userSummary: summary,
                checkpointID: nil
            )

        case "add_hook_teaser":
            // Hook insertion always produces a Pending proposal — even
            // when the user has Auto-Apply enabled. Cold-open is too
            // high-stakes to slam in without explicit consent.
            if !chatAttachmentScope.isEmpty {
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError("add_hook_teaser needs the full project — detach the scope chips above the chat box and try again."),
                    userSummary: "⚠️ 选定范围下不能插入开场金句，先取消上方附件再试。",
                    checkpointID: nil
                )
            }
            switch AgentHook.parseHookTeaserArgs(args: args, records: records) {
            case .failure(let err):
                return AgentToolOutcome(
                    resultJSON: AgentToolJSON.encodeError(err.userMessage),
                    userSummary: "⚠️ \(err.userMessage)",
                    checkpointID: nil
                )
            case .success(let inputs):
                switch proposeHookFromInputs(inputs, toolCallID: toolCall.id) {
                case .failure(.validation(let bullets)):
                    let joined = bullets.map { "• \($0)" }.joined(separator: "\n")
                    return AgentToolOutcome(
                        resultJSON: AgentToolJSON.encodeError("Pre-flight rejected: \(joined)"),
                        userSummary: "⚠️ Pre-flight rejected:\n\(joined)",
                        checkpointID: nil
                    )
                case .success(let result):
                    let duration = inputs.sourceEnd - inputs.sourceStart
                    return AgentToolOutcome(
                        resultJSON: AgentToolJSON.encode(AddHookTeaserToolResult(
                            status: "pending_user_apply",
                            durationSeconds: duration,
                            requiresUserConfirmation: true,
                            nextSteps: "Wait for the user to click Apply on the proposal card before any overlay/SFX follow-up. Do not propose more edits in this turn."
                        )),
                        userSummary: result.bubbleSummary,
                        checkpointID: nil,
                        proposedBatchID: result.proposal.id
                    )
                }
            }

        case "run_first_cut":
            let request = RunFirstCutRequest.parse(from: args)
            return await runFirstCutTool(request, userMessageID: userMessageID)

        default:
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encodeError("Unknown tool: \(toolCall.function.name)"),
                userSummary: "⚠️ Unknown tool: \(toolCall.function.name)",
                checkpointID: nil
            )
        }
    }

    /// Run the full first-cut pipeline as an agent tool. Pushes a
    /// pre-state revision so `restore_checkpoint` rewinds past it,
    /// returns a checkpoint ID for the chat trail, and reports a
    /// concise summary that the model can react to on the next step.
    private func runFirstCutTool(
        _ request: RunFirstCutRequest,
        userMessageID: UUID
    ) async -> AgentToolOutcome {
        guard analysisPipeline != nil, store != nil else {
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encodeError("Analysis pipeline is not configured for this project."),
                userSummary: "⚠️ Analysis pipeline not configured.",
                checkpointID: nil
            )
        }
        guard !isAnalyzing else {
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encodeError("Another analysis run is already in progress. Wait for it to finish before retrying."),
                userSummary: "⚠️ AI first cut already running.",
                checkpointID: nil
            )
        }
        // Timeline drives first cut — only video clips currently
        // placed on V1 (deduped by source, in timeline order) are
        // eligible. Library-only clips that the user dragged off the
        // timeline are intentionally skipped so the agent doesn't
        // resurrect them.
        let timelineClips = videoRecordsOnTimeline
        guard !timelineClips.isEmpty else {
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encodeError("No clip on the timeline to analyze. Ask the user to drag a clip onto the timeline first (imports auto-append, but they may have removed it)."),
                userSummary: "⚠️ Nothing on the timeline to cut.",
                checkpointID: nil
            )
        }
        if let target = request.clipID,
           !timelineClips.contains(where: { $0.id == target && $0.status == .ready }) {
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encodeError("clip_id \(target.uuidString) is not a ready clip on the timeline. Omit clip_id to run on every clip currently placed on the timeline."),
                userSummary: "⚠️ Requested clip wasn't on the timeline.",
                checkpointID: nil
            )
        }

        let unanalyzedBefore = timelineClips.filter {
            $0.status == .ready && ($0.copilot == nil || $0.copilot?.isTranscribeOnly == true)
        }.count
        let segmentsBefore = timelineSegments.count

        // Snapshot BEFORE the pipeline runs so restore_checkpoint can
        // rewind past the first cut, mirroring how every other mutating
        // agent tool captures a pre-state revision.
        pushRevision(
            label: "AI first cut",
            trigger: .aiAction(messageID: userMessageID)
        )
        let checkpointID = revisions.last?.id

        if let target = request.clipID {
            await analyzeRecord(id: target)
        } else {
            await analyzeAllRecords()
        }

        let analyzedClipsAfter = max(0, unanalyzedBefore - timelineClips.filter { clip in
            // Re-resolve from `records` because `analyzeAllRecords`
            // mutates copilot snapshots in place and our local
            // `timelineClips` array carries pre-analysis copies.
            guard let current = records.first(where: { $0.id == clip.id }) else { return false }
            return current.status == .ready && (current.copilot == nil || current.copilot?.isTranscribeOnly == true)
        }.count)
        // analyzeRecord on a single clip targets exactly one clip; the
        // delta count above can come out 0/1 depending on cache state, so
        // just clamp to ≥1 when we ran the single-clip path successfully.
        let analyzedClips = request.clipID != nil ? max(analyzedClipsAfter, 1) : analyzedClipsAfter
        let segmentsAfter = timelineSegments.count

        if segmentsAfter == 0 {
            // Roll back the speculative revision we pushed so we don't
            // leave an empty checkpoint cluttering the undo stack.
            if let cpID = checkpointID,
               let idx = revisions.firstIndex(where: { $0.id == cpID }) {
                revisions.remove(at: idx)
                currentRevisionIndex = revisions.count - 1
            }
            return AgentToolOutcome(
                resultJSON: AgentToolJSON.encodeError("First cut produced no segments. The transcription may have been empty or the LLM cleanup pass failed."),
                userSummary: "⚠️ First cut finished but produced no segments.",
                checkpointID: nil
            )
        }

        let note: String?
        if analyzedClips == 0 && segmentsAfter == segmentsBefore {
            note = "All clips were already analyzed — rebuilt the timeline from cached cuts."
        } else if analyzedClips == 0 {
            note = "Used cached analysis snapshots; no new transcription was needed."
        } else {
            note = nil
        }

        let payload = RunFirstCutToolResult(
            ok: true,
            segments: segmentsAfter,
            totalDurationSeconds: composedIndex.totalDuration,
            analyzedClips: analyzedClips,
            totalClips: timelineClips.count,
            note: note
        )
        let summary: String
        if analyzedClips == 0 {
            summary = "✂️ Rebuilt the first cut from cached analysis — \(segmentsAfter) segment\(segmentsAfter == 1 ? "" : "s") (\(String(format: "%.1f", composedIndex.totalDuration))s)."
        } else {
            summary = "✂️ AI first cut ready — \(segmentsAfter) segment\(segmentsAfter == 1 ? "" : "s") across \(analyzedClips) clip\(analyzedClips == 1 ? "" : "s") (\(String(format: "%.1f", composedIndex.totalDuration))s)."
        }
        return AgentToolOutcome(
            resultJSON: AgentToolJSON.encode(payload),
            userSummary: summary,
            checkpointID: checkpointID
        )
    }

    /// Load chat history from disk.
    func loadChatHistory() async {
        guard let projectRoot else { return }
        let store = ChatStore(projectRoot: projectRoot)
        self.chatStore = store
        do {
            try await store.load()
            self.chatMessages = await store.all()
            // Defensive: any `.working` assistant bubble that
            // survived a project close is by definition stale —
            // whatever the spinner was tracking finished (or got
            // interrupted) before we relaunched, but the bubble
            // never had a chance to finalize because the agent
            // loop's resolution path doesn't run on shutdown.
            // Without this, reopening a project mid-flight (or
            // after a clean exit during analysis) shows a phantom
            // spinner next to a piece of work that's actually
            // long over. Demote so the user sees the resolved
            // state, and persist back so the next reopen agrees.
            resolveStaleWorkingLines(persist: true)
        } catch {
            print("⚠️ Failed to load chat history: \(error)")
        }
    }

    // MARK: - Chat Attachments

    /// Attach a timeline segment to the chat composer. No-op if the
    /// segment doesn't exist or is already attached (idempotent so
    /// repeated drops don't create duplicates).
    func attachSegment(id segmentID: UUID) {
        guard chatAttachments.allSatisfy({ $0.segmentID != segmentID }) else { return }
        guard let segment = timelineSegments.first(where: { $0.id == segmentID }) else { return }
        // Pull composed range from the freshly rebuilt index so the
        // chip labels and ScopeGuard use the same numbers the AI sees.
        let index = ComposedTimelineIndex.build(from: timelineSegments)
        guard let entry = index.entries.first(where: { $0.segmentID == segmentID }) else { return }
        let attachment = ChatAttachment(
            segmentID: segmentID,
            composedStart: entry.composedStart,
            composedEnd: entry.composedEnd,
            sourceVideoID: segment.sourceVideoID,
            sourceStartSeconds: segment.range.startSeconds
        )
        chatAttachments.append(attachment)
    }

    /// Remove an attachment by its own id (not segment id).
    func removeChatAttachment(id attachmentID: UUID) {
        chatAttachments.removeAll { $0.id == attachmentID }
    }

    /// Clear all attachments.
    func clearChatAttachments() {
        chatAttachments.removeAll()
    }

    /// Attachments whose referenced segments still exist on the current
    /// timeline. The UI renders invalid ones as disabled chips but the
    /// AI pipeline (`chatAttachmentScope`) only sees the valid ones.
    var validChatAttachments: [ChatAttachment] {
        let liveIDs = Set(timelineSegments.map(\.id))
        return chatAttachments.filter { liveIDs.contains($0.segmentID) }
    }

    /// Virtual-timeline scope built from the currently valid attachments.
    /// Empty when no attachments are active — AI pipeline branches on
    /// `scope.isEmpty` to decide between global and scoped behaviour.
    var chatAttachmentScope: ChatAttachmentScope {
        ChatAttachmentScope(attachments: validChatAttachments)
    }

    // MARK: - Agent Proposal Gate

    /// Commit an Agent-generated batch against the current timeline.
    /// Called in two situations:
    ///  1. Auto-apply mode, directly from the tool-call handler.
    ///  2. Manual mode, when the user clicks Apply on a proposal card.
    /// Returns an `AgentToolOutcome` that the tool-call site can echo
    /// back to the LLM (auto path). The manual path discards it.
    @discardableResult
    private func commitAgentBatch(
        batch: AIActionBatch,
        dryRun: AIActionExecutor.Result,
        userMessageID: UUID
    ) -> AgentToolOutcome {
        pushRevision(
            label: "AI: \(batch.explanation)",
            trigger: .aiAction(messageID: userMessageID)
        )

        timelineSegments = dryRun.segments
        if let newStyle = dryRun.subtitleStyle { subtitleStyle = newStyle }
        if let newVisible = dryRun.showSubtitles { showSubtitles = newVisible }
        reconcileSegmentSelection()
        rebuildComposedSubtitles()
        rebuildComposition()

        let summary = batch.userFacingSummary
        // Surface executor warnings in the chat bubble *and* in the
        // tool-call JSON fed back to the LLM. Silent skips (e.g.
        // bilingual enabled without a secondary locale) otherwise look
        // like success to both the user and the model.
        let warningLines = dryRun.warnings.map { "⚠️ \($0)" }.joined(separator: "\n")
        let bubble = """
        ✅ \(batch.explanation)
        \(summary.isEmpty ? "" : "\(summary)\n")\(dryRun.appliedCount) action(s) applied\(dryRun.skippedCount > 0 ? ", \(dryRun.skippedCount) skipped" : "")\(warningLines.isEmpty ? "" : "\n\(warningLines)")
        """

        return AgentToolOutcome(
            resultJSON: AgentToolJSON.encode(EditTimelineToolResult(
                applied: dryRun.appliedCount,
                skipped: dryRun.skippedCount,
                explanation: batch.explanation,
                warnings: dryRun.warnings
            )),
            userSummary: bubble,
            checkpointID: revisions.last?.id
        )
    }

    /// User clicked Apply on a pending proposal. Re-runs the batch
    /// against the *current* timeline (not the snapshot at proposal
    /// time) so concurrent user edits are respected, then commits.
    /// Appends a small confirmation bubble; marks the proposal
    /// `.applied` so its chat card collapses into "Applied" state.
    func applyProposal(id: UUID) {
        guard let idx = pendingProposals.firstIndex(where: { $0.id == id }) else { return }
        let proposal = pendingProposals[idx]

        // Re-validate before apply. The original validation passed at
        // proposal time, but state may have shifted between the
        // proposal landing and the user clicking Apply — most notably,
        // an `insertSourceClip` action's source media record may have
        // been removed from the project. Without this re-check we'd
        // silently commit a segment whose source is gone, and only
        // discover it at render time as missing-media black-frame.
        //
        // The validator's `knownSourceVideoIDs` check is permissive
        // when the set is empty (it serves callers who don't enumerate
        // sources). At Apply time we definitively know the project's
        // records — including the empty case — so we run an explicit
        // pre-check first that surfaces missing sources even when no
        // records are loaded.
        let knownSourceIDs = Set(records.map(\.id))
        var missingSources: [UUID] = []
        for action in proposal.batch.actions {
            if case .insertSourceClip(let sourceVideoID, _, _, _, _, _) = action,
               !knownSourceIDs.contains(sourceVideoID) {
                missingSources.append(sourceVideoID)
            }
        }
        let revalidation = AIActionValidator.validate(
            batch: proposal.batch,
            segments: timelineSegments,
            knownSourceVideoIDs: knownSourceIDs
        )
        if !missingSources.isEmpty || revalidation.hasErrors {
            pendingProposals[idx].decision = .stale
            var bullets = revalidation.errors.prefix(3).map { "• \($0.message)" }
            for missing in missingSources.prefix(max(0, 3 - bullets.count)) {
                bullets.append("• Source video \(missing.uuidString) is no longer in the project.")
            }
            let body = bullets.joined(separator: "\n")
            let msg = EditorChatMessage(
                role: .system,
                content: "Can't apply “\(proposal.batch.explanation)” — project state changed since the proposal was made:\n\(body)",
                iconSystemName: "exclamationmark.triangle.fill",
                iconTone: .warning
            )
            chatMessages.append(msg)
            Task { try? await chatStore?.append(msg) }
            return
        }

        let dryRun = AIActionExecutor.apply(
            batch: proposal.batch,
            to: timelineSegments,
            baseSubtitleStyle: subtitleStyle,
            transcriptLookup: { ranges, sourceID in
                self.subtitleEntries(for: ranges, sourceVideoID: sourceID)
            }
        )

        if dryRun.appliedCount == 0 {
            pendingProposals[idx].decision = .stale
            let msg = EditorChatMessage(
                role: .system,
                content: "Can't apply “\(proposal.batch.explanation)” — the segments it referenced no longer match the timeline.",
                iconSystemName: "exclamationmark.triangle.fill",
                iconTone: .warning
            )
            chatMessages.append(msg)
            Task { try? await chatStore?.append(msg) }
            return
        }

        _ = commitAgentBatch(
            batch: proposal.batch,
            dryRun: dryRun,
            userMessageID: UUID() // no triggering user message at this point
        )
        pendingProposals[idx].decision = .applied

        let confirm = EditorChatMessage(
            role: .system,
            content: "Applied: \(proposal.title)",
            checkpointID: revisions.last?.id,
            iconSystemName: "checkmark.seal.fill",
            iconTone: .success
        )
        chatMessages.append(confirm)
        Task { try? await chatStore?.append(confirm) }
    }

    /// User clicked Reject — discards the proposal without touching
    /// the timeline.
    func rejectProposal(id: UUID) {
        guard let idx = pendingProposals.firstIndex(where: { $0.id == id }) else { return }
        let title = pendingProposals[idx].title
        pendingProposals[idx].decision = .rejected

        let msg = EditorChatMessage(
            role: .system,
            content: "↩︎ Rejected: \(title)"
        )
        chatMessages.append(msg)
        Task { try? await chatStore?.append(msg) }
    }

    /// Apply every pending proposal in order. Useful for users who
    /// batch-review several suggestions at once. Stops at the first
    /// stale proposal to avoid surprising partial application.
    func applyAllPendingProposals() {
        let ids = pendingProposals
            .filter { $0.decision == .pending }
            .map(\.id)
        for id in ids {
            let before = pendingProposals.count(where: { $0.decision == .applied })
            applyProposal(id: id)
            let after = pendingProposals.count(where: { $0.decision == .applied })
            if after == before { break }
        }
    }

    /// Toggle between Manual (require user approval) and Auto-apply.
    func setAgentMode(_ mode: AgentMode) {
        agentMode = mode
    }

    /// Look up a proposal by id for the chat card UI.
    func proposal(id: UUID) -> ProposedBatch? {
        pendingProposals.first { $0.id == id }
    }

    /// Aggregate segment IDs that any pending proposal would delete.
    /// Used by TimelineDock to paint diff hints.
    var pendingDeletionIDs: Set<UUID> {
        var out: Set<UUID> = []
        for p in pendingProposals where p.decision == .pending {
            out.formUnion(p.deletedSegmentIDs)
        }
        return out
    }

    var pendingSpeedChangeIDs: Set<UUID> {
        var out: Set<UUID> = []
        for p in pendingProposals where p.decision == .pending {
            out.formUnion(p.speedChangedSegmentIDs)
        }
        return out
    }

    var pendingVolumeChangeIDs: Set<UUID> {
        var out: Set<UUID> = []
        for p in pendingProposals where p.decision == .pending {
            out.formUnion(p.volumeChangedSegmentIDs)
        }
        return out
    }

    // MARK: - Export

    /// Whether the selected clip has segments ready for export.
    var canExport: Bool {
        guard !isExporting, !isAnalyzing else { return false }
        return !timelineSegments.isEmpty
    }

    /// Export the selected clip using the current timeline segments.
    /// The work runs on a tracked Task so the user can cancel mid-encode via
    /// `cancelExport()`. On failure or cancellation the partial output file
    /// is removed so the user doesn't end up with a half-written .mp4.
    func exportEditedVideo(
        to destinationURL: URL,
        format: ExportFormat = .mov,
        resolution: ExportResolution = .original,
        subtitleOption: SubtitleExportOption = .none
    ) async {
        guard !timelineSegments.isEmpty else {
            bannerMessage = L("No segments to export. Run AI analysis or add segments manually.")
            return
        }

        // Verify all source videos exist
        let sourceIDs = Set(timelineSegments.map(\.sourceVideoID))
        for sourceID in sourceIDs {
            guard let record = records.first(where: { $0.id == sourceID }) else {
                bannerMessage = L("Source clip missing from project.")
                return
            }
            let sourceURL = URL(fileURLWithPath: record.sourcePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                bannerMessage = L("Source file not found: %@. Please relink.", sourceURL.lastPathComponent)
                return
            }
        }

        // Refuse to overwrite a destination directory; remove a stale file
        // up-front so AVAssetExportSession doesn't hit a "file exists"
        // failure halfway through.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                bannerMessage = L("Export destination must be a file, not a directory.")
                return
            }
            try? FileManager.default.removeItem(at: destinationURL)
        }

        isExporting = true
        isCancellingExport = false
        exportProgress = nil
        bannerMessage = nil

        let segments = timelineSegments
        let allRecords = records
        let cues = composedSubtitles
        let chaptersForExport = currentChapters ?? []
        let chapterBarStyleForExport = currentChapterBarStyle
        let auxAudio = project.audioTracks
        let overlayVideo = project.overlayTracks
        let voiceEnhancerSettings = project.voiceEnhancer

        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let exporter = AIVideoExporter()
                try await exporter.exportWithComposition(
                    sourceLookup: { sourceID in
                        let rec = allRecords.first { $0.id == sourceID }
                        return URL(fileURLWithPath: rec?.sourcePath ?? "/dev/null")
                    },
                    sourceKind: { sourceID in
                        allRecords.first { $0.id == sourceID }?.kind ?? .video
                    },
                    segments: segments,
                    auxAudioTracks: auxAudio,
                    overlayVideoTracks: overlayVideo,
                    format: format,
                    resolution: resolution,
                    subtitleOption: subtitleOption,
                    composedSubtitles: cues,
                    chapters: chaptersForExport,
                    chapterBarStyle: chapterBarStyleForExport,
                    voiceEnhancer: voiceEnhancerSettings,
                    primaryHidden: project.tracks.first(where: { $0.kind == .video })?.isMuted ?? false,
                    destinationURL: destinationURL,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            // Ignore late callbacks that fire after the
                            // export has finished / been cancelled —
                            // otherwise we flicker the progress card back
                            // on after completion.
                            guard let self, self.isExporting else { return }
                            self.exportProgress = progress
                        }
                    }
                )

                self.isExporting = false
                self.isCancellingExport = false
                self.exportProgress = nil
                self.exportTask = nil
                self.bannerMessage = L("Export complete! Saved to %@", destinationURL.lastPathComponent)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destinationURL)
                self.isExporting = false
                self.isCancellingExport = false
                self.exportProgress = nil
                self.exportTask = nil
                self.bannerMessage = L("Export cancelled.")
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                self.isExporting = false
                self.isCancellingExport = false
                self.exportProgress = nil
                self.exportTask = nil
                self.bannerMessage = L("Export failed: %@", error.localizedDescription)
            }
        }
    }

    /// Cancel any in-flight export. The exporter is wired to forward Swift
    /// Concurrency cancellation into AVAssetExportSession.cancelExport(),
    /// which surfaces as `.cancelled` and triggers cleanup.
    func cancelExport() {
        guard isExporting, let task = exportTask else { return }
        isCancellingExport = true
        task.cancel()
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
