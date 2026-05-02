import Foundation
import AVFoundation
import Combine
import CuttiKit

/// Read-only snapshot of a project's persisted editor state. Loaded
/// when the user opens a project in the iOS app. Mirrors the subset of
/// `MediaCoreViewModel`'s working state the iOS preview actually needs
/// (tracks + subtitle style); full editing will come later.
@MainActor
final class ProjectDocument: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var manifest: MediaManifest = MediaManifest()
    @Published private(set) var subtitleStyle: SubtitleStyle = .default
    @Published private(set) var showSubtitles: Bool = true
    @Published private(set) var loadError: String?

    /// Set to true once `load()` has finished restoring state. Guards
    /// against didSet-triggered saves during the load phase itself
    /// (otherwise setting aspectRatio from the persisted value would
    /// immediately re-save, racing partially-applied state).
    private var hasLoaded: Bool = false

    /// Canvas aspect ratio for preview + export framing. Session-only
    /// (not persisted yet) — CapCut default is 9:16 portrait.
    @Published var aspectRatio: AspectRatio = .portrait9x16 {
        didSet { if aspectRatio != oldValue { saveIOSSession() } }
    }

    enum AspectRatio: String, CaseIterable, Identifiable {
        case portrait9x16   // 9:16
        case landscape16x9  // 16:9
        case square         // 1:1
        case landscape4x3   // 4:3
        case portrait3x4    // 3:4
        case widescreen21x9 // 21:9

        var id: String { rawValue }
        var ratio: CGFloat {
            switch self {
            case .portrait9x16:   return 9.0 / 16.0
            case .landscape16x9:  return 16.0 / 9.0
            case .square:         return 1
            case .landscape4x3:   return 4.0 / 3.0
            case .portrait3x4:    return 3.0 / 4.0
            case .widescreen21x9: return 21.0 / 9.0
            }
        }
        var label: String {
            switch self {
            case .portrait9x16:   return "9:16"
            case .landscape16x9:  return "16:9"
            case .square:         return "1:1"
            case .landscape4x3:   return "4:3"
            case .portrait3x4:    return "3:4"
            case .widescreen21x9: return "21:9"
            }
        }
    }

    // Playback state, shared between PreviewPane (owner of AVPlayer) and
    // TimelineCanvas (draws playhead + seeks on tap).
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying: Bool = false
    @Published var selectedSegmentID: UUID? = nil
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    /// Composed-timeline seconds picked as the project cover frame.
    /// Shown as the thumbnail on the "设置封面" timeline tile. Lives in
    /// memory only for this session — persistence is a follow-up once
    /// we have an ios-scoped session schema.
    @Published var coverTimeSeconds: Double? = nil {
        didSet { if coverTimeSeconds != oldValue { saveIOSSession() } }
    }

    /// Per-segment visual-effect preset (iOS-only — lives in session
    /// memory, not on the shared `SegmentEffects` so it doesn't
    /// require changing the cross-platform manifest schema).
    @Published var visualEffects: [UUID: VisualEffectPreset] = [:] {
        didSet { if visualEffects != oldValue { saveIOSSession() } }
    }

    /// Background style drawn behind the preview video within the
    /// aspect-ratio letterbox. iOS-only and session-memory for now.
    @Published var background: BackgroundStyle = .color(RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)) {
        didSet { if background != oldValue { saveIOSSession() } }
    }

    /// In-canvas text overlays. Each overlay renders between its own
    /// composed-time window and participates in both preview and
    /// export via `IOSCompositionBuilder.buildVideoComposition`.
    @Published var textOverlays: [IOSSessionState.TextOverlay] = [] {
        didSet { if textOverlays != oldValue { saveIOSSession() } }
    }

    /// Per-segment "exit transition" duration in seconds. Segment IDs
    /// absent from this dict have no transition. The builder reads
    /// this to derive paired fade-out (this segment) / fade-in (next
    /// segment) windows of equal length.
    @Published var transitions: [UUID: Double] = [:] {
        didSet { if transitions != oldValue { saveIOSSession() } }
    }

    /// Authored chapters. Each chapter occupies a contiguous span of
    /// composed-timeline seconds; the editor keeps them sorted and
    /// non-overlapping. Used by ChaptersSheet (editing) and
    /// ChapterBarOverlay (live preview strip). Future export turn
    /// will burn these in via ChapterBarBurnInRenderer.
    @Published var chapters: [VideoChapter] = [] {
        didSet { if chapters != oldValue { saveIOSSession() } }
    }

    /// BCP-47 locale used to display the secondary translation in the
    /// transcript editor (and, future, bilingual burn-in). `nil` means
    /// "monolingual mode" — only the source `text` is shown.
    @Published var transcriptDisplayLocale: String? = nil {
        didSet { if transcriptDisplayLocale != oldValue { saveIOSSession() } }
    }

    enum BackgroundStyle: Equatable {
        case color(RGBAColor)
        case blur
    }

    enum VisualEffectPreset: String, CaseIterable, Codable, Sendable {
        case none, pixellate, bloom, vignette, sepia, noir, chrome, comic, thermal

        var label: String {
            switch self {
            case .none:      return "无"
            case .pixellate: return "马赛克"
            case .bloom:     return "柔光"
            case .vignette:  return "暗角"
            case .sepia:     return "复古"
            case .noir:      return "黑白"
            case .chrome:    return "鲜艳"
            case .comic:     return "漫画"
            case .thermal:   return "热成像"
            }
        }
        var icon: String {
            switch self {
            case .none:      return "circle.slash"
            case .pixellate: return "square.grid.3x3.fill"
            case .bloom:     return "sun.max.fill"
            case .vignette:  return "circle.lefthalf.filled.righthalf.striped.horizontal"
            case .sepia:     return "photo.artframe"
            case .noir:      return "circle.lefthalf.filled"
            case .chrome:    return "paintpalette.fill"
            case .comic:     return "scribble.variable"
            case .thermal:   return "flame.fill"
            }
        }
    }

    // Lightweight in-memory undo: snapshots of `tracks` taken before
    // each mutating op. 50-level cap matches the macOS editor.
    private var undoStack: [[Track]] = []
    private var redoStack: [[Track]] = []
    private let undoCap = 50
    // While `interactiveEditDepth > 0`, only the FIRST pushUndoSnapshot
    // call records — subsequent calls in the same interaction coalesce
    // into that single snapshot. Prevents slider/drag gestures from
    // spamming 60+ undo frames per second.
    private var interactiveEditDepth: Int = 0
    private var interactiveEditCoalesced: Bool = false
    let player: AVPlayer = {
        let p = AVPlayer()
        p.actionAtItemEnd = .pause
        return p
    }()
    private var timeObserverToken: Any?

    let project: ProjectInfo
    let store: ProjectStore

    init(project: ProjectInfo, rootDirectory: URL) {
        self.project = project
        self.store = ProjectStore(projectRoot: rootDirectory)
        installTimeObserver()
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = CMTimeGetSeconds(time)
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            // If we're parked at the end, rewind first so play resumes from 0.
            if let item = player.currentItem,
               CMTimeGetSeconds(item.currentTime()) >= CMTimeGetSeconds(item.duration) - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying = player.timeControlStatus == .playing
    }

    func seek(toSeconds seconds: Double) {
        let clamped = max(0, min(seconds, primaryDurationSeconds))
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    /// Pause playback (if running) and nudge the playhead by
    /// `delta` seconds. Used by the frame-step buttons in the
    /// transport bar to land on a specific frame. Uses the
    /// tolerance-zero seek so the preview jumps to the exact
    /// requested frame instead of the nearest keyframe.
    func pauseAndStep(bySeconds delta: Double) {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        }
        seek(toSeconds: currentTime + delta)
    }

    func load() {
        do {
            self.manifest = try store.loadManifest()
        } catch {
            // A freshly-created project has no manifest yet; treat as empty.
            self.manifest = MediaManifest()
        }

        let session = store.loadSessionState()
        self.subtitleStyle = session.subtitleStyle
        self.showSubtitles = session.showSubtitles
        if let persisted = session.currentTracks, !persisted.isEmpty {
            self.tracks = persisted.map { $0.toTrack() }
        } else {
            // No persisted tracks yet → show just the empty primary video lane.
            self.tracks = [Project.makePrimaryVideoTrack()]
        }

        // Restore iOS-only UI state (aspect ratio, cover frame,
        // per-segment visual presets, background) from our side-car
        // file. Done last so didSet guards fire after hasLoaded flips.
        let ios = IOSSessionStore.load(projectRoot: store.projectRoot)
        if let ratio = AspectRatio(rawValue: ios.aspectRatio) {
            self.aspectRatio = ratio
        }
        self.coverTimeSeconds = ios.coverTimeSeconds
        self.visualEffects = ios.visualEffects.reduce(into: [UUID: VisualEffectPreset]()) { out, pair in
            if let id = UUID(uuidString: pair.key),
               let preset = VisualEffectPreset(rawValue: pair.value) {
                out[id] = preset
            }
        }
        switch ios.background {
        case .color(let r, let g, let b, let a):
            self.background = .color(RGBAColor(red: r, green: g, blue: b, alpha: a))
        case .blur:
            self.background = .blur
        }
        self.textOverlays = ios.textOverlays ?? []
        self.transitions = (ios.transitions ?? [:]).reduce(into: [UUID: Double]()) { out, pair in
            if let id = UUID(uuidString: pair.key), pair.value > 0 {
                out[id] = pair.value
            }
        }
        self.chapters = (ios.chapters ?? []).sorted { $0.startSeconds < $1.startSeconds }
        self.transcriptDisplayLocale = ios.transcriptDisplayLocale

        self.hasLoaded = true
    }

    private func saveIOSSession() {
        guard hasLoaded else { return }
        let bg: IOSSessionState.Background = {
            switch background {
            case .color(let c):
                return .color(r: c.red, g: c.green, b: c.blue, a: c.alpha)
            case .blur:
                return .blur
            }
        }()
        let state = IOSSessionState(
            aspectRatio: aspectRatio.rawValue,
            coverTimeSeconds: coverTimeSeconds,
            visualEffects: visualEffects.reduce(into: [String: String]()) { out, pair in
                out[pair.key.uuidString] = pair.value.rawValue
            },
            background: bg,
            textOverlays: textOverlays,
            transitions: transitions.reduce(into: [String: Double]()) { out, pair in
                out[pair.key.uuidString] = pair.value
            },
            chapters: chapters,
            transcriptDisplayLocale: transcriptDisplayLocale
        )
        IOSSessionStore.save(state, projectRoot: store.projectRoot)
    }

    /// Total composed duration across the primary video track (seconds).
    var primaryDurationSeconds: Double {
        tracks.first(where: { $0.kind == .video })?
            .segments.reduce(0.0) { $0 + $1.durationSeconds } ?? 0
    }

    /// Import a video file at `sourceURL`, append it to the primary
    /// video track as a full-length segment, and persist both the
    /// manifest and the session state so reopening restores the clip.
    func importVideo(at sourceURL: URL, initialRange: TimeRange? = nil) async throws {
        let importer = IOSMediaImporter(store: store)
        let record = try await importer.importVideo(from: sourceURL)
        let duration = record.analysis?.durationSeconds ?? 0
        // Clamp any caller-supplied trim range to the actual media
        // duration; if nil, default to the full clip.
        let range: TimeRange = {
            if let r = initialRange {
                let clampedStart = max(0, min(r.startSeconds, duration))
                let clampedEnd = max(clampedStart + 0.1, min(r.endSeconds, duration))
                return TimeRange(startSeconds: clampedStart, endSeconds: clampedEnd)
            }
            return TimeRange(startSeconds: 0, endSeconds: duration)
        }()

        var nextTracks = tracks
        if nextTracks.isEmpty {
            nextTracks = [Project.makePrimaryVideoTrack()]
        }
        if let primaryIdx = nextTracks.firstIndex(where: { $0.kind == .video }) {
            let segment = TimelineSegment(
                id: UUID(),
                sourceVideoID: record.id,
                range: range,
                text: "",
                subtitles: []
            )
            nextTracks[primaryIdx].segments.append(segment)
        }

        self.manifest = (try? store.loadManifest()) ?? manifest
        pushUndoSnapshot()
        self.tracks = nextTracks

        let session = EditorSessionState(
            subtitleStyle: subtitleStyle,
            showSubtitles: showSubtitles,
            lastAutosaveAt: Date(),
            currentTracks: nextTracks.map(EditorRevision.PersistableTrack.init(from:))
        )
        try store.saveSessionState(session)
    }

    // MARK: - Editing

    /// Read the currently selected segment, or nil if no selection.
    var selectedSegment: TimelineSegment? {
        guard let id = selectedSegmentID else { return nil }
        for t in tracks {
            if let s = t.segments.first(where: { $0.id == id }) { return s }
        }
        return nil
    }

    /// Generic helper: mutate the selected segment in place with a
    /// closure; automatically snapshots for undo and persists.
    private func mutateSelected(_ change: (inout TimelineSegment) -> Void) {
        guard let id = selectedSegmentID else { return }
        var next = tracks
        for i in next.indices {
            if let idx = next[i].segments.firstIndex(where: { $0.id == id }) {
                var seg = next[i].segments[idx]
                change(&seg)
                next[i].segments[idx] = seg
                pushUndoSnapshot()
                tracks = next
                persistSession()
                return
            }
        }
    }

    /// Largest trimmed range a segment can expand into, i.e. its source
    /// media's full duration (0 ... media.duration). Used as the clamp
    /// when dragging trim handles.
    func sourceDuration(for segment: TimelineSegment) -> Double {
        manifest.media
            .first(where: { $0.id == segment.sourceVideoID })?
            .analysis?.durationSeconds ?? segment.range.endSeconds
    }

    /// Map a composed-timeline second to the primary segment covering
    /// it, returning the source media ID and the corresponding source
    /// seconds (after applying segment trim + speed). Returns nil when
    /// the timeline is empty or the time is out of range.
    func resolveComposedTime(_ seconds: Double)
        -> (sourceVideoID: UUID, sourceSeconds: Double)?
    {
        guard let primary = tracks.first(where: { $0.kind == .video }) else { return nil }
        var cursor: Double = 0
        for seg in primary.segments {
            let start = seg.placementOffset ?? cursor
            let dur = seg.durationSeconds
            let end = start + dur
            if seconds >= start && seconds <= end {
                let rel = (seconds - start) * seg.normalizedSpeedRate
                return (seg.sourceVideoID, seg.range.startSeconds + rel)
            }
            if seg.placementOffset == nil { cursor = end }
        }
        // Clamp to last segment tail so the cover tile still shows
        // something when coverTimeSeconds is at/after the timeline end.
        if let last = primary.segments.last {
            return (last.sourceVideoID, last.range.endSeconds)
        }
        return nil
    }

    private func pushUndoSnapshot() {
        if interactiveEditDepth > 0 {
            if interactiveEditCoalesced { return }
            interactiveEditCoalesced = true
        }
        undoStack.append(tracks)
        if undoStack.count > undoCap {
            undoStack.removeFirst(undoStack.count - undoCap)
        }
        redoStack.removeAll()
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    /// Opens a coalesced-edit window. Use for Slider / drag gestures so
    /// the whole interaction pushes ONE undo snapshot instead of dozens
    /// of intermediate ticks. Pair each begin with an end (nesting is
    /// supported; only the outermost end closes the window).
    func beginInteractiveEdit() {
        interactiveEditDepth += 1
    }

    func endInteractiveEdit() {
        guard interactiveEditDepth > 0 else { return }
        interactiveEditDepth -= 1
        if interactiveEditDepth == 0 {
            interactiveEditCoalesced = false
        }
    }

    /// Convenience for `Slider(onEditingChanged:)` — pass this directly:
    /// `Slider(..., onEditingChanged: { document.interactiveEdit($0) })`.
    /// `true` opens the coalesced-edit window, `false` closes it.
    func interactiveEdit(_ isEditing: Bool) {
        if isEditing { beginInteractiveEdit() } else { endInteractiveEdit() }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(tracks)
        if redoStack.count > undoCap {
            redoStack.removeFirst(redoStack.count - undoCap)
        }
        tracks = prev
        selectedSegmentID = nil
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        persistSession()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(tracks)
        tracks = next
        selectedSegmentID = nil
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        persistSession()
    }

    func selectSegment(_ id: UUID?) {
        selectedSegmentID = id
    }

    /// Delete the currently-selected segment (if any) from whichever
    /// track owns it. Persists session.json.
    func deleteSelectedSegment() {
        guard let id = selectedSegmentID else { return }
        var changed = false
        var next = tracks
        for i in next.indices {
            if let idx = next[i].segments.firstIndex(where: { $0.id == id }) {
                next[i].segments.remove(at: idx)
                changed = true
                break
            }
        }
        if changed {
            pushUndoSnapshot()
            tracks = next
            selectedSegmentID = nil
            persistSession()
        }
    }

    /// Update the trimmed range of the selected segment. `newStart` and
    /// `newEnd` are in source-media seconds and will be clamped to
    /// [0, sourceDuration] with a 0.1s minimum duration.
    func trimSelectedSegment(newStart: Double, newEnd: Double) {
        guard let id = selectedSegmentID else { return }
        var next = tracks
        for i in next.indices {
            if let idx = next[i].segments.firstIndex(where: { $0.id == id }) {
                var seg = next[i].segments[idx]
                let maxEnd = sourceDuration(for: seg)
                let clampedStart = max(0, min(newStart, maxEnd - 0.1))
                let clampedEnd = max(clampedStart + 0.1, min(newEnd, maxEnd))
                seg.range = TimeRange(startSeconds: clampedStart, endSeconds: clampedEnd)
                next[i].segments[idx] = seg
                pushUndoSnapshot()
                tracks = next
                persistSession()
                return
            }
        }
    }

    /// Split the primary-track segment that currently contains the
    /// playhead into two segments at the playhead's source-media
    /// offset. No-op if playhead is outside any segment.
    func splitAtPlayhead() {
        guard let primaryIdx = tracks.firstIndex(where: { $0.kind == .video }) else { return }
        let primary = tracks[primaryIdx].segments

        // Find the segment covering currentTime in the composed timeline.
        var cursor: Double = 0
        var hit: (Int, Double)? = nil  // (segmentIndex, startInTimeline)
        for (i, seg) in primary.enumerated() {
            let start = seg.placementOffset ?? cursor
            let end = start + seg.durationSeconds
            if currentTime > start + 0.05, currentTime < end - 0.05 {
                hit = (i, start)
                break
            }
            if seg.placementOffset == nil { cursor = end }
        }
        if let (segIdx, segStart) = hit {
            splitPrimary(trackIdx: primaryIdx, segIdx: segIdx, segStart: segStart)
            return
        }

        // No primary-track hit → try every .audio track. Voiceovers
        // and extracted-music clips live there and always carry an
        // explicit placementOffset, so the search is simpler.
        for (ti, t) in tracks.enumerated() where t.kind == .audio {
            for (si, seg) in t.segments.enumerated() {
                let start = seg.placementOffset ?? 0
                let end = start + seg.durationSeconds
                if currentTime > start + 0.05, currentTime < end - 0.05 {
                    splitAudio(trackIdx: ti, segIdx: si, segStart: start)
                    return
                }
            }
        }
    }

    private func splitPrimary(trackIdx: Int, segIdx: Int, segStart: Double) {
        let seg = tracks[trackIdx].segments[segIdx]
        let splitSourceTime = seg.range.startSeconds + (currentTime - segStart)
        let left = TimelineSegment(
            id: UUID(),
            sourceVideoID: seg.sourceVideoID,
            range: TimeRange(startSeconds: seg.range.startSeconds, endSeconds: splitSourceTime),
            text: seg.text,
            subtitles: []
        )
        let right = TimelineSegment(
            id: UUID(),
            sourceVideoID: seg.sourceVideoID,
            range: TimeRange(startSeconds: splitSourceTime, endSeconds: seg.range.endSeconds),
            text: "",
            subtitles: []
        )

        var next = tracks
        next[trackIdx].segments.replaceSubrange(segIdx...segIdx, with: [left, right])
        pushUndoSnapshot()
        tracks = next
        selectedSegmentID = right.id
        persistSession()
    }

    /// Audio-track split. Each half keeps an explicit placementOffset
    /// so the right half doesn't collapse against its neighbour when
    /// the composition is re-linearised. Volume/fades/speedRate are
    /// copied to both sides; the right half inherits nothing that
    /// would cause a second playback of the same fade envelope.
    private func splitAudio(trackIdx: Int, segIdx: Int, segStart: Double) {
        let seg = tracks[trackIdx].segments[segIdx]
        let splitSourceTime = seg.range.startSeconds + (currentTime - segStart)
        let left = TimelineSegment(
            id: UUID(),
            sourceVideoID: seg.sourceVideoID,
            range: TimeRange(startSeconds: seg.range.startSeconds, endSeconds: splitSourceTime),
            text: seg.text,
            subtitles: [],
            volumeLevel: seg.volumeLevel,
            isVideoHidden: seg.isVideoHidden,
            speedRate: seg.speedRate,
            effects: seg.effects,
            placementOffset: segStart,
            alternatives: [],
            linkedSegmentID: seg.linkedSegmentID,
            pipLayout: nil,
            freeTransform: nil,
            overlaySpec: nil
        )
        let right = TimelineSegment(
            id: UUID(),
            sourceVideoID: seg.sourceVideoID,
            range: TimeRange(startSeconds: splitSourceTime, endSeconds: seg.range.endSeconds),
            text: "",
            subtitles: [],
            volumeLevel: seg.volumeLevel,
            isVideoHidden: seg.isVideoHidden,
            speedRate: seg.speedRate,
            effects: seg.effects,
            placementOffset: currentTime,
            alternatives: [],
            linkedSegmentID: nil,
            pipLayout: nil,
            freeTransform: nil,
            overlaySpec: nil
        )

        var next = tracks
        next[trackIdx].segments.replaceSubrange(segIdx...segIdx, with: [left, right])
        pushUndoSnapshot()
        tracks = next
        selectedSegmentID = right.id
        persistSession()
    }

    // MARK: - Segment-level actions (剪辑 panel)

    /// Duplicate the selected segment, appended right after it on the
    /// same track. New copy becomes selected.
    func duplicateSelectedSegment() {
        guard let id = selectedSegmentID else { return }
        var next = tracks
        for i in next.indices {
            if let idx = next[i].segments.firstIndex(where: { $0.id == id }) {
                let src = next[i].segments[idx]
                var copy = TimelineSegment(
                    id: UUID(),
                    sourceVideoID: src.sourceVideoID,
                    range: src.range,
                    text: src.text,
                    subtitles: src.subtitles,
                    volumeLevel: src.volumeLevel,
                    isVideoHidden: src.isVideoHidden,
                    speedRate: src.speedRate,
                    effects: src.effects,
                    placementOffset: nil,
                    alternatives: src.alternatives,
                    linkedSegmentID: nil,
                    pipLayout: src.pipLayout,
                    freeTransform: src.freeTransform,
                    overlaySpec: src.overlaySpec
                )
                _ = copy
                next[i].segments.insert(copy, at: idx + 1)
                pushUndoSnapshot()
                tracks = next
                selectedSegmentID = copy.id
                persistSession()
                return
            }
        }
    }

    // MARK: - Clipboard (⌘C / ⌘X / ⌘V)

    /// Copy the currently selected segment onto `appState.segmentClipboard`.
    /// Noop if nothing is selected. Returns true on success.
    @discardableResult
    func copySelectedSegment(to appState: AppState) -> Bool {
        guard let seg = selectedSegment else { return false }
        appState.segmentClipboard = seg
        return true
    }

    /// Copy then delete — standard cut behavior.
    func cutSelectedSegment(to appState: AppState) {
        guard copySelectedSegment(to: appState) else { return }
        deleteSelectedSegment()
    }

    /// Paste the last-copied segment after the current selection (or
    /// at the end of the primary video track if nothing is selected).
    /// Generates a fresh UUID so repeated pastes produce independent
    /// segments. Silently bails if the clipboard's source media isn't
    /// present in this project's manifest (cross-project paste where
    /// the source wasn't copied over).
    func pasteClipboardSegment(from appState: AppState) {
        guard let src = appState.segmentClipboard else { return }
        guard manifest.media.contains(where: { $0.id == src.sourceVideoID }) else {
            return
        }
        var copy = TimelineSegment(
            id: UUID(),
            sourceVideoID: src.sourceVideoID,
            range: src.range,
            text: src.text,
            subtitles: src.subtitles,
            volumeLevel: src.volumeLevel,
            isVideoHidden: src.isVideoHidden,
            speedRate: src.speedRate,
            effects: src.effects,
            placementOffset: nil,
            alternatives: [],
            linkedSegmentID: nil,
            pipLayout: src.pipLayout,
            freeTransform: src.freeTransform,
            overlaySpec: src.overlaySpec
        )
        _ = copy
        var next = tracks
        // Prefer inserting after the currently-selected segment.
        if let selID = selectedSegmentID {
            for i in next.indices {
                if let idx = next[i].segments.firstIndex(where: { $0.id == selID }) {
                    next[i].segments.insert(copy, at: idx + 1)
                    pushUndoSnapshot()
                    tracks = next
                    selectedSegmentID = copy.id
                    persistSession()
                    return
                }
            }
        }
        // Fallback: append to primary video track.
        if let primaryIdx = next.firstIndex(where: { $0.kind == .video }) {
            next[primaryIdx].segments.append(copy)
            pushUndoSnapshot()
            tracks = next
            selectedSegmentID = copy.id
            persistSession()
        }
    }

    /// Set volume level (0.0 – 1.0) of the selected segment.
    func setSelectedSegmentVolume(_ level: Double) {
        mutateSelected { $0.volumeLevel = max(0, min(1, level)) }
    }

    /// Set playback speed (0.25x – 4x) of the selected segment.
    func setSelectedSegmentSpeed(_ rate: Double) {
        let clamped = max(TimelineSegment.minimumSpeedRate,
                          min(TimelineSegment.maximumSpeedRate, rate))
        mutateSelected { $0.speedRate = clamped }
    }

    /// Rotate selected segment by +90° (wraps 0/90/180/270).
    func rotateSelectedSegment90() {
        mutateSelected { $0.effects.rotation = ($0.effects.rotation + 90) % 360 }
    }

    func flipSelectedSegmentHorizontal() {
        mutateSelected { $0.effects.flipHorizontal.toggle() }
    }

    func flipSelectedSegmentVertical() {
        mutateSelected { $0.effects.flipVertical.toggle() }
    }

    /// Toggle per-segment video visibility. Audio still plays.
    func toggleSelectedSegmentVideoHidden() {
        mutateSelected { $0.isVideoHidden.toggle() }
    }

    /// Mute or unmute the entire primary video track (CapCut's
    /// "关闭原声"). Sets volume on every segment of the video track.
    func togglePrimaryTrackMuted() {
        guard let primaryIdx = tracks.firstIndex(where: { $0.kind == .video }) else { return }
        let anyAudible = tracks[primaryIdx].segments.contains { $0.volumeLevel > 0.01 }
        let newLevel: Double = anyAudible ? 0 : 1
        var next = tracks
        for i in next[primaryIdx].segments.indices {
            next[primaryIdx].segments[i].volumeLevel = newLevel
        }
        pushUndoSnapshot()
        tracks = next
        persistSession()
    }

    /// True when every primary-track segment is muted.
    var isPrimaryTrackMuted: Bool {
        guard let primary = tracks.first(where: { $0.kind == .video }) else { return false }
        return !primary.segments.isEmpty && primary.segments.allSatisfy { $0.volumeLevel <= 0.01 }
    }

    // MARK: - Audio detach / reattach

    /// Split the audio portion of the selected V1 clip onto its own
    /// aux-audio lane so the user can trim, fade, and volume it
    /// independently of the video. Links both segments via
    /// `linkedSegmentID` so either side stays aware of the pair, and
    /// mutes the V1 so we don't double-play the track.
    ///
    /// No-op if the current selection is on an audio track, already
    /// has a linked partner, or the V1 segment can't be located.
    func detachSelectedAudio() {
        guard let id = selectedSegmentID,
              let primaryIdx = tracks.firstIndex(where: { $0.kind == .video }),
              let segIdx = tracks[primaryIdx].segments.firstIndex(where: { $0.id == id })
        else { return }
        let v1 = tracks[primaryIdx].segments[segIdx]
        guard v1.linkedSegmentID == nil else { return }

        // Compute V1's composed start so the aux audio segment plays
        // at the exact same moment, even when prior segments have
        // explicit placementOffsets mixed in.
        var cursor: Double = 0
        var composedStart: Double = 0
        for (i, seg) in tracks[primaryIdx].segments.enumerated() {
            let start = seg.placementOffset ?? cursor
            if i == segIdx { composedStart = start; break }
            let end = start + seg.durationSeconds
            if seg.placementOffset == nil { cursor = end }
        }

        let auxID = UUID()
        var aux = TimelineSegment(
            id: auxID,
            sourceVideoID: v1.sourceVideoID,
            range: v1.range,
            text: "",
            subtitles: [],
            volumeLevel: v1.volumeLevel > 0.01 ? v1.volumeLevel : 1.0,
            isVideoHidden: true,
            speedRate: v1.speedRate,
            effects: v1.effects,
            placementOffset: composedStart,
            alternatives: [],
            linkedSegmentID: v1.id,
            pipLayout: nil,
            freeTransform: nil,
            overlaySpec: nil
        )
        _ = aux

        var next = tracks
        next[primaryIdx].segments[segIdx].volumeLevel = 0
        next[primaryIdx].segments[segIdx].linkedSegmentID = auxID

        // Reuse the first existing .audio lane if one exists — the
        // user rarely wants a brand-new lane for every detach.
        if let auxTrackIdx = next.firstIndex(where: { $0.kind == .audio }) {
            next[auxTrackIdx].segments.append(aux)
        } else {
            next.append(Track(kind: .audio, name: "A1", segments: [aux]))
        }
        pushUndoSnapshot()
        tracks = next
        persistSession()
    }

    /// Remove the aux-audio partner of the currently selected segment
    /// (or of the aux itself) and unmute the V1. Works from either
    /// side of the link.
    func reattachSelectedAudio() {
        guard let id = selectedSegmentID else { return }
        // Locate segment + whether it's the V1 or the aux side.
        var v1TrackIdx: Int? = nil
        var v1SegIdx: Int? = nil
        var auxTrackIdx: Int? = nil
        var auxSegIdx: Int? = nil

        for (ti, track) in tracks.enumerated() {
            for (si, seg) in track.segments.enumerated() where seg.id == id {
                if track.kind == .video, let linkID = seg.linkedSegmentID {
                    v1TrackIdx = ti; v1SegIdx = si
                    for (tj, tr) in tracks.enumerated() {
                        if let sj = tr.segments.firstIndex(where: { $0.id == linkID }) {
                            auxTrackIdx = tj; auxSegIdx = sj; break
                        }
                    }
                } else if track.kind == .audio, let linkID = seg.linkedSegmentID {
                    auxTrackIdx = ti; auxSegIdx = si
                    for (tj, tr) in tracks.enumerated() where tr.kind == .video {
                        if let sj = tr.segments.firstIndex(where: { $0.id == linkID }) {
                            v1TrackIdx = tj; v1SegIdx = sj; break
                        }
                    }
                }
            }
        }
        guard let vT = v1TrackIdx, let vS = v1SegIdx,
              let aT = auxTrackIdx, let aS = auxSegIdx else { return }

        var next = tracks
        let auxVol = next[aT].segments[aS].volumeLevel
        next[aT].segments.remove(at: aS)
        next[vT].segments[vS].linkedSegmentID = nil
        // Restore audible V1 by copying the aux's volume back
        // — the user may have tuned it while detached.
        next[vT].segments[vS].volumeLevel = max(auxVol, 0.01)
        // Drop emptied aux tracks so the timeline collapses back to
        // its CapCut-style "+ 添加音频" placeholder.
        if next[aT].kind == .audio, next[aT].segments.isEmpty {
            next.remove(at: aT)
        }
        pushUndoSnapshot()
        tracks = next
        persistSession()
    }

    /// True when the selected segment (on either side) is part of an
    /// aux-audio link. UI uses this to toggle the context-menu label
    /// between "分离音频" and "合并音频".
    var selectedHasLinkedAudio: Bool {
        guard let seg = selectedSegment else { return false }
        return seg.linkedSegmentID != nil
    }

    // MARK: - Color / transform

    /// Adjust color effect on the selected segment. Pass nil to keep
    /// a channel unchanged.
    func setSelectedSegmentColor(brightness: Double? = nil,
                                 contrast: Double? = nil,
                                 saturation: Double? = nil) {
        mutateSelected {
            if let b = brightness { $0.effects.brightness = max(-1, min(1, b)) }
            if let c = contrast { $0.effects.contrast = max(0, min(2, c)) }
            if let s = saturation { $0.effects.saturation = max(0, min(2, s)) }
        }
    }

    /// Reset all visual effects on the selected segment.
    func resetSelectedSegmentEffects() {
        mutateSelected { $0.effects = .default }
    }

    /// Apply a named filter preset (brightness/contrast/saturation) to
    /// the selected segment. `nil` restores defaults.
    func applyFilterPreset(_ preset: FilterPreset) {
        mutateSelected {
            $0.effects.brightness = preset.brightness
            $0.effects.contrast = preset.contrast
            $0.effects.saturation = preset.saturation
        }
    }

    /// Set audio fade durations (seconds) on the selected segment.
    func setSelectedSegmentFade(fadeIn: Double? = nil, fadeOut: Double? = nil) {
        mutateSelected {
            if let f = fadeIn { $0.effects.audioFadeInDuration = max(0, min(f, $0.durationSeconds / 2)) }
            if let f = fadeOut { $0.effects.audioFadeOutDuration = max(0, min(f, $0.durationSeconds / 2)) }
        }
    }

    /// Assign (or clear with `.none`) the iOS-side visual effect
    /// preset for the currently selected segment.
    func setSelectedVisualEffect(_ preset: VisualEffectPreset) {
        guard let id = selectedSegmentID else { return }
        if preset == .none {
            visualEffects.removeValue(forKey: id)
        } else {
            visualEffects[id] = preset
        }
        objectWillChange.send()
    }

    /// Curated set of color-grading presets mirroring CapCut's 滤镜.
    /// These are client-only; they map to CIColorControls values the
    /// macOS renderer already honours, so exports will match once the
    /// full renderer ports.
    enum FilterPreset: String, CaseIterable, Identifiable {
        case original    // 原图
        case warm        // 暖阳
        case cool        // 冷调
        case vivid       // 鲜艳
        case mono        // 黑白
        case film        // 胶片
        case vlog        // Vlog

        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "原图"
            case .warm:     return "暖阳"
            case .cool:     return "冷调"
            case .vivid:    return "鲜艳"
            case .mono:     return "黑白"
            case .film:     return "胶片"
            case .vlog:     return "Vlog"
            }
        }
        var brightness: Double {
            switch self {
            case .original: return 0
            case .warm:     return 0.05
            case .cool:     return -0.02
            case .vivid:    return 0.03
            case .mono:     return 0
            case .film:     return -0.05
            case .vlog:     return 0.04
            }
        }
        var contrast: Double {
            switch self {
            case .original: return 1
            case .warm:     return 1.05
            case .cool:     return 1.03
            case .vivid:    return 1.15
            case .mono:     return 1.1
            case .film:     return 1.08
            case .vlog:     return 1.05
            }
        }
        var saturation: Double {
            switch self {
            case .original: return 1
            case .warm:     return 1.1
            case .cool:     return 0.95
            case .vivid:    return 1.35
            case .mono:     return 0
            case .film:     return 0.85
            case .vlog:     return 1.2
            }
        }
    }

    // MARK: - Reorder / merge

    /// Move the selected segment left (offset -1) or right (+1) on its
    /// track. No-op when already at the edge.
    func moveSelectedSegment(offset: Int) {
        guard offset != 0, let id = selectedSegmentID else { return }
        var next = tracks
        for i in next.indices {
            if let idx = next[i].segments.firstIndex(where: { $0.id == id }) {
                let newIdx = idx + offset
                guard next[i].segments.indices.contains(newIdx) else { return }
                let seg = next[i].segments.remove(at: idx)
                next[i].segments.insert(seg, at: newIdx)
                pushUndoSnapshot()
                tracks = next
                persistSession()
                return
            }
        }
    }

    /// Merge the selected segment with the one to its right — only
    /// works when they come from the same source and are already
    /// contiguous in source time (typical after a split without any
    /// trim). Otherwise the merged clip would drop frames; we skip.
    func mergeSelectedWithNext() {
        guard let id = selectedSegmentID else { return }
        var next = tracks
        for i in next.indices {
            guard let idx = next[i].segments.firstIndex(where: { $0.id == id }),
                  idx + 1 < next[i].segments.count else { continue }
            let left = next[i].segments[idx]
            let right = next[i].segments[idx + 1]
            guard left.sourceVideoID == right.sourceVideoID,
                  abs(left.range.endSeconds - right.range.startSeconds) < 0.01 else { return }
            let merged = TimelineSegment(
                id: left.id,
                sourceVideoID: left.sourceVideoID,
                range: TimeRange(startSeconds: left.range.startSeconds,
                                 endSeconds: right.range.endSeconds),
                text: left.text,
                subtitles: left.subtitles + right.subtitles,
                volumeLevel: left.volumeLevel,
                isVideoHidden: left.isVideoHidden,
                speedRate: left.speedRate,
                effects: left.effects,
                placementOffset: left.placementOffset,
                alternatives: left.alternatives,
                linkedSegmentID: left.linkedSegmentID,
                pipLayout: left.pipLayout,
                freeTransform: left.freeTransform,
                overlaySpec: left.overlaySpec
            )
            next[i].segments.replaceSubrange(idx...(idx + 1), with: [merged])
            pushUndoSnapshot()
            tracks = next
            persistSession()
            return
        }
    }

    /// Whether the selected segment has an adjacent right-neighbor
    /// that can be merged (same source + contiguous range).
    var canMergeSelected: Bool {
        guard let id = selectedSegmentID else { return false }
        for t in tracks {
            if let idx = t.segments.firstIndex(where: { $0.id == id }),
               idx + 1 < t.segments.count {
                let a = t.segments[idx], b = t.segments[idx + 1]
                return a.sourceVideoID == b.sourceVideoID
                    && abs(a.range.endSeconds - b.range.startSeconds) < 0.01
            }
        }
        return false
    }

    // MARK: - Subtitle display

    func toggleShowSubtitles() {
        showSubtitles.toggle()
        persistSession()
    }

    // MARK: - Text overlays

    /// Insert a new text overlay at the current playhead with sensible
    /// defaults (bottom third, 3s duration). Returns the new overlay's
    /// ID so the caller can immediately open an edit sheet for it.
    @discardableResult
    func addTextOverlay(text: String = "双击编辑") -> UUID {
        let start = currentTime
        let dur = min(3.0, max(1.0, primaryDurationSeconds - start))
        let overlay = IOSSessionState.TextOverlay(
            id: UUID(),
            text: text,
            startSeconds: start,
            endSeconds: start + dur,
            positionX: 0.5,
            positionY: 0.18,
            fontSizeRel: 0.06,
            colorR: 1, colorG: 1, colorB: 1
        )
        textOverlays.append(overlay)
        return overlay.id
    }

    func updateTextOverlay(id: UUID, _ change: (inout IOSSessionState.TextOverlay) -> Void) {
        guard let idx = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        var next = textOverlays
        change(&next[idx])
        textOverlays = next
    }

    func deleteTextOverlay(id: UUID) {
        textOverlays.removeAll { $0.id == id }
    }

    // MARK: - Transitions

    /// Default cross-fade-to-black duration applied by the toolbar
    /// toggle. Half a second reads as an intentional cut-to-black
    /// without stalling the pacing.
    static let defaultTransitionSeconds: Double = 0.5

    func hasTransition(for segmentID: UUID) -> Bool {
        (transitions[segmentID] ?? 0) > 0
    }

    /// Toggle the exit-transition on the segment. When enabled, the
    /// last T seconds of this segment fade to black and the first T
    /// seconds of the next segment fade up from black. Toggling off
    /// removes the entry so JSON stays clean.
    func toggleTransition(for segmentID: UUID) {
        var next = transitions
        if (next[segmentID] ?? 0) > 0 {
            next.removeValue(forKey: segmentID)
        } else {
            next[segmentID] = Self.defaultTransitionSeconds
        }
        transitions = next
    }

    /// Overwrite the transition duration on a specific segment.
    /// Values <= 0 remove the entry (equivalent to disabling). Used
    /// by the transition-duration sheet so the user can fine-tune
    /// how long the fade spans without also triggering an undo per
    /// slider tick — interactive-edit coalescing belongs on the
    /// caller.
    func setTransitionDuration(for segmentID: UUID, seconds: Double) {
        var next = transitions
        if seconds <= 0.001 {
            next.removeValue(forKey: segmentID)
        } else {
            next[segmentID] = min(5, max(0.05, seconds))
        }
        transitions = next
    }

    /// Apply a uniform cross-fade transition to every primary-track
    /// boundary (the last segment is skipped — nothing to fade into).
    /// Returns the count of segments that received a transition. Used
    /// by the AI 智能转场 tile.
    @discardableResult
    func applyUniformTransition(seconds: Double = 0.5) -> Int {
        guard let primary = tracks.first(where: { $0.kind == .video }) else { return 0 }
        let ids = primary.segments.dropLast().map { $0.id }
        guard !ids.isEmpty else { return 0 }
        var next = transitions
        let clamped = min(5.0, max(0.05, seconds))
        for id in ids { next[id] = clamped }
        transitions = next
        return ids.count
    }

    /// Apply a fade-in to the first primary segment and fade-out to the
    /// last — a minimal "智能片头 / 智能片尾" pass that doesn't require
    /// LLM tooling. Returns true when the timeline had at least one
    /// primary segment to fade.
    @discardableResult
    func applyIntroOutroFade(seconds: Double = 0.8) -> Bool {
        guard let tIdx = tracks.firstIndex(where: { $0.kind == .video }),
              !tracks[tIdx].segments.isEmpty else { return false }
        let clamped = min(3.0, max(0.1, seconds))
        var next = tracks
        var first = next[tIdx].segments[0]
        var firstFx = first.effects
        firstFx.audioFadeInDuration = max(firstFx.audioFadeInDuration, clamped)
        first.effects = firstFx
        next[tIdx].segments[0] = first

        let lastIdx = next[tIdx].segments.count - 1
        var last = next[tIdx].segments[lastIdx]
        var lastFx = last.effects
        lastFx.audioFadeOutDuration = max(lastFx.audioFadeOutDuration, clamped)
        last.effects = lastFx
        next[tIdx].segments[lastIdx] = last

        pushUndoSnapshot()
        tracks = next
        // Visual fade-out on the last clip is driven by the transition
        // map (same knob the transition sheet uses).
        var nextTransitions = transitions
        nextTransitions[last.id] = clamped
        transitions = nextTransitions
        persistSession()
        return true
    }

    // MARK: - Chapters

    /// Auto-suggest a sensible PiP layout for every overlay segment
    /// that doesn't already have one. Heuristic mirrors the macOS
    /// AutoPiPAnalyzer's defaults without running a full Vision pass:
    ///
    /// • Source aspect closer to square (0.7…1.4) → circle (presenter
    ///   cam looks best framed as a coin).
    /// • Wider/taller sources → rounded square at 22% of canvas height
    ///   in the bottom-right corner with a small inset, matching the
    ///   `PiPLayout.default` preset every other entry point uses.
    ///
    /// Returns the number of overlays updated. Caller can flash a
    /// toast based on that. Idempotent — re-running won't disturb
    /// overlays that already carry a layout (user customizations
    /// stick).
    @discardableResult
    func applyPiPSuggestionsForOverlays() -> Int {
        var next = tracks
        var changed = 0
        for ti in next.indices where next[ti].kind == .overlay {
            for si in next[ti].segments.indices {
                let seg = next[ti].segments[si]
                guard seg.pipLayout == nil else { continue }
                let aspect = sourceAspect(for: seg) ?? 16.0 / 9.0
                let shape: PiPLayout.Shape = (aspect >= 0.7 && aspect <= 1.4) ? .circle : .roundedSquare
                next[ti].segments[si].pipLayout = PiPLayout(
                    shape: shape,
                    corner: .bottomRight,
                    sizeFraction: 0.22,
                    insetFraction: 0.025,
                    borderWidthPx: 0,
                    borderColorHex: nil,
                    shadowEnabled: true
                )
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        pushUndoSnapshot()
        tracks = next
        persistSession()
        return changed
    }

    private func sourceAspect(for segment: TimelineSegment) -> Double? {
        guard let asset = manifest.media.first(where: { $0.id == segment.sourceVideoID }),
              let analysis = asset.analysis,
              analysis.height > 0 else { return nil }
        return Double(analysis.width) / Double(analysis.height)
    }

    // MARK: - Chapters (legacy section header below; kept for diff scope)

    /// Add a chapter that starts at the current playhead and runs to
    /// the end of the timeline (or to the next chapter that already
    /// starts after the playhead). Existing chapters whose ranges
    /// overlap the new chapter's start are clipped so the list stays
    /// non-overlapping and sorted. Returns the new chapter's id, or
    /// nil if the timeline is empty / a chapter already starts at
    /// this exact point (idempotent).
    @discardableResult
    func addChapterAtPlayhead(title: String? = nil) -> UUID? {
        let total = primaryDurationSeconds
        guard total > 0.5 else { return nil }
        let start = max(0, min(currentTime, total - 0.1))
        if chapters.contains(where: { abs($0.startSeconds - start) < 0.05 }) {
            return nil
        }
        let nextStart = chapters
            .map(\.startSeconds)
            .filter { $0 > start + 0.05 }
            .min() ?? total
        let new = VideoChapter(
            startSeconds: start,
            endSeconds: nextStart,
            title: title ?? "章节 \(chapters.count + 1)"
        )
        var next = chapters
        // Truncate the chapter that previously contained `start`.
        for i in next.indices where next[i].startSeconds < start && next[i].endSeconds > start {
            next[i].endSeconds = start
        }
        next.append(new)
        next.sort { $0.startSeconds < $1.startSeconds }
        chapters = next
        return new.id
    }

    func renameChapter(id: UUID, title: String) {
        guard let idx = chapters.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = chapters
        next[idx].title = trimmed
        chapters = next
    }

    func deleteChapter(id: UUID) {
        guard let idx = chapters.firstIndex(where: { $0.id == id }) else { return }
        var next = chapters
        let removed = next.remove(at: idx)
        // Extend the previous chapter to cover the gap so the bar
        // stays gap-free.
        if idx > 0 {
            next[idx - 1].endSeconds = removed.endSeconds
        }
        chapters = next
    }

    /// Overwrite the chapter list wholesale (used by AI chapter
    /// generation). Sorts defensively, clamps to the composed
    /// timeline duration, and drops zero-length spans. Pushes an
    /// undo snapshot so the user can revert with a single tap.
    func replaceChapters(with incoming: [VideoChapter]) {
        let total = primaryDurationSeconds
        let sorted = incoming.sorted { $0.startSeconds < $1.startSeconds }
        var cleaned: [VideoChapter] = []
        for var c in sorted {
            c.startSeconds = max(0, min(c.startSeconds, total - 0.1))
            c.endSeconds = max(c.startSeconds + 0.2, min(c.endSeconds, total))
            if let last = cleaned.last, c.startSeconds <= last.startSeconds + 0.2 { continue }
            cleaned.append(c)
        }
        pushUndoSnapshot()
        chapters = cleaned
    }

    /// Chapter that contains the current playhead, or nil when the
    /// playhead sits before the first chapter (or the timeline has
    /// no chapters yet).
    var currentChapter: VideoChapter? {
        chapters.first { $0.startSeconds <= currentTime && currentTime < $0.endSeconds }
            ?? chapters.last { $0.startSeconds <= currentTime }
    }

    /// Replace subtitles on the selected segment (used by the SFSpeech
    /// auto-captions flow).
    // MARK: - Subtitle style


    func updateSubtitleStyle(_ change: (inout SubtitleStyle) -> Void) {
        var next = subtitleStyle
        change(&next)
        subtitleStyle = next
        persistSession()
    }

    func setSelectedSegmentSubtitles(_ subs: [SubtitleEntry]) {
        mutateSelected { $0.subtitles = subs }
    }

    /// Insert a text cue at the current playhead into whichever
    /// primary-track segment covers that composed time. When the
    /// insertion lands in a gap, nothing happens. Returns the cue id
    /// on success.
    @discardableResult
    func insertTextAtPlayhead(_ text: String, duration: Double = 2.0) -> UUID? {
        guard let primaryIdx = tracks.firstIndex(where: { $0.kind == .video }) else { return nil }
        var cursor: Double = 0
        let primary = tracks[primaryIdx]
        for (idx, seg) in primary.segments.enumerated() {
            let segStart = seg.placementOffset ?? cursor
            let segEnd = segStart + seg.durationSeconds
            if currentTime >= segStart && currentTime <= segEnd {
                let rel = currentTime - segStart
                let cueID = UUID()
                var next = tracks
                var newSeg = next[primaryIdx].segments[idx]
                newSeg.subtitles.append(SubtitleEntry(
                    id: cueID,
                    relativeStart: max(0, rel),
                    relativeDuration: max(0.5, duration),
                    text: text
                ))
                next[primaryIdx].segments[idx] = newSeg
                pushUndoSnapshot()
                tracks = next
                persistSession()
                return cueID
            }
            if seg.placementOffset == nil { cursor = segEnd }
        }
        return nil
    }

    /// Composed active subtitle for the current playhead time, or nil.
    /// Used by PreviewPane to draw a caption overlay.
    var activeSubtitleText: String? {
        activeSubtitleLines?.primary
    }

    /// Composed active subtitle for the current playhead time split
    /// into primary (source language) and optional secondary
    /// (translation, if `transcriptDisplayLocale` is set and the cue
    /// has a translation for that locale).
    var activeSubtitleLines: (primary: String, secondary: String?)? {
        guard showSubtitles,
              let primary = tracks.first(where: { $0.kind == .video }) else { return nil }
        var cursor: Double = 0
        for seg in primary.segments {
            let start = seg.placementOffset ?? cursor
            let end = start + seg.durationSeconds
            if currentTime >= start && currentTime <= end {
                let rel = (currentTime - start) * seg.normalizedSpeedRate
                for sub in seg.subtitles
                where rel >= sub.relativeStart && rel <= sub.relativeStart + sub.relativeDuration {
                    var secondary: String? = nil
                    if let loc = transcriptDisplayLocale,
                       let translated = sub.translations[loc],
                       !translated.isEmpty {
                        secondary = translated
                    }
                    return (sub.text, secondary)
                }
                return nil
            }
            if seg.placementOffset == nil { cursor = end }
        }
        return nil
    }

    /// Walk every primary segment and flatten its per-segment
    /// subtitles into composed-timeline `TextOverlay`s using the
    /// active `subtitleStyle`. Used at export time so the burned-in
    /// MP4 matches what the user sees in preview — the preview still
    /// uses the live SwiftUI caption overlay, which is why we do NOT
    /// pass these into PreviewPane.
    ///
    /// Returns an empty list when `showSubtitles` is false, so the
    /// user's "closed captions off" choice round-trips through export.
    var synthesizedSubtitleOverlays: [IOSSessionState.TextOverlay] {
        guard showSubtitles,
              let primary = tracks.first(where: { $0.kind == .video }) else { return [] }
        let style = subtitleStyle
        // Subtitle fontSizePoints is expressed at 1080p canonical
        // height; our TextOverlay fontSizeRel is relative to canvas
        // short side, so divide by 1080 to convert.
        let fontSizeRel = max(0.02, min(0.2, style.fontSizePoints / 1080.0))
        // verticalPositionFraction: 0 = top, 1 = bottom (SwiftUI
        // convention). Core Image Y is origin-bottom, so invert.
        let posY = max(0.05, min(0.95, 1.0 - style.verticalPositionFraction))
        let posX = max(0.05, min(0.95, style.horizontalPositionFraction))

        // Secondary (translation) line — slightly smaller, offset so
        // that when the subtitle sits near the bottom (the common
        // case) the translation renders ABOVE the primary line; when
        // near the top it renders BELOW. Keeps both lines on-canvas
        // without changing the user's layout anchor.
        let secondaryLocale = transcriptDisplayLocale
        let secondaryFontSizeRel = max(0.015, fontSizeRel * 0.8)
        let secondaryGap = fontSizeRel * 1.25
        let secondaryPosY: Double = (style.verticalPositionFraction >= 0.5)
            ? min(0.98, posY + secondaryGap)
            : max(0.02, posY - secondaryGap)

        var out: [IOSSessionState.TextOverlay] = []
        var cursor: Double = 0
        for seg in primary.segments {
            let segStart = seg.placementOffset ?? cursor
            let speed = max(0.01, seg.normalizedSpeedRate)
            for sub in seg.subtitles {
                let composedStart = segStart + sub.relativeStart / speed
                let composedEnd = segStart + (sub.relativeStart + sub.relativeDuration) / speed
                out.append(IOSSessionState.TextOverlay(
                    id: sub.id,
                    text: sub.text,
                    startSeconds: composedStart,
                    endSeconds: composedEnd,
                    positionX: posX,
                    positionY: posY,
                    fontSizeRel: fontSizeRel,
                    colorR: style.textColor.red,
                    colorG: style.textColor.green,
                    colorB: style.textColor.blue
                ))
                if let loc = secondaryLocale,
                   let translated = sub.translations[loc],
                   !translated.isEmpty {
                    out.append(IOSSessionState.TextOverlay(
                        id: UUID(),
                        text: translated,
                        startSeconds: composedStart,
                        endSeconds: composedEnd,
                        positionX: posX,
                        positionY: secondaryPosY,
                        fontSizeRel: secondaryFontSizeRel,
                        colorR: style.textColor.red,
                        colorG: style.textColor.green,
                        colorB: style.textColor.blue
                    ))
                }
            }
            if seg.placementOffset == nil { cursor = segStart + seg.durationSeconds }
        }
        return out
    }

    /// Write a freshly-transcribed subtitle list onto the segment with
    /// the given ID (used by AI transcription which may outlive the
    /// current selection).
    func setSubtitles(_ subs: [SubtitleEntry], forSegmentID id: UUID) {
        var next = tracks
        for i in next.indices {
            if let idx = next[i].segments.firstIndex(where: { $0.id == id }) {
                next[i].segments[idx].subtitles = subs
                pushUndoSnapshot()
                tracks = next
                persistSession()
                return
            }
        }
    }

    // MARK: - Transcript editor APIs

    /// One transcript cue projected onto the composed timeline. Used by
    /// the iOS TranscriptSheet to display a flat, time-ordered list of
    /// every subtitle in the project.
    struct TranscriptCue: Identifiable, Equatable {
        let id: UUID
        let segmentID: UUID
        let composedStart: Double
        let composedEnd: Double
        let text: String
        let speakerID: Int?
        let translations: [String: String]
    }

    /// Flatten every primary-track segment's subtitles into a single
    /// time-ordered list, with timings projected onto the composed
    /// timeline (accounting for `placementOffset` and speed).
    var composedTranscriptCues: [TranscriptCue] {
        guard let primary = tracks.first(where: { $0.kind == .video }) else { return [] }
        var out: [TranscriptCue] = []
        var cursor: Double = 0
        for seg in primary.segments {
            let segStart = seg.placementOffset ?? cursor
            let speed = max(0.01, seg.normalizedSpeedRate)
            for sub in seg.subtitles {
                let start = segStart + sub.relativeStart / speed
                let end = segStart + (sub.relativeStart + sub.relativeDuration) / speed
                out.append(TranscriptCue(
                    id: sub.id,
                    segmentID: seg.id,
                    composedStart: start,
                    composedEnd: end,
                    text: sub.text,
                    speakerID: sub.speakerID,
                    translations: sub.translations
                ))
            }
            if seg.placementOffset == nil { cursor = segStart + seg.durationSeconds }
        }
        return out.sorted { $0.composedStart < $1.composedStart }
    }

    /// Inline-edit a single cue's text. No-op if the cue ID can't be
    /// found. Pushes one undo snapshot per call.
    func updateTranscriptCueText(id: UUID, newText: String) {
        var next = tracks
        for ti in next.indices {
            for si in next[ti].segments.indices {
                if let ci = next[ti].segments[si].subtitles.firstIndex(where: { $0.id == id }) {
                    let old = next[ti].segments[si].subtitles[ci]
                    if old.text == newText { return }
                    next[ti].segments[si].subtitles[ci] = SubtitleEntry(
                        id: old.id,
                        relativeStart: old.relativeStart,
                        relativeDuration: old.relativeDuration,
                        text: newText,
                        speakerID: old.speakerID,
                        translations: old.translations
                    )
                    pushUndoSnapshot()
                    tracks = next
                    persistSession()
                    return
                }
            }
        }
    }

    /// Set or clear a single locale's translation on a cue. Pass an
    /// empty/whitespace string to remove the translation for that
    /// locale. No-op if the cue can't be found.
    func setTranscriptCueTranslation(id: UUID, locale: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = tracks
        for ti in next.indices {
            for si in next[ti].segments.indices {
                if let ci = next[ti].segments[si].subtitles.firstIndex(where: { $0.id == id }) {
                    let old = next[ti].segments[si].subtitles[ci]
                    var translations = old.translations
                    if trimmed.isEmpty {
                        guard translations[locale] != nil else { return }
                        translations.removeValue(forKey: locale)
                    } else {
                        if translations[locale] == trimmed { return }
                        translations[locale] = trimmed
                    }
                    next[ti].segments[si].subtitles[ci] = SubtitleEntry(
                        id: old.id,
                        relativeStart: old.relativeStart,
                        relativeDuration: old.relativeDuration,
                        text: old.text,
                        speakerID: old.speakerID,
                        translations: translations
                    )
                    pushUndoSnapshot()
                    tracks = next
                    persistSession()
                    return
                }
            }
        }
    }

    /// Delete one transcript cue and excise the source-media interval it
    /// covered from its parent segment, splitting the segment into kept
    /// runs around the deleted cue. Mirrors `removeFillerWords` for a
    /// single cue. Returns true on success.
    @discardableResult
    func deleteTranscriptCue(id: UUID) -> Bool {
        var next = tracks
        for ti in next.indices where next[ti].kind == .video {
            guard let segIdx = next[ti].segments.firstIndex(where: { seg in
                seg.subtitles.contains { $0.id == id }
            }) else { continue }
            let seg = next[ti].segments[segIdx]
            guard let cue = seg.subtitles.first(where: { $0.id == id }) else { continue }

            let base = seg.range.startSeconds
            let cueStart = base + max(0, cue.relativeStart)
            let cueEnd = cueStart + max(0.01, cue.relativeDuration)
            let segEnd = seg.range.endSeconds
            let clippedStart = max(seg.range.startSeconds, min(segEnd, cueStart))
            let clippedEnd = max(clippedStart, min(segEnd, cueEnd))

            var keptRuns: [(Double, Double)] = []
            if clippedStart > seg.range.startSeconds + 0.02 {
                keptRuns.append((seg.range.startSeconds, clippedStart))
            }
            if segEnd > clippedEnd + 0.02 {
                keptRuns.append((clippedEnd, segEnd))
            }

            var rewritten = Array(next[ti].segments.prefix(segIdx))
            for run in keptRuns {
                let kept = seg.subtitles.compactMap { c -> SubtitleEntry? in
                    if c.id == id { return nil }
                    let cs = base + c.relativeStart
                    let ce = cs + c.relativeDuration
                    guard cs >= run.0 - 0.01, ce <= run.1 + 0.01 else { return nil }
                    return SubtitleEntry(
                        id: UUID(),
                        relativeStart: cs - run.0,
                        relativeDuration: c.relativeDuration,
                        text: c.text,
                        speakerID: c.speakerID,
                        translations: c.translations
                    )
                }
                rewritten.append(TimelineSegment(
                    id: UUID(),
                    sourceVideoID: seg.sourceVideoID,
                    range: TimeRange(startSeconds: run.0, endSeconds: run.1),
                    text: seg.text,
                    subtitles: kept,
                    volumeLevel: seg.volumeLevel,
                    isVideoHidden: seg.isVideoHidden,
                    speedRate: seg.speedRate,
                    effects: seg.effects,
                    placementOffset: nil,
                    alternatives: seg.alternatives,
                    linkedSegmentID: nil,
                    pipLayout: seg.pipLayout,
                    freeTransform: seg.freeTransform,
                    overlaySpec: seg.overlaySpec
                ))
            }
            rewritten.append(contentsOf: next[ti].segments.suffix(from: segIdx + 1))
            next[ti].segments = rewritten

            pushUndoSnapshot()
            tracks = next
            if selectedSegmentID == seg.id { selectedSegmentID = nil }
            persistSession()
            return true
        }
        return false
    }

    /// Find/replace across every cue's text. Returns the number of cues
    /// modified. Pushes a single undo snapshot when at least one
    /// substitution happened.
    @discardableResult
    func replaceInTranscript(find: String, replace: String, caseSensitive: Bool) -> Int {
        let needle = find
        guard !needle.isEmpty else { return 0 }
        var next = tracks
        var changed = 0
        for ti in next.indices {
            for si in next[ti].segments.indices {
                for ci in next[ti].segments[si].subtitles.indices {
                    let old = next[ti].segments[si].subtitles[ci]
                    let updated: String
                    if caseSensitive {
                        updated = old.text.replacingOccurrences(of: needle, with: replace)
                    } else {
                        updated = old.text.replacingOccurrences(
                            of: needle, with: replace, options: [.caseInsensitive]
                        )
                    }
                    if updated != old.text {
                        next[ti].segments[si].subtitles[ci] = SubtitleEntry(
                            id: old.id,
                            relativeStart: old.relativeStart,
                            relativeDuration: old.relativeDuration,
                            text: updated,
                            speakerID: old.speakerID,
                            translations: old.translations
                        )
                        changed += 1
                    }
                }
            }
        }
        if changed > 0 {
            pushUndoSnapshot()
            tracks = next
            persistSession()
        }
        return changed
    }

    /// Transcribe every primary-track segment that doesn't yet have
    /// subtitles. Existing cues are left in place. Returns total cues
    /// added.
    @discardableResult
    func transcribeAllPrimarySegments(locale: Locale? = nil) async -> Int {
        guard let primary = tracks.first(where: { $0.kind == .video }) else { return 0 }
        var added = 0
        for seg in primary.segments {
            guard seg.subtitles.isEmpty else { continue }
            guard let asset = manifest.media.first(where: { $0.id == seg.sourceVideoID }) else { continue }
            let url = IOSCompositionBuilder.resolveURL(for: asset, projectRoot: store.projectRoot)
            do {
                let entries = try await IOSTranscriber.transcribe(
                    fileURL: url,
                    options: .init(locale: locale)
                )
                let trimmed = entries.compactMap { e -> SubtitleEntry? in
                    let segStartRel = e.relativeStart - seg.range.startSeconds
                    let segEndRel = segStartRel + e.relativeDuration
                    let segDur = seg.durationSeconds
                    guard segEndRel > 0, segStartRel < segDur else { return nil }
                    let clippedStart = max(0, segStartRel)
                    let clippedDur = min(segDur, segEndRel) - clippedStart
                    guard clippedDur > 0.05 else { return nil }
                    return SubtitleEntry(
                        id: UUID(),
                        relativeStart: clippedStart,
                        relativeDuration: clippedDur,
                        text: e.text,
                        speakerID: e.speakerID,
                        translations: e.translations
                    )
                }
                if !trimmed.isEmpty {
                    setSubtitles(trimmed, forSegmentID: seg.id)
                    added += trimmed.count
                }
            } catch {
                continue
            }
        }
        return added
    }

    /// Encode every cue as SRT for sharing/export.
    func subtitlesSRT() -> String {
        formatSubtitles(separator: ",")
    }

    /// Encode every cue as WebVTT for sharing/export.
    func subtitlesVTT() -> String {
        "WEBVTT\n\n" + formatSubtitles(separator: ".")
    }

    private func formatSubtitles(separator: String) -> String {
        var out: [String] = []
        var idx = 1
        for cue in composedTranscriptCues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append("\(idx)")
            out.append("\(timestamp(cue.composedStart, sep: separator)) --> \(timestamp(cue.composedEnd, sep: separator))")
            out.append(text)
            out.append("")
            idx += 1
        }
        return out.joined(separator: "\n")
    }

    private func timestamp(_ seconds: Double, sep: String) -> String {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1_000
        let ms = totalMs % 1_000
        return String(format: "%02d:%02d:%02d\(sep)%03d", h, m, s, ms)
    }

    /// Parse an SRT / WebVTT file and splice its cues onto the primary
    /// track. Cues are matched to the segment covering their composed
    /// start time; timing is back-projected through each segment's
    /// `placementOffset` + speed so re-exporting produces the same
    /// composed timestamps. Overwrites any subtitles already on the
    /// affected segments. Returns the number of imported cues.
    @discardableResult
    func importSubtitles(fromFile url: URL) throws -> Int {
        let body = try String(contentsOf: url, encoding: .utf8)
        let cues = try SubtitleImporter.parse(body)
        guard let primary = tracks.first(where: { $0.kind == .video }) else { return 0 }

        // Build (segIndex, composedStart, composedEnd, speed) lookup.
        struct Placement { let index: Int; let start: Double; let end: Double; let speed: Double }
        var placements: [Placement] = []
        var cursor: Double = 0
        for (idx, seg) in primary.segments.enumerated() {
            let segStart = seg.placementOffset ?? cursor
            let segEnd = segStart + seg.durationSeconds
            placements.append(Placement(
                index: idx, start: segStart, end: segEnd,
                speed: max(0.01, seg.normalizedSpeedRate)
            ))
            if seg.placementOffset == nil { cursor = segEnd }
        }

        // Group cues by target segment.
        var grouped: [Int: [SubtitleEntry]] = [:]
        for cue in cues {
            guard let p = placements.first(where: { cue.startSeconds >= $0.start - 0.01
                                                     && cue.startSeconds < $0.end + 0.01 }) else { continue }
            let relStart = max(0, (cue.startSeconds - p.start) * p.speed)
            let clippedEnd = min(cue.endSeconds, p.end)
            let relEnd = max(relStart + 0.05, (clippedEnd - p.start) * p.speed)
            let entry = SubtitleEntry(
                id: UUID(),
                relativeStart: relStart,
                relativeDuration: relEnd - relStart,
                text: cue.text
            )
            grouped[p.index, default: []].append(entry)
        }
        guard !grouped.isEmpty else { return 0 }

        var nextTracks = tracks
        for ti in nextTracks.indices where nextTracks[ti].kind == .video {
            for (segIdx, entries) in grouped {
                guard segIdx < nextTracks[ti].segments.count else { continue }
                nextTracks[ti].segments[segIdx].subtitles = entries.sorted {
                    $0.relativeStart < $1.relativeStart
                }
            }
            break
        }

        let total = grouped.values.reduce(0) { $0 + $1.count }
        pushUndoSnapshot()
        tracks = nextTracks
        persistSession()
        return total
    }

    /// Default filler words used by `removeFillerWords`. Matches macOS
    /// `AgentDefaults.fillerWords` so cross-platform projects feel
    /// consistent after a cleanup pass.
    static let defaultFillerWords: [String] = [
        "uh", "um", "uhh", "umm", "uhm", "er", "erm", "ah", "ahh",
        "like", "you know", "i mean", "sort of", "kind of", "basically",
        "嗯", "啊", "呃", "那个", "这个", "然后", "就是", "其实",
    ]

    /// Scan every primary-track segment's subtitles for filler cues and
    /// excise those intervals from the timeline. Each segment that
    /// contains filler cues is split into multiple sub-segments whose
    /// source ranges skip the filler intervals; subtitles landing in
    /// the kept runs are preserved (their `relativeStart` is rebased
    /// against the new piece). Returns the number of filler cues
    /// removed across the timeline.
    ///
    /// Requires subtitles to already exist on the segments (run
    /// 智能字幕 first, or no cues == nothing to do).
    @discardableResult
    func removeFillerWords(extraTerms: [String] = []) -> Int {
        let terms = (Self.defaultFillerWords + extraTerms)
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return 0 }

        var next = tracks
        var removed = 0
        for ti in next.indices where next[ti].kind == .video {
            var rewritten: [TimelineSegment] = []
            for seg in next[ti].segments {
                let matchedCues = seg.subtitles.filter { cue in
                    let lowered = cue.text.lowercased()
                    let words = lowered.unicodeScalars
                        .split { !CharacterSet.letters.union(.decimalDigits).contains($0) }
                        .map { String($0) }
                    for term in terms {
                        if term.contains(" ") {
                            if lowered.contains(term) { return true }
                        } else if words.contains(term) {
                            return true
                        }
                    }
                    return false
                }
                if matchedCues.isEmpty {
                    rewritten.append(seg)
                    continue
                }

                // Exclusion intervals in source-media seconds, merged.
                let base = seg.range.startSeconds
                var excl: [(Double, Double)] = matchedCues
                    .map { (base + max(0, $0.relativeStart),
                            base + max(0, $0.relativeStart) + max(0.01, $0.relativeDuration)) }
                    .sorted { $0.0 < $1.0 }
                var merged: [(Double, Double)] = []
                for iv in excl {
                    if let last = merged.last, iv.0 <= last.1 + 0.01 {
                        merged[merged.count - 1].1 = max(last.1, iv.1)
                    } else {
                        merged.append(iv)
                    }
                }
                excl = merged
                removed += matchedCues.count

                // Build kept runs between exclusions.
                var keptRuns: [(Double, Double)] = []
                var cursor = seg.range.startSeconds
                for iv in excl {
                    if iv.0 > cursor + 0.02 { keptRuns.append((cursor, min(iv.0, seg.range.endSeconds))) }
                    cursor = max(cursor, iv.1)
                    if cursor >= seg.range.endSeconds { break }
                }
                if cursor < seg.range.endSeconds - 0.02 {
                    keptRuns.append((cursor, seg.range.endSeconds))
                }

                // Rewrite each kept run as a new segment, preserving
                // non-filler subtitles that fall inside it with
                // adjusted relative timing.
                for run in keptRuns {
                    let kept = seg.subtitles.compactMap { cue -> SubtitleEntry? in
                        let cueStart = base + cue.relativeStart
                        let cueEnd = cueStart + cue.relativeDuration
                        guard cueStart >= run.0 - 0.01, cueEnd <= run.1 + 0.01 else { return nil }
                        return SubtitleEntry(
                            id: UUID(),
                            relativeStart: cueStart - run.0,
                            relativeDuration: cue.relativeDuration,
                            text: cue.text,
                            speakerID: cue.speakerID
                        )
                    }
                    let piece = TimelineSegment(
                        id: UUID(),
                        sourceVideoID: seg.sourceVideoID,
                        range: TimeRange(startSeconds: run.0, endSeconds: run.1),
                        text: seg.text,
                        subtitles: kept,
                        volumeLevel: seg.volumeLevel,
                        isVideoHidden: seg.isVideoHidden,
                        speedRate: seg.speedRate,
                        effects: seg.effects,
                        placementOffset: nil,
                        alternatives: seg.alternatives,
                        linkedSegmentID: nil,
                        pipLayout: seg.pipLayout,
                        freeTransform: seg.freeTransform,
                        overlaySpec: seg.overlaySpec
                    )
                    _ = piece
                    rewritten.append(piece)
                }
            }
            next[ti].segments = rewritten
        }

        if removed > 0 {
            pushUndoSnapshot()
            tracks = next
            // Previous selection likely points at a segment that was
            // split into pieces; clear it rather than re-map, since
            // the user's intent was global cleanup.
            selectedSegmentID = nil
            persistSession()
        }
        return removed
    }

    // MARK: - Audio track

    /// Delete a set of transcript cues at once, re-splitting timeline
    /// segments around the removed cue windows just like
    /// `removeFillerWords` does. Used by the 智能首剪 (smart.full) AI
    /// preset to apply the LLM's keep/cut decision in one undo step.
    /// Returns the number of cues actually removed.
    func removeCues(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        var next = tracks
        var removed = 0
        for ti in next.indices where next[ti].kind == .video {
            var rewritten: [TimelineSegment] = []
            for seg in next[ti].segments {
                let matched = seg.subtitles.filter { ids.contains($0.id) }
                if matched.isEmpty {
                    rewritten.append(seg)
                    continue
                }
                removed += matched.count

                let base = seg.range.startSeconds
                var excl: [(Double, Double)] = matched
                    .map { (base + max(0, $0.relativeStart),
                            base + max(0, $0.relativeStart) + max(0.01, $0.relativeDuration)) }
                    .sorted { $0.0 < $1.0 }
                var merged: [(Double, Double)] = []
                for iv in excl {
                    if let last = merged.last, iv.0 <= last.1 + 0.01 {
                        merged[merged.count - 1].1 = max(last.1, iv.1)
                    } else {
                        merged.append(iv)
                    }
                }
                excl = merged

                var keptRuns: [(Double, Double)] = []
                var cursor = seg.range.startSeconds
                for iv in excl {
                    if iv.0 > cursor + 0.02 {
                        keptRuns.append((cursor, min(iv.0, seg.range.endSeconds)))
                    }
                    cursor = max(cursor, iv.1)
                    if cursor >= seg.range.endSeconds { break }
                }
                if cursor < seg.range.endSeconds - 0.02 {
                    keptRuns.append((cursor, seg.range.endSeconds))
                }

                for run in keptRuns {
                    let kept = seg.subtitles.compactMap { cue -> SubtitleEntry? in
                        if ids.contains(cue.id) { return nil }
                        let cs = base + cue.relativeStart
                        let ce = cs + cue.relativeDuration
                        guard cs >= run.0 - 0.01, ce <= run.1 + 0.01 else { return nil }
                        return SubtitleEntry(
                            id: UUID(),
                            relativeStart: cs - run.0,
                            relativeDuration: cue.relativeDuration,
                            text: cue.text,
                            speakerID: cue.speakerID,
                            translations: cue.translations
                        )
                    }
                    rewritten.append(TimelineSegment(
                        id: UUID(),
                        sourceVideoID: seg.sourceVideoID,
                        range: TimeRange(startSeconds: run.0, endSeconds: run.1),
                        text: seg.text,
                        subtitles: kept,
                        volumeLevel: seg.volumeLevel,
                        isVideoHidden: seg.isVideoHidden,
                        speedRate: seg.speedRate,
                        effects: seg.effects,
                        placementOffset: nil,
                        alternatives: seg.alternatives,
                        linkedSegmentID: nil,
                        pipLayout: seg.pipLayout,
                        freeTransform: seg.freeTransform,
                        overlaySpec: seg.overlaySpec
                    ))
                }
            }
            next[ti].segments = rewritten
        }

        if removed > 0 {
            pushUndoSnapshot()
            tracks = next
            selectedSegmentID = nil
            persistSession()
        }
        return removed
    }

    /// Trim silent source-time spans out of every primary video
    /// segment that references `mediaID`. Used by `smart.trimPauses`
    /// — drops silent gaps detected by `AudioQualityService` without
    /// deleting any spoken content. Ranges are in source-media
    /// seconds (same space as `seg.range`), and only ranges at least
    /// `minDurationSeconds` long are applied so we don't shave off
    /// breath pauses that read as natural.
    ///
    /// Returns the number of segment pieces removed (cumulative
    /// across all primary segments touched), or 0 if nothing changed.
    func trimSilentSourceRanges(
        mediaID: UUID,
        sourceRanges: [ClosedRange<Double>],
        minDurationSeconds: Double = 0.5
    ) -> Int {
        let eligible = sourceRanges
            .filter { $0.upperBound - $0.lowerBound >= minDurationSeconds }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !eligible.isEmpty else { return 0 }

        var next = tracks
        var trimmedPieces = 0
        for ti in next.indices where next[ti].kind == .video {
            var rewritten: [TimelineSegment] = []
            for seg in next[ti].segments {
                guard seg.sourceVideoID == mediaID else {
                    rewritten.append(seg)
                    continue
                }

                // Intersect each silent range with the segment's
                // source window, then merge overlapping intervals.
                var excl: [(Double, Double)] = []
                for r in eligible {
                    let a = max(r.lowerBound, seg.range.startSeconds)
                    let b = min(r.upperBound, seg.range.endSeconds)
                    if b - a >= minDurationSeconds { excl.append((a, b)) }
                }
                if excl.isEmpty {
                    rewritten.append(seg)
                    continue
                }
                excl.sort { $0.0 < $1.0 }
                var merged: [(Double, Double)] = []
                for iv in excl {
                    if let last = merged.last, iv.0 <= last.1 + 0.01 {
                        merged[merged.count - 1].1 = max(last.1, iv.1)
                    } else {
                        merged.append(iv)
                    }
                }
                excl = merged

                var keptRuns: [(Double, Double)] = []
                var cursor = seg.range.startSeconds
                for iv in excl {
                    if iv.0 > cursor + 0.02 {
                        keptRuns.append((cursor, min(iv.0, seg.range.endSeconds)))
                    }
                    cursor = max(cursor, iv.1)
                    if cursor >= seg.range.endSeconds { break }
                }
                if cursor < seg.range.endSeconds - 0.02 {
                    keptRuns.append((cursor, seg.range.endSeconds))
                }

                if keptRuns.isEmpty {
                    // Entire segment was silent — drop it.
                    trimmedPieces += 1
                    continue
                }
                trimmedPieces += excl.count

                let base = seg.range.startSeconds
                for run in keptRuns {
                    let kept = seg.subtitles.compactMap { cue -> SubtitleEntry? in
                        let cs = base + cue.relativeStart
                        let ce = cs + cue.relativeDuration
                        guard cs >= run.0 - 0.01, ce <= run.1 + 0.01 else { return nil }
                        return SubtitleEntry(
                            id: UUID(),
                            relativeStart: cs - run.0,
                            relativeDuration: cue.relativeDuration,
                            text: cue.text,
                            speakerID: cue.speakerID,
                            translations: cue.translations
                        )
                    }
                    rewritten.append(TimelineSegment(
                        id: UUID(),
                        sourceVideoID: seg.sourceVideoID,
                        range: TimeRange(startSeconds: run.0, endSeconds: run.1),
                        text: seg.text,
                        subtitles: kept,
                        volumeLevel: seg.volumeLevel,
                        isVideoHidden: seg.isVideoHidden,
                        speedRate: seg.speedRate,
                        effects: seg.effects,
                        placementOffset: nil,
                        alternatives: seg.alternatives,
                        linkedSegmentID: nil,
                        pipLayout: seg.pipLayout,
                        freeTransform: seg.freeTransform,
                        overlaySpec: seg.overlaySpec
                    ))
                }
            }
            next[ti].segments = rewritten
        }

        if trimmedPieces > 0 {
            pushUndoSnapshot()
            tracks = next
            selectedSegmentID = nil
            persistSession()
        }
        return trimmedPieces
    }

    /// Append an audio-only media file (picked from files/music app, or
    /// captured via the mic) as a new clip on a dedicated audio track.
    /// Placed at the current playhead (via `placementOffset`) so a
    /// voiceover recorded while looking at frame N lands on frame N.
    /// The dedicated audio track is created on first import.
    func importAudio(at sourceURL: URL) async throws {
        let importer = IOSMediaImporter(store: store)
        let record = try await importer.importAudio(from: sourceURL)
        let duration = record.analysis?.durationSeconds ?? 0

        var nextTracks = tracks
        let audioIdx: Int
        if let existing = nextTracks.firstIndex(where: { $0.kind == .audio }) {
            audioIdx = existing
        } else {
            nextTracks.append(Track(kind: .audio, name: "Audio"))
            audioIdx = nextTracks.count - 1
        }
        let segment = TimelineSegment(
            id: UUID(),
            sourceVideoID: record.id,
            range: TimeRange(startSeconds: 0, endSeconds: duration),
            text: sourceURL.deletingPathExtension().lastPathComponent,
            subtitles: [],
            placementOffset: currentTime
        )
        nextTracks[audioIdx].segments.append(segment)

        self.manifest = (try? store.loadManifest()) ?? manifest
        pushUndoSnapshot()
        self.tracks = nextTracks
        persistSession()
    }

    /// Import an audio file as a project-wide BGM track. Mirrors macOS
    /// `addBGMTrack`: lands as its own audio Track named `BGM N`, full
    /// duration, anchored at t=0, default volume 0.3 so it sits under
    /// dialog. Voice-over `importAudio` sticks the file at the playhead
    /// at full volume and shares the existing Audio track — different
    /// intent, so we keep them as separate entry points.
    func importBGM(at sourceURL: URL) async throws {
        let importer = IOSMediaImporter(store: store)
        let record = try await importer.importAudio(from: sourceURL)
        let duration = record.analysis?.durationSeconds ?? 0
        guard duration > 0.05 else { return }

        let segment = TimelineSegment(
            id: UUID(),
            sourceVideoID: record.id,
            range: TimeRange(startSeconds: 0, endSeconds: duration),
            text: "BGM",
            subtitles: [],
            volumeLevel: 0.3,
            placementOffset: 0
        )
        let bgmCount = tracks.filter { $0.kind == .audio && $0.name.hasPrefix("BGM") }.count
        let track = Track(
            kind: .audio,
            name: "BGM \(bgmCount + 1)",
            segments: [segment]
        )

        self.manifest = (try? store.loadManifest()) ?? manifest
        pushUndoSnapshot()
        var next = tracks
        next.append(track)
        self.tracks = next
        persistSession()
    }

    // MARK: - Picture-in-Picture overlay

    /// Import a video as a PiP (picture-in-picture) overlay. Creates (or
    /// reuses) an `.overlay` track and appends a segment anchored at the
    /// current playhead with a default `PiPLayout` (bottom-right, rounded
    /// square, ~22% of canvas height). The segment is auto-selected so
    /// subsequent shape/opacity edits target it.
    func importPiPOverlay(at sourceURL: URL) async throws {
        let importer = IOSMediaImporter(store: store)
        let record = try await importer.importVideo(from: sourceURL)
        let duration = record.analysis?.durationSeconds ?? 0
        // Cap the default PiP clip length at 5s so importing a long
        // video doesn't silently extend the composed timeline.
        let clipEnd = min(duration, 5.0)

        var nextTracks = tracks
        let overlayIdx: Int
        if let existing = nextTracks.firstIndex(where: { $0.kind == .overlay }) {
            overlayIdx = existing
        } else {
            nextTracks.append(Track(kind: .overlay, name: "PiP"))
            overlayIdx = nextTracks.count - 1
        }
        let segment = TimelineSegment(
            id: UUID(),
            sourceVideoID: record.id,
            range: TimeRange(startSeconds: 0, endSeconds: clipEnd),
            text: sourceURL.deletingPathExtension().lastPathComponent,
            subtitles: [],
            placementOffset: currentTime,
            pipLayout: .default
        )
        nextTracks[overlayIdx].segments.append(segment)

        self.manifest = (try? store.loadManifest()) ?? manifest
        pushUndoSnapshot()
        self.tracks = nextTracks
        selectedSegmentID = segment.id
        persistSession()
    }

    /// Cycle the selected PiP segment's mask shape:
    /// circle → roundedSquare → square → circle. No-op if the selection
    /// isn't a PiP segment (no `pipLayout`). Returns true if a shape
    /// change was applied so callers can surface a message on miss.
    @discardableResult
    func cycleSelectedPiPShape() -> Bool {
        guard let id = selectedSegmentID else { return false }
        var next = tracks
        for ti in next.indices {
            guard let si = next[ti].segments.firstIndex(where: { $0.id == id }) else { continue }
            guard var layout = next[ti].segments[si].pipLayout else { return false }
            layout.shape = Self.nextPiPShape(after: layout.shape)
            next[ti].segments[si].pipLayout = layout.normalized()
            pushUndoSnapshot()
            tracks = next
            persistSession()
            return true
        }
        return false
    }

    /// Set the selected PiP segment's opacity (0…1). Stored on
    /// `freeTransform.opacity`; if the segment has no freeTransform yet,
    /// an identity transform is created so opacity can persist. No-op
    /// when the selection isn't a PiP segment.
    @discardableResult
    func setSelectedPiPOpacity(_ opacity: Double) -> Bool {
        guard let id = selectedSegmentID else { return false }
        let clamped = min(1, max(0, opacity))
        var next = tracks
        for ti in next.indices {
            guard let si = next[ti].segments.firstIndex(where: { $0.id == id }) else { continue }
            guard next[ti].segments[si].pipLayout != nil else { return false }
            var ft = next[ti].segments[si].freeTransform ?? .identity
            ft.opacity = clamped
            next[ti].segments[si].freeTransform = ft
            pushUndoSnapshot()
            tracks = next
            persistSession()
            return true
        }
        return false
    }

    /// First pipLayout-bearing segment on any overlay track, used by
    /// the opacity sheet when nothing is explicitly selected.
    var firstPiPSegment: TimelineSegment? {
        for t in tracks where t.kind == .overlay {
            if let s = t.segments.first(where: { $0.pipLayout != nil }) { return s }
        }
        return nil
    }

    /// First overlay segment (any shape), used by the Free Transform
    /// sheet so users can tweak position/scale/rotation even on
    /// overlays that don't have a corner-anchored pipLayout.
    var firstOverlaySegment: TimelineSegment? {
        for t in tracks where t.kind == .overlay {
            if let s = t.segments.first { return s }
        }
        return nil
    }

    /// Apply a freeTransform update via a caller-supplied mutator so
    /// sliders can tweak a single field without clobbering others.
    /// Targets the currently-selected overlay segment; falls back to
    /// `firstOverlaySegment` when no selection exists. Returns true
    /// when a segment was updated. `pushUndo` should be false while
    /// a slider is being dragged and true on the last tick, matching
    /// the PiP opacity sheet's coalescing pattern.
    @discardableResult
    func updateSelectedFreeTransform(
        pushUndo: Bool = true,
        mutate: (inout FreeTransform) -> Void
    ) -> Bool {
        let targetID: UUID? = {
            if let id = selectedSegmentID,
               tracks.contains(where: { t in
                   t.kind == .overlay && t.segments.contains(where: { $0.id == id })
               }) {
                return id
            }
            return firstOverlaySegment?.id
        }()
        guard let id = targetID else { return false }

        var next = tracks
        for ti in next.indices where next[ti].kind == .overlay {
            guard let si = next[ti].segments.firstIndex(where: { $0.id == id }) else { continue }
            var ft = next[ti].segments[si].freeTransform ?? .identity
            mutate(&ft)
            ft.positionX = min(2, max(-1, ft.positionX))
            ft.positionY = min(2, max(-1, ft.positionY))
            ft.scale = min(5, max(0.1, ft.scale))
            ft.opacity = min(1, max(0, ft.opacity))
            // Normalize rotation into [-180, 180] so the slider math stays tame.
            var rot = ft.rotationDegrees.truncatingRemainder(dividingBy: 360)
            if rot > 180 { rot -= 360 }
            if rot < -180 { rot += 360 }
            ft.rotationDegrees = rot
            next[ti].segments[si].freeTransform = ft
            if pushUndo { pushUndoSnapshot() }
            tracks = next
            persistSession()
            return true
        }
        return false
    }

    /// Clear freeTransform on the currently-selected (or first) overlay
    /// segment — used by the sheet's "Reset" button. Always pushes an
    /// undo so a one-tap reset is fully reversible.
    @discardableResult
    func resetSelectedFreeTransform() -> Bool {
        return updateSelectedFreeTransform { ft in
            ft = .identity
        }
    }

    private static func nextPiPShape(after shape: PiPLayout.Shape) -> PiPLayout.Shape {
        switch shape {
        case .circle:        return .roundedSquare
        case .roundedSquare: return .square
        case .square:        return .circle
        }
    }

    private func persistSession() {
        let session = EditorSessionState(
            subtitleStyle: subtitleStyle,
            showSubtitles: showSubtitles,
            lastAutosaveAt: Date(),
            currentTracks: tracks.map(EditorRevision.PersistableTrack.init(from:))
        )
        try? store.saveSessionState(session)
    }

    /// Reposition a detached-audio segment along the timeline by
    /// updating its `placementOffset`. Used by the audio row's drag
    /// gesture — the drag's translation is applied against the
    /// segment's offset at gesture start, then written back here.
    /// Clamped to [0, +inf). Only touches segments on .audio tracks
    /// so dragging can't corrupt the primary video lane. Snapshots
    /// are coalesced via `interactiveEdit` so one drag = one undo.
    func setAudioPlacement(segmentID: UUID, newOffset: Double) {
        var next = tracks
        var changed = false
        for ti in next.indices where next[ti].kind == .audio {
            if let si = next[ti].segments.firstIndex(where: { $0.id == segmentID }) {
                next[ti].segments[si].placementOffset = max(0, newOffset)
                changed = true
                break
            }
        }
        guard changed else { return }
        pushUndoSnapshot()
        tracks = next
        persistSession()
    }

    /// CapCut-style trim on a detached-audio clip. Dragging the left
    /// handle moves both `range.startSeconds` and `placementOffset`
    /// by the same delta so the clip's right edge appears fixed
    /// relative to the timeline; dragging the right handle just
    /// moves `range.endSeconds`. Clamps to the source duration and
    /// 0.1s minimum. Audio tracks only.
    func trimAudioSegment(segmentID: UUID, newStart: Double, newEnd: Double) {
        var next = tracks
        var changed = false
        for ti in next.indices where next[ti].kind == .audio {
            if let si = next[ti].segments.firstIndex(where: { $0.id == segmentID }) {
                let seg = next[ti].segments[si]
                let maxEnd = sourceDuration(for: seg)
                let clampedStart = max(0, min(newStart, maxEnd - 0.1))
                let clampedEnd = max(clampedStart + 0.1, min(newEnd, maxEnd))
                let baseOffset = seg.placementOffset ?? 0
                // Preserve the right-edge timeline position when the
                // left handle moved: shift placementOffset by the
                // same amount the range-start shifted.
                let startDelta = clampedStart - seg.range.startSeconds
                var updated = seg
                updated.range = TimeRange(startSeconds: clampedStart, endSeconds: clampedEnd)
                updated.placementOffset = max(0, baseOffset + startDelta)
                next[ti].segments[si] = updated
                changed = true
                break
            }
        }
        guard changed else { return }
        pushUndoSnapshot()
        tracks = next
        persistSession()
    }
}
