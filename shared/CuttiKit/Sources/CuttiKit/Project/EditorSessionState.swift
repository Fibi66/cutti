import Foundation

/// Lightweight session state that isn't captured by `MediaManifest` or the
/// revision store: subtitle presentation preferences and the timestamp of
/// the last autosave. Persisted at `media/session.json` so it survives
/// restarts without bloating the revision history.
public struct EditorSessionState: Codable, Equatable, Sendable {
    public var subtitleStyle: SubtitleStyle
    public var showSubtitles: Bool
    public var lastAutosaveAt: Date?
    /// Live multi-track snapshot of the editor state. The revision
    /// store captures *pre-edit* history for Cmd+Z; `currentTracks`
    /// captures the user's *current* working state so every manual
    /// edit (subtitle text, split, trim, volume, effects…) survives
    /// project reopen. Nil on a fresh project (falls back to
    /// `MediaCoreViewModel.rebuildTimelineSegments` from keptRanges).
    public var currentTracks: [EditorRevision.PersistableTrack]?
    /// Soft-deleted subtitle cues: the user removed the video for
    /// these ranges via the transcript editor but asked to keep the
    /// text visible with strikethrough. Persisted here so reopening
    /// the project still shows the deleted words.
    public var subtitleTombstones: [SubtitleTombstone]

    public static let `default` = EditorSessionState(
        subtitleStyle: .default,
        showSubtitles: true,
        lastAutosaveAt: nil,
        currentTracks: nil,
        subtitleTombstones: []
    )

    public enum CodingKeys: String, CodingKey {
        case subtitleStyle, showSubtitles, lastAutosaveAt, currentTracks, subtitleTombstones
    }

    public init(
        subtitleStyle: SubtitleStyle,
        showSubtitles: Bool,
        lastAutosaveAt: Date?,
        currentTracks: [EditorRevision.PersistableTrack]? = nil,
        subtitleTombstones: [SubtitleTombstone] = []
    ) {
        self.subtitleStyle = subtitleStyle
        self.showSubtitles = showSubtitles
        self.lastAutosaveAt = lastAutosaveAt
        self.currentTracks = currentTracks
        self.subtitleTombstones = subtitleTombstones
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.subtitleStyle = try c.decode(SubtitleStyle.self, forKey: .subtitleStyle)
        self.showSubtitles = try c.decode(Bool.self, forKey: .showSubtitles)
        self.lastAutosaveAt = try c.decodeIfPresent(Date.self, forKey: .lastAutosaveAt)
        self.currentTracks = try c.decodeIfPresent([EditorRevision.PersistableTrack].self, forKey: .currentTracks)
        self.subtitleTombstones = try c.decodeIfPresent([SubtitleTombstone].self, forKey: .subtitleTombstones) ?? []
    }

    // Dirtiness is computed on the fields we care about; PersistableTrack
    // is deliberately NOT Equatable (too many nested Codable-only types),
    // so we ignore it in `==`. `MediaCoreViewModel.performAutosave` uses
    // its own `lastAutosavedSegments` comparison for timeline dirtiness.
    public static func == (lhs: EditorSessionState, rhs: EditorSessionState) -> Bool {
        lhs.subtitleStyle == rhs.subtitleStyle
            && lhs.showSubtitles == rhs.showSubtitles
            && lhs.lastAutosaveAt == rhs.lastAutosaveAt
            && lhs.subtitleTombstones == rhs.subtitleTombstones
    }
}

public extension ProjectStore {
    public var sessionURL: URL {
        projectRoot.appending(path: "media/session.json")
    }

    public func loadSessionState() -> EditorSessionState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionURL.path),
              let data = try? Data(contentsOf: sessionURL) else {
            return .default
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // If decoding fails (e.g. schema migration), fall back to defaults
        // rather than crashing or losing the ability to launch.
        return (try? decoder.decode(EditorSessionState.self, from: data)) ?? .default
    }

    public func saveSessionState(_ state: EditorSessionState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        // Ensure parent dir exists (loadManifest may have been called but
        // bootstrapProject may not have run yet for some test paths).
        let parent = sessionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: sessionURL, options: .atomic)
    }
}
