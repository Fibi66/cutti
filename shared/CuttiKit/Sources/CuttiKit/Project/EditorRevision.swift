import Foundation

// MARK: - Editor Revision (Checkpoint)

/// A snapshot of the editor state at a point in time.
/// Every meaningful edit creates a new revision. Users can restore
/// any past revision, which creates a new head (non-destructive).
public struct EditorRevision: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let label: String
    /// Legacy flat list of primary-video-track segments. Still written so
    /// older builds can round-trip a project, and still consumed on
    /// restore when `tracks` is absent (i.e. revisions written before
    /// multitrack support landed).
    public let segments: [PersistableSegment]
    public let selectedSegmentID: UUID?
    public let playheadSeconds: Double
    public let trigger: RevisionTrigger
    /// Full multitrack snapshot — primary video track plus any aux audio
    /// or overlay tracks. Optional for backward compatibility: revisions
    /// written before multitrack shipped won't have this field, and
    /// `restore` falls back to the flat `segments` array in that case.
    public let tracks: [PersistableTrack]?
    /// Soft-deleted subtitle cues at the moment this revision was
    /// snapshotted. Optional for backward compatibility — revisions
    /// predating transcript-driven delete won't have the field and
    /// decode to `nil`, which restore treats as "no tombstones".
    public let subtitleTombstones: [SubtitleTombstone]?
    /// Project-wide subtitle style at the moment this revision was
    /// snapshotted. Optional for backward compatibility — revisions
    /// predating this field decode to nil, which `restore` treats as
    /// "do not touch the current style". Captured so revision-driven
    /// edits that mutate the global style (notably the Inspector's
    /// "Apply to all cues" button, and AI `setSubtitleStyle` actions)
    /// round-trip correctly through Cmd+Z.
    public let subtitleStyle: SubtitleStyle?

    public init(
        id: UUID,
        timestamp: Date,
        label: String,
        segments: [PersistableSegment],
        selectedSegmentID: UUID?,
        playheadSeconds: Double,
        trigger: RevisionTrigger,
        tracks: [PersistableTrack]? = nil,
        subtitleTombstones: [SubtitleTombstone]? = nil,
        subtitleStyle: SubtitleStyle? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.label = label
        self.segments = segments
        self.selectedSegmentID = selectedSegmentID
        self.playheadSeconds = playheadSeconds
        self.trigger = trigger
        self.tracks = tracks
        self.subtitleTombstones = subtitleTombstones
        self.subtitleStyle = subtitleStyle
    }

    public enum CodingKeys: String, CodingKey {
        case id, timestamp, label, segments, selectedSegmentID, playheadSeconds, trigger, tracks, subtitleTombstones, subtitleStyle
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        label = try c.decode(String.self, forKey: .label)
        segments = try c.decode([PersistableSegment].self, forKey: .segments)
        selectedSegmentID = try c.decodeIfPresent(UUID.self, forKey: .selectedSegmentID)
        playheadSeconds = try c.decodeIfPresent(Double.self, forKey: .playheadSeconds) ?? 0
        trigger = try c.decode(RevisionTrigger.self, forKey: .trigger)
        tracks = try c.decodeIfPresent([PersistableTrack].self, forKey: .tracks)
        subtitleTombstones = try c.decodeIfPresent([SubtitleTombstone].self, forKey: .subtitleTombstones)
        subtitleStyle = try c.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle)
    }

    /// Lightweight segment representation for persistence.
    /// Avoids storing full SubtitleEntry arrays in every revision.
    public struct PersistableSegment: Codable, Sendable {
        public let id: UUID
        public let sourceVideoID: UUID
        public let startSeconds: Double
        public let endSeconds: Double
        public let text: String
        public let volumeLevel: Double
        public let speedRate: Double
        /// Persisted so diarization survives revision restore.
        public let subtitles: [PersistableSubtitle]?
        /// Composed-time anchor for overlay-track segments (and any
        /// gapped primary segments). Nil means "flow from the previous
        /// segment / track start" — preserved on round-trip so undo
        /// doesn't silently reset an overlay's position to t=0.
        public let placementOffset: Double?
        /// Persisted so hidden-video state survives undo/redo and
        /// project reopen. Optional for back-compat with revisions
        /// written before this flag existed.
        public let isVideoHidden: Bool?
        /// Alternate equivalent takes carried alongside the primary
        /// segment. Optional for back-compat with revisions written
        /// before the feature existed.
        public let alternatives: [AlternativeTake]?
        /// Two-way audio-detach link between a V1 clip and its mirror
        /// aux-audio segment on A2. Optional for back-compat with
        /// revisions written before the feature existed.
        public let linkedSegmentID: UUID?
        /// Picture-in-Picture overlay layout. Optional for back-compat
        /// with revisions written before the feature existed; nil on
        /// primary-track segments and on overlay segments that should
        /// fully cover V1.
        public let pipLayout: PiPLayout?
        /// AI-generated overlay spec (template + props). Nil for all
        /// non-overlay and non-AI-generated segments. Optional for
        /// back-compat with revisions written before the feature
        /// existed.
        public let overlaySpec: OverlayRenderSpec?

        enum CodingKeys: String, CodingKey {
            case id, sourceVideoID, startSeconds, endSeconds, text, volumeLevel, speedRate, subtitles, placementOffset, isVideoHidden, alternatives, linkedSegmentID, pipLayout, overlaySpec
        }

        public init(from segment: TimelineSegment) {
            self.id = segment.id
            self.sourceVideoID = segment.sourceVideoID
            self.startSeconds = segment.range.startSeconds
            self.endSeconds = segment.range.endSeconds
            self.text = segment.text
            self.volumeLevel = segment.volumeLevel
            self.speedRate = segment.speedRate
            self.subtitles = segment.subtitles.map(PersistableSubtitle.init(from:))
            self.placementOffset = segment.placementOffset
            self.isVideoHidden = segment.isVideoHidden ? true : nil
            self.alternatives = segment.alternatives.isEmpty ? nil : segment.alternatives
            self.linkedSegmentID = segment.linkedSegmentID
            self.pipLayout = segment.pipLayout
            self.overlaySpec = segment.overlaySpec
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sourceVideoID = try container.decode(UUID.self, forKey: .sourceVideoID)
            startSeconds = try container.decode(Double.self, forKey: .startSeconds)
            endSeconds = try container.decode(Double.self, forKey: .endSeconds)
            text = try container.decode(String.self, forKey: .text)
            volumeLevel = try container.decode(Double.self, forKey: .volumeLevel)
            speedRate = try container.decodeIfPresent(Double.self, forKey: .speedRate) ?? 1.0
            subtitles = try container.decodeIfPresent([PersistableSubtitle].self, forKey: .subtitles)
            placementOffset = try container.decodeIfPresent(Double.self, forKey: .placementOffset)
            isVideoHidden = try container.decodeIfPresent(Bool.self, forKey: .isVideoHidden)
            alternatives = try container.decodeIfPresent([AlternativeTake].self, forKey: .alternatives)
            linkedSegmentID = try container.decodeIfPresent(UUID.self, forKey: .linkedSegmentID)
            pipLayout = try container.decodeIfPresent(PiPLayout.self, forKey: .pipLayout)
            overlaySpec = try container.decodeIfPresent(OverlayRenderSpec.self, forKey: .overlaySpec)
        }

        public func toTimelineSegment(subtitles fallback: [SubtitleEntry] = []) -> TimelineSegment {
            let subs: [SubtitleEntry]
            if let persisted = self.subtitles {
                subs = persisted.map { $0.toSubtitleEntry() }
            } else {
                subs = fallback
            }
            var seg = TimelineSegment(
                id: id,
                sourceVideoID: sourceVideoID,
                range: TimeRange(startSeconds: startSeconds, endSeconds: endSeconds),
                text: text,
                subtitles: subs,
                placementOffset: placementOffset
            )
            seg.volumeLevel = volumeLevel
            seg.speedRate = speedRate
            seg.isVideoHidden = isVideoHidden ?? false
            seg.alternatives = alternatives ?? []
            seg.linkedSegmentID = linkedSegmentID
            seg.pipLayout = pipLayout?.normalized()
            seg.overlaySpec = overlaySpec
            return seg
        }
    }

    public struct PersistableSubtitle: Codable, Sendable {
        public let id: UUID
        public let relativeStart: Double
        public let relativeDuration: Double
        public let text: String
        public let speakerID: Int?
        /// BCP-47-keyed translations persisted alongside the source-
        /// language text. Optional for back-compat with revisions
        /// written before the bilingual feature existed — a missing
        /// field rehydrates as an empty translation dict on the
        /// `SubtitleEntry`.
        public let translations: [String: String]?
        /// Optional per-run rich-text styling. Missing field rehydrates
        /// as nil on the `SubtitleEntry`, which renders identically to
        /// plain cue text — back-compat for every revision written
        /// before the rich-text feature landed.
        public let runs: [SubtitleRun]?
        /// Optional per-word timestamps for karaoke rendering. Missing
        /// field rehydrates as nil — back-compat for every revision
        /// written before the karaoke feature landed; such cues will
        /// render uniformly (no word-level pill sweep) until the owning
        /// audio is re-transcribed with word timestamps enabled.
        public let wordTimings: [WordTiming]?
        /// Optional per-cue visual style override. Missing field
        /// rehydrates as nil — back-compat for every revision written
        /// before per-cue style overrides landed; such cues render
        /// using the project-wide `SubtitleStyle` exactly as before.
        public let styleOverride: SubtitleCueStyleOverride?

        enum CodingKeys: String, CodingKey {
            case id, relativeStart, relativeDuration, text, speakerID, translations, runs, wordTimings, styleOverride
        }

        public init(from entry: SubtitleEntry) {
            self.id = entry.id
            self.relativeStart = entry.relativeStart
            self.relativeDuration = entry.relativeDuration
            self.text = entry.text
            self.speakerID = entry.speakerID
            self.translations = entry.translations.isEmpty ? nil : entry.translations
            self.runs = entry.runs
            self.wordTimings = entry.wordTimings
            // Persist nil for empty overrides so revisions stay
            // bit-identical to pre-feature ones when no cue is
            // customized — keeps diffs and migration audits clean.
            self.styleOverride = (entry.styleOverride?.hasAnyField == true) ? entry.styleOverride : nil
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            relativeStart = try c.decode(Double.self, forKey: .relativeStart)
            relativeDuration = try c.decode(Double.self, forKey: .relativeDuration)
            text = try c.decode(String.self, forKey: .text)
            speakerID = try c.decodeIfPresent(Int.self, forKey: .speakerID)
            translations = try c.decodeIfPresent([String: String].self, forKey: .translations)
            runs = try c.decodeIfPresent([SubtitleRun].self, forKey: .runs)
            wordTimings = try c.decodeIfPresent([WordTiming].self, forKey: .wordTimings)
            styleOverride = try c.decodeIfPresent(SubtitleCueStyleOverride.self, forKey: .styleOverride)
        }

        public func toSubtitleEntry() -> SubtitleEntry {
            SubtitleEntry(
                id: id,
                relativeStart: relativeStart,
                relativeDuration: relativeDuration,
                text: text,
                speakerID: speakerID,
                translations: translations ?? [:],
                runs: runs,
                wordTimings: wordTimings,
                styleOverride: styleOverride
            )
        }
    }

    public struct PersistableTrack: Codable, Sendable {
        public let id: UUID
        public let kind: String      // "video" | "audio" | "overlay"
        public let name: String
        public let isMuted: Bool
        public let isSolo: Bool
        /// Optional so older manifests (pre-lock) decode cleanly.
        public let isLocked: Bool?
        public let segments: [PersistableSegment]

        public init(from track: Track) {
            self.id = track.id
            self.kind = track.kind.rawValue
            self.name = track.name
            self.isMuted = track.isMuted
            self.isSolo = track.isSolo
            self.isLocked = track.isLocked
            self.segments = track.segments.map(PersistableSegment.init(from:))
        }

        public func toTrack() -> Track {
            let resolvedKind = TrackKind(rawValue: kind) ?? .video
            return Track(
                id: id,
                kind: resolvedKind,
                name: name,
                isMuted: isMuted,
                isSolo: isSolo,
                isLocked: isLocked ?? false,
                segments: segments.map { $0.toTimelineSegment() }
            )
        }
    }
}

// MARK: - Revision Trigger

/// What caused this revision to be created.
public enum RevisionTrigger: Codable, Sendable {
    case analysis
    case aiAction(messageID: UUID)
    case userEdit(description: String)
    case restore(fromRevisionID: UUID)
    case importMedia
    /// Periodic autosave snapshot. Distinguished from userEdit so the UI
    /// can hide/collapse these in the revision list if desired.
    case autosave
    /// Explicit user-triggered save (⌘S). Like autosave but surfaced in
    /// the revision history as a prominent, user-authored checkpoint.
    case manualSave
}

// MARK: - Revision Store

/// Persists revision history per project as a JSON file.
public actor RevisionStore {
    private let fileURL: URL
    private var revisions: [EditorRevision] = []
    private let maxRevisions = 200

    public init(projectRoot: URL) {
        self.fileURL = projectRoot.appending(path: "media/revisions.json")
    }

    /// Load revisions from disk.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            revisions = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        revisions = try decoder.decode([EditorRevision].self, from: data)
    }

    /// Save revisions to disk.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(revisions)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Add a new revision and persist.
    public func push(_ revision: EditorRevision) throws {
        revisions.append(revision)

        // Auto-prune: keep only the most recent N revisions
        if revisions.count > maxRevisions {
            revisions = Array(revisions.suffix(maxRevisions))
        }

        try save()
    }

    /// Get all revisions (newest last).
    public func all() -> [EditorRevision] {
        revisions
    }

    /// Get a specific revision by ID.
    public func get(id: UUID) -> EditorRevision? {
        revisions.first { $0.id == id }
    }

    /// Get the most recent revision.
    public func latest() -> EditorRevision? {
        revisions.last
    }

    /// Clear all revisions.
    public func clear() throws {
        revisions = []
        try save()
    }
}
