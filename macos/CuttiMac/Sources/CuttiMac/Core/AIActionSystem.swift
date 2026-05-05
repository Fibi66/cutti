import Foundation
import CuttiKit

// MARK: - Tool Definition + Parsing

extension AIAction {
    /// Tool definition for the editing agent.
    static let editTimelineToolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "edit_timeline",
            description: "Apply one or more deterministic timeline or subtitle edits. Use delete_range and set_speed_range when the user refers to final-video time ranges. Use insert_source_clip to splice a slice of an arbitrary source recording (any record from the project library, not just clips already on the timeline) into the timeline at a composed-time anchor — this powers cold-open hook teasers and callbacks. Subtitle actions: edit_subtitle (change one cue's text — pass subtitle_id or at_time), replace_subtitle_text (batch find/replace), set_subtitle_style (adjust font size / colors / position / bilingual display — any subset of fields; use the `bilingual_*` fields to turn the secondary translation line on/off and lay it out), set_subtitles_visible (toggle overlay). For bilingual subtitles, always call `translate_subtitles` first to populate the translations, then use set_subtitle_style with `bilingual=true` and `bilingual_secondary_locale` matching the translate target.",
            parameters: .init(
                type: "object",
                properties: [
                    "explanation": .init(
                        type: "string",
                        description: "Brief explanation of what you are changing and why.",
                        items: nil
                    ),
                    "actions": .init(
                        type: "array",
                        description: "Editing actions to apply in order.",
                        items: .init(
                            type: "object",
                            properties: [
                                "type": .init(
                                    type: "string",
                                    description: "Action type: delete, delete_range, split, trim_start, trim_end, set_volume, set_speed, set_speed_range, reorder_segments, insert_source_clip, edit_subtitle, replace_subtitle_text, set_subtitle_style, or set_subtitles_visible.",
                                    items: nil
                                ),
                                "segment_id": .init(
                                    type: "string",
                                    description: "Target segment UUID for segment-based edits.",
                                    items: nil
                                ),
                                "value": .init(
                                    type: "number",
                                    description: "Generic numeric value for split, trim, or volume when applicable.",
                                    items: nil
                                ),
                                "start_time": .init(
                                    type: "number",
                                    description: "Start time in composed timeline seconds.",
                                    items: nil
                                ),
                                "end_time": .init(
                                    type: "number",
                                    description: "End time in composed timeline seconds.",
                                    items: nil
                                ),
                                "rate": .init(
                                    type: "number",
                                    description: "Playback speed, where 1.0 is normal and 2.0 is 2x faster.",
                                    items: nil
                                ),
                                "segment_ids": .init(
                                    type: "array",
                                    description: "Full ordered list of segment UUIDs for reorder_segments. Must contain every current segment exactly once — call get_timeline_summary first to discover them.",
                                    items: .init(type: "string", properties: nil, required: nil)
                                ),
                                "source_video_id": .init(
                                    type: "string",
                                    description: "For insert_source_clip: UUID of the source media record to slice from. Must reference a record present in the project library — call get_timeline_summary or score_hook_candidates first to discover valid IDs.",
                                    items: nil
                                ),
                                "source_start": .init(
                                    type: "number",
                                    description: "For insert_source_clip: start time in source-recording seconds.",
                                    items: nil
                                ),
                                "source_end": .init(
                                    type: "number",
                                    description: "For insert_source_clip: end time in source-recording seconds. Must be > source_start and at least 0.2s longer.",
                                    items: nil
                                ),
                                "composed_insert_at": .init(
                                    type: "number",
                                    description: "For insert_source_clip: composed-timeline second to splice the new clip at. 0 prepends before everything (cold-open hook teaser); the current timeline length appends; values strictly inside an existing segment split it cleanly.",
                                    items: nil
                                ),
                                "fade_in_seconds": .init(
                                    type: "number",
                                    description: "For insert_source_clip: audio fade-in duration in seconds (0 disables). Recommend 0.15s for a hook teaser.",
                                    items: nil
                                ),
                                "fade_out_seconds": .init(
                                    type: "number",
                                    description: "For insert_source_clip: audio fade-out duration in seconds (0 disables). Recommend 0.30s for a hook teaser.",
                                    items: nil
                                ),
                                "subtitle_id": .init(
                                    type: "string",
                                    description: "Target subtitle cue UUID for edit_subtitle. Prefer this over at_time when known.",
                                    items: nil
                                ),
                                "at_time": .init(
                                    type: "number",
                                    description: "Composed timeline seconds. Used by edit_subtitle to locate the cue playing at that moment when subtitle_id is unknown.",
                                    items: nil
                                ),
                                "new_text": .init(
                                    type: "string",
                                    description: "New subtitle text for edit_subtitle.",
                                    items: nil
                                ),
                                "find": .init(
                                    type: "string",
                                    description: "Search string (or regex pattern when is_regex=true) for replace_subtitle_text.",
                                    items: nil
                                ),
                                "replace_with": .init(
                                    type: "string",
                                    description: "Replacement string for replace_subtitle_text. May reference regex capture groups with $1, $2, etc.",
                                    items: nil
                                ),
                                "is_regex": .init(
                                    type: "boolean",
                                    description: "Treat the find string as an ICU regex pattern.",
                                    items: nil
                                ),
                                "font_size_points": .init(
                                    type: "number",
                                    description: "Subtitle font size in points at 1080p (clamped 12–200).",
                                    items: nil
                                ),
                                "font_name": .init(
                                    type: "string",
                                    description: "Subtitle font family (e.g. \"Helvetica Neue\").",
                                    items: nil
                                ),
                                "text_color": .init(
                                    type: "string",
                                    description: "Subtitle text color as #RRGGBB or #RRGGBBAA hex.",
                                    items: nil
                                ),
                                "background_color": .init(
                                    type: "string",
                                    description: "Subtitle background color as #RRGGBB or #RRGGBBAA hex.",
                                    items: nil
                                ),
                                "background_opacity": .init(
                                    type: "number",
                                    description: "Subtitle background alpha 0.0–1.0. 0 = fully transparent (no background).",
                                    items: nil
                                ),
                                "max_width_fraction": .init(
                                    type: "number",
                                    description: "Max subtitle box width as fraction of frame width (0.1–1.0).",
                                    items: nil
                                ),
                                "vertical_position_fraction": .init(
                                    type: "number",
                                    description: "Subtitle vertical position, 0 = top, 1 = bottom.",
                                    items: nil
                                ),
                                "horizontal_position_fraction": .init(
                                    type: "number",
                                    description: "Subtitle horizontal center, 0 = left, 1 = right (default 0.5).",
                                    items: nil
                                ),
                                "alignment": .init(
                                    type: "string",
                                    description: "Subtitle text alignment: leading, center, or trailing.",
                                    items: nil
                                ),
                                "bilingual": .init(
                                    type: "boolean",
                                    description: "Enable (true) or disable (false) bilingual two-line subtitles. When enabling, also pass `bilingual_secondary_locale` (must match the locale previously populated via `translate_subtitles`). Disabling drops the translation line and returns to single-line rendering.",
                                    items: nil
                                ),
                                "bilingual_primary_locale": .init(
                                    type: "string",
                                    description: "Optional BCP-47 tag of the primary (source) language — informational metadata only (the renderer keys off `bilingual_secondary_locale`). Example: \"en-US\".",
                                    items: nil
                                ),
                                "bilingual_secondary_locale": .init(
                                    type: "string",
                                    description: "BCP-47 tag of the translation language to render on the secondary line (e.g. \"zh-Hans\", \"ja\", \"en-US\"). Required when enabling bilingual. Must exactly match the `target_locale` used in a prior `translate_subtitles` call or the secondary line will be blank.",
                                    items: nil
                                ),
                                "bilingual_secondary_size_ratio": .init(
                                    type: "number",
                                    description: "Secondary line font size as a fraction of the primary (clamped 0.4–1.0). Defaults to 0.75. Smaller values visually demote the translation.",
                                    items: nil
                                ),
                                "bilingual_line_spacing_fraction": .init(
                                    type: "number",
                                    description: "Vertical gap between the two bilingual lines, as a fraction of the primary font size (clamped 0.0–1.0). Defaults to 0.18.",
                                    items: nil
                                ),
                                "bilingual_placement": .init(
                                    type: "string",
                                    description: "Where the secondary (translation) line sits relative to the primary. `below` = translation under primary (default, matches Chinese-under-English convention). `above` = translation above primary.",
                                    items: nil
                                ),
                                "visible": .init(
                                    type: "boolean",
                                    description: "Whether to show subtitles (set_subtitles_visible).",
                                    items: nil
                                )
                            ],
                            required: ["type"]
                        )
                    )
                ],
                required: ["explanation", "actions"],
                items: nil
            )
        )
    )

    /// Parse an AIActionBatch from LLM function call arguments.
    static func parseBatch(from arguments: [String: Any]) -> AIActionBatch? {
        guard let explanation = arguments["explanation"] as? String,
              let rawActions = arguments["actions"] as? [[String: Any]] else {
            return nil
        }

        var actions: [AIAction] = []
        for raw in rawActions {
            guard let type = raw["type"] as? String else { continue }

            let segmentID = (raw["segment_id"] as? String).flatMap(UUID.init(uuidString:))
            let value = number(raw["value"])
            let startTime = number(raw["start_time"])
            let endTime = number(raw["end_time"])
            let rate = number(raw["rate"]) ?? value

            switch type {
            case "delete":
                guard let segmentID else { continue }
                actions.append(.deleteSegment(id: segmentID))

            case "delete_range":
                guard let startTime, let endTime else { continue }
                actions.append(.deleteRange(start: startTime, end: endTime))

            case "split":
                guard let segmentID, let time = value else { continue }
                actions.append(.splitSegment(id: segmentID, atSourceTime: time))

            case "trim_start":
                guard let segmentID, let newStart = value else { continue }
                actions.append(.trimStart(id: segmentID, newStart: newStart))

            case "trim_end":
                guard let segmentID, let newEnd = value else { continue }
                actions.append(.trimEnd(id: segmentID, newEnd: newEnd))

            case "set_volume":
                guard let segmentID, let level = value else { continue }
                actions.append(.setVolume(id: segmentID, level: level))

            case "set_speed":
                guard let segmentID, let rate else { continue }
                actions.append(.setSpeed(id: segmentID, rate: rate))

            case "set_speed_range":
                guard let startTime, let endTime, let rate else { continue }
                actions.append(.setSpeedRange(start: startTime, end: endTime, rate: rate))

            case "reorder_segments":
                // The validator rejects partial lists — the LLM is
                // expected to call get_timeline_summary first, take
                // the complete segment id list, and emit it reordered
                // (e.g. pulling the "pricing" segment to the front to
                // make it the intro).
                guard let rawIDs = raw["segment_ids"] as? [String] else { continue }
                let ids = rawIDs.compactMap(UUID.init(uuidString:))
                guard !ids.isEmpty else { continue }
                actions.append(.reorderSegments(ids: ids))

            case "insert_source_clip":
                // composed_insert_at is intentionally required (no
                // parser-side default) so an omitted argument fails
                // loudly instead of silently prepending. The validator
                // surfaces the schema violation back to the LLM.
                guard let sourceIDString = raw["source_video_id"] as? String,
                      let sourceVideoID = UUID(uuidString: sourceIDString) else { continue }
                guard let srcStart = number(raw["source_start"]),
                      let srcEnd = number(raw["source_end"]),
                      let insertAt = number(raw["composed_insert_at"]) else { continue }
                let fadeIn = number(raw["fade_in_seconds"]) ?? 0.15
                let fadeOut = number(raw["fade_out_seconds"]) ?? 0.30
                actions.append(.insertSourceClip(
                    sourceVideoID: sourceVideoID,
                    sourceStart: srcStart,
                    sourceEnd: srcEnd,
                    composedInsertAt: insertAt,
                    fadeInSeconds: fadeIn,
                    fadeOutSeconds: fadeOut
                ))

            case "edit_subtitle":
                let subID = (raw["subtitle_id"] as? String).flatMap(UUID.init(uuidString:))
                let atTime = number(raw["at_time"])
                guard let newText = raw["new_text"] as? String else { continue }
                guard subID != nil || atTime != nil else { continue }
                actions.append(.editSubtitle(id: subID, atSeconds: atTime, newText: newText))

            case "replace_subtitle_text":
                guard let find = raw["find"] as? String, !find.isEmpty else { continue }
                let replaceWith = (raw["replace_with"] as? String) ?? ""
                let isRegex = (raw["is_regex"] as? Bool) ?? false
                actions.append(.replaceSubtitleText(find: find, replaceWith: replaceWith, isRegex: isRegex))

            case "set_subtitle_style":
                let patch = SubtitleStylePatch.parse(from: raw)
                guard !patch.isEmpty else { continue }
                actions.append(.setSubtitleStyle(patch: patch))

            case "set_subtitles_visible":
                guard let visible = raw["visible"] as? Bool else { continue }
                actions.append(.setSubtitlesVisible(visible: visible))

            default:
                continue
            }
        }

        return AIActionBatch(actions: actions, explanation: explanation)
    }

    private static func number(_ raw: Any?) -> Double? {
        if let raw = raw as? Double {
            return raw
        }
        if let raw = raw as? Int {
            return Double(raw)
        }
        if let raw = raw as? NSNumber {
            return raw.doubleValue
        }
        return nil
    }
}

// MARK: - Restore Checkpoint Tool

struct RestoreCheckpointRequest: Sendable, Equatable {
    let checkpointID: UUID?
    let checkpointIndex: Int?
    let reason: String?

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "restore_checkpoint",
            description: "Restore the timeline to a previous checkpoint from the provided checkpoint history. Use checkpoint_index when possible; index 0 is the most recent undo checkpoint.",
            parameters: .init(
                type: "object",
                properties: [
                    "checkpoint_index": .init(
                        type: "number",
                        description: "Checkpoint index from the provided checkpoint history list. Use 0 to undo the latest change.",
                        items: nil
                    ),
                    "checkpoint_id": .init(
                        type: "string",
                        description: "Optional full checkpoint UUID. Prefer checkpoint_index when the list is provided.",
                        items: nil
                    ),
                    "reason": .init(
                        type: "string",
                        description: "Optional short explanation of why this checkpoint is being restored.",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )

    static func parse(from arguments: [String: Any]) -> RestoreCheckpointRequest? {
        let checkpointID = (arguments["checkpoint_id"] as? String).flatMap(UUID.init(uuidString:))
        let checkpointIndex = number(arguments["checkpoint_index"]).map { Int($0) }
        let reason = arguments["reason"] as? String

        guard checkpointID != nil || checkpointIndex != nil else {
            return nil
        }

        return RestoreCheckpointRequest(
            checkpointID: checkpointID,
            checkpointIndex: checkpointIndex,
            reason: reason
        )
    }

    func resolveCheckpoint(from history: [EditorRevision], allRevisions: [EditorRevision]) -> EditorRevision? {
        if let checkpointID {
            return allRevisions.first(where: { $0.id == checkpointID })
        }

        if let checkpointIndex, checkpointIndex >= 0, checkpointIndex < history.count {
            return history[checkpointIndex]
        }

        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        if let raw = raw as? Double {
            return raw
        }
        if let raw = raw as? Int {
            return Double(raw)
        }
        if let raw = raw as? NSNumber {
            return raw.doubleValue
        }
        return nil
    }
}
