import Foundation
import CuttiKit

/// Maps visual-analysis findings from source-video time into the
/// composed timeline, and exposes them as Agent tools. Each source
/// video has its own `VisualIndex` cache (see VisualIndexStore); the
/// mapping here is pure — it takes the indices + current segments
/// and produces composed-time matches the Agent can delete / skip.
enum VisualAgentQuery {

    struct CueMatch: Codable, Equatable {
        /// Index in the timelineSegments array — stable across a single
        /// tool call but not across edits.
        let segmentIndex: Int
        /// Composed-time (final-video) start seconds.
        let composedStart: Double
        /// Composed-time end seconds.
        let composedEnd: Double
        /// Source-video seconds [start, end) that matched.
        let sourceStart: Double
        let sourceEnd: Double
        /// Kind of visual anomaly — "black", "no_face", "scene_change".
        let kind: String
    }

    /// Map a single source-time range (in the source video of
    /// `segment.sourceVideoID`) to a composed-time range, clipped to
    /// the portion that actually survives in `segment`. Returns nil
    /// when the range doesn't intersect the segment.
    static func mapToComposed(
        sourceRange: (start: Double, end: Double),
        segment: TimelineSegment,
        composedStart: Double
    ) -> (start: Double, end: Double)? {
        let clipStart = max(sourceRange.start, segment.range.startSeconds)
        let clipEnd = min(sourceRange.end, segment.range.endSeconds)
        guard clipEnd > clipStart + 0.001 else { return nil }
        let relStart = (clipStart - segment.range.startSeconds) / segment.normalizedSpeedRate
        let relEnd = (clipEnd - segment.range.startSeconds) / segment.normalizedSpeedRate
        return (composedStart + relStart, composedStart + relEnd)
    }

    /// Find all composed-time ranges inside `segments` that fall inside a
    /// black-frame range of the corresponding source video. Segments
    /// whose source has no index in `indices` are skipped.
    static func findBlackFrames(
        segments: [TimelineSegment],
        indices: [UUID: VisualIndex]
    ) -> [CueMatch] {
        return collectMatches(
            segments: segments,
            indices: indices,
            kind: "black",
            ranges: { $0.blackFrameRanges.map { (start: $0.start, end: $0.end) } }
        )
    }

    /// Find composed-time ranges with no face detected.
    static func findEmptyFrames(
        segments: [TimelineSegment],
        indices: [UUID: VisualIndex]
    ) -> [CueMatch] {
        return collectMatches(
            segments: segments,
            indices: indices,
            kind: "no_face",
            ranges: { $0.emptyFrameRanges.map { (start: $0.start, end: $0.end) } }
        )
    }

    /// Find composed-time points where the source video has a scene
    /// change. Emits 0.25s-wide windows around each timestamp so the
    /// Agent can address them as ranges rather than instants.
    static func findSceneChanges(
        segments: [TimelineSegment],
        indices: [UUID: VisualIndex]
    ) -> [CueMatch] {
        let window = 0.25
        return collectMatches(
            segments: segments,
            indices: indices,
            kind: "scene_change",
            ranges: { index in
                index.sceneChangeTimestamps.map { (start: max(0, $0 - window / 2), end: $0 + window / 2) }
            }
        )
    }

    private static func collectMatches(
        segments: [TimelineSegment],
        indices: [UUID: VisualIndex],
        kind: String,
        ranges: (VisualIndex) -> [(start: Double, end: Double)]
    ) -> [CueMatch] {
        var matches: [CueMatch] = []
        var cursor: Double = 0
        for (i, seg) in segments.enumerated() {
            let composedStart = cursor
            cursor += seg.durationSeconds
            guard let index = indices[seg.sourceVideoID] else { continue }
            for r in ranges(index) {
                if let composed = mapToComposed(sourceRange: r, segment: seg, composedStart: composedStart) {
                    matches.append(CueMatch(
                        segmentIndex: i,
                        composedStart: composed.start,
                        composedEnd: composed.end,
                        sourceStart: max(r.start, seg.range.startSeconds),
                        sourceEnd: min(r.end, seg.range.endSeconds),
                        kind: kind
                    ))
                }
            }
        }
        return matches
    }

    // MARK: - Tool definitions

    static let findBlackFramesTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "find_black_frames",
            description: "Scan the current timeline for composed-time ranges whose underlying source video is nearly black (fade-outs, accidental lens cap moments, missing footage). Uses a cached visual index; fast on repeat calls. Returns composed_start/composed_end for each match so you can hand them directly to edit_timeline.delete_range.",
            parameters: .init(
                type: "object",
                properties: [:],
                required: nil,
                items: nil
            )
        )
    )

    static let findEmptyFramesTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "find_empty_frames",
            description: "Find composed-time ranges where no human face is visible in the source video — useful when the user is editing a talking-head / interview piece and wants to cut away to B-roll or trim dead air.",
            parameters: .init(
                type: "object",
                properties: [:],
                required: nil,
                items: nil
            )
        )
    )

    static let findSceneChangesTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "find_scene_changes",
            description: "Return composed-time points where the source video has a visual scene change (large frame-to-frame luminance shift). Emits short windows around each change; use to suggest natural cut points.",
            parameters: .init(
                type: "object",
                properties: [:],
                required: nil,
                items: nil
            )
        )
    )

    /// Auto Picture-in-Picture: run on-device Vision (face detection +
    /// saliency) over every overlay clip that doesn't already have a
    /// PiP layout and, when a clip looks like a presenter-cam, place it
    /// as a tidy corner Picture-in-Picture. Apply this when the user
    /// describes the classic "slides + webcam" setup or asks to turn an
    /// overlay into a corner headshot, even if they don't say "PiP".
    static let autoPiPTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "auto_pip",
            description: "Run on-device Vision analysis (face detection + saliency) across every overlay clip that does not yet have a Picture-in-Picture layout, and for each clip that looks like a presenter-cam (a face roughly centered in the frame) auto-place it as a corner PiP over the underlying primary video. Returns how many overlays were analyzed and how many qualified. Call this when the user asks for a picture-in-picture, corner headshot, talking-head overlay, webcam bubble, or any variant of the 'slides plus talking head' layout. No arguments — runs across all eligible overlays.",
            parameters: .init(
                type: "object",
                properties: [:],
                required: nil,
                items: nil
            )
        )
    )
}

// MARK: - Visual index persistence

/// On-disk cache of per-video `VisualIndex` blobs. Keyed by source
/// video UUID; stored as `<projectRoot>/media/visual_index/<id>.json`.
/// Missing files are treated as "not yet analysed" — caller runs
/// `VisualAnalysisService.analyze` and passes the result back via
/// `save`.
enum VisualIndexStore {

    static func indexURL(projectRoot: URL, videoID: UUID) -> URL {
        projectRoot
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent("visual_index", isDirectory: true)
            .appendingPathComponent("\(videoID.uuidString).json")
    }

    static func load(projectRoot: URL, videoID: UUID) -> VisualIndex? {
        let url = indexURL(projectRoot: projectRoot, videoID: videoID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VisualIndex.self, from: data)
    }

    static func save(_ index: VisualIndex, projectRoot: URL, videoID: UUID) throws {
        let url = indexURL(projectRoot: projectRoot, videoID: videoID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(index)
        try data.write(to: url, options: .atomic)
    }
}
