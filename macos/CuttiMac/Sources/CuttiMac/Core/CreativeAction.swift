import Foundation
import CuttiKit

// MARK: - Tool Definitions (macOS-only: depend on ToolDefinition / OpenAIClient)

extension InsertBRollRequest {
    /// OpenAI tool definition — advertised alongside `edit_timeline` so
    /// the Agent can plan B-roll inserts in the same turn as timeline
    /// edits.
    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "insert_broll",
            description: "Layer a secondary video clip on top of the main timeline at a given composed-time anchor. Use when the user asks to 'add B-roll', 'insert cutaway', or cover part of the main video with a supplementary clip. The overlay fully replaces the main video picture during its window.",
            parameters: .init(
                type: "object",
                properties: [
                    "composed_time": .init(
                        type: "number",
                        description: "Start time (in composed timeline seconds, 0-based) where the overlay begins.",
                        items: nil
                    ),
                    "media_id": .init(
                        type: "string",
                        description: "UUID of an already-imported media asset. Must match an existing MediaAssetRecord.id — do not invent one.",
                        items: nil
                    ),
                    "duration": .init(
                        type: "number",
                        description: "Length of the overlay in seconds. Will be clamped to the source media's own duration.",
                        items: nil
                    ),
                    "mute_original": .init(
                        type: "boolean",
                        description: "When true (default) the overlay's own audio plays and the primary audio keeps playing; when false the overlay audio is muted so only the primary audio is heard.",
                        items: nil
                    ),
                ],
                required: ["composed_time", "media_id", "duration"],
                items: nil
            )
        )
    )
}

extension CreativeAction {
    /// OpenAI tool definition for insert_crossfade.
    static let insertCrossfadeToolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "insert_crossfade",
            description: "Crossfade two adjacent segments (segment N fades out while N+1 fades in) over the given duration in seconds. Both segment_ids must belong to the current timeline AND be directly adjacent. Duration is auto-clamped to half the shorter segment's length.",
            parameters: .init(
                type: "object",
                properties: [
                    "from_segment_id": .init(
                        type: "string",
                        description: "UUID of the outgoing segment (the one that fades out).",
                        items: nil
                    ),
                    "to_segment_id": .init(
                        type: "string",
                        description: "UUID of the incoming segment (the one that fades in). Must be the segment directly after from_segment_id.",
                        items: nil
                    ),
                    "duration": .init(
                        type: "number",
                        description: "Crossfade length in seconds. Typical values: 0.3 for tight cuts, 1.0 for softer transitions.",
                        items: nil
                    ),
                ],
                required: ["from_segment_id", "to_segment_id", "duration"],
                items: nil
            )
        )
    )
}
