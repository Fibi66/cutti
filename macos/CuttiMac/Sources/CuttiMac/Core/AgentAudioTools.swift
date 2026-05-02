import Foundation

// MARK: - Agent Audio Tools
//
// Tool definitions + argument parsers for the three audio-editing
// capabilities exposed to the AI agent:
//   • set_segment_volume — per-segment volume (0…2×)
//   • audio_ducking      — drop BGM track volume during speech
//   • normalize_loudness — level every segment to a target LUFS/dB
//
// All tools route through MediaCoreViewModel. The parsers here are
// pure so they can be unit-tested without touching Combine state.

/// Parsed form of a `set_segment_volume` tool call.
struct SetSegmentVolumeRequest: Equatable, Sendable {
    var segmentID: UUID
    /// 0.0 = mute, 1.0 = unity, values > 1 boost (capped at 2.0).
    var level: Double

    static func parse(from args: [String: Any]) -> SetSegmentVolumeRequest? {
        guard let idString = args["segment_id"] as? String,
              let id = UUID(uuidString: idString) else { return nil }
        guard let rawLevel = (args["level"] as? Double)
            ?? (args["level"] as? Int).map(Double.init) else { return nil }
        return SetSegmentVolumeRequest(
            segmentID: id,
            level: max(0, min(rawLevel, 2.0))
        )
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "set_segment_volume",
            description: "Set the audio volume of ONE primary-track segment. 0.0 mutes it, 1.0 is unity, up to 2.0 boosts it. Use this when the user says 'make this clip louder / quieter', not for timeline-wide loudness changes (use normalize_loudness instead).",
            parameters: .init(
                type: "object",
                properties: [
                    "segment_id": .init(
                        type: "string",
                        description: "UUID of the primary-track segment. Call get_segment_detail first if unsure.",
                        items: nil
                    ),
                    "level": .init(
                        type: "number",
                        description: "Volume multiplier. 0.0 = mute, 1.0 = unity, up to 2.0. Values outside [0, 2] are clamped.",
                        items: nil
                    )
                ],
                required: ["segment_id", "level"],
                items: nil
            )
        )
    )
}

/// Parsed form of an `audio_ducking` tool call. Duck = lower BGM
/// tracks' volume during speech windows on the primary track.
struct AudioDuckingRequest: Equatable, Sendable {
    /// Target BGM track id. When nil, ALL audio tracks are ducked.
    var trackID: UUID?
    /// Multiplier applied to the BGM during speech. 0.25 = duck to 25%,
    /// 0 = full silence under speech. Clamped to [0, 1].
    var duckLevel: Double

    static func parse(from args: [String: Any]) -> AudioDuckingRequest? {
        let trackIDString = args["track_id"] as? String
        let trackID = trackIDString.flatMap(UUID.init(uuidString:))
        guard let raw = (args["duck_level"] as? Double)
            ?? (args["duck_level"] as? Int).map(Double.init) else { return nil }
        return AudioDuckingRequest(
            trackID: trackID,
            duckLevel: max(0, min(raw, 1.0))
        )
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "audio_ducking",
            description: "Automatically lower the volume of a BGM (background music) track wherever the primary track has speech, so the voice stays intelligible. Sets the BGM track's overall volume to duck_level — a more sophisticated time-varying duck is a future enhancement. Pass track_id = null to duck every audio track.",
            parameters: .init(
                type: "object",
                properties: [
                    "track_id": .init(
                        type: "string",
                        description: "UUID of the BGM / audio track to duck. When null, every audio track is ducked.",
                        items: nil
                    ),
                    "duck_level": .init(
                        type: "number",
                        description: "Target BGM volume multiplier (0 = silent, 1 = no change, 0.25 is a typical duck).",
                        items: nil
                    )
                ],
                required: ["duck_level"],
                items: nil
            )
        )
    )
}

/// Parsed form of a `normalize_loudness` tool call.
struct NormalizeLoudnessRequest: Equatable, Sendable {
    /// Target average loudness in dB. Typical values: -16 (podcast),
    /// -14 (YouTube), -23 (broadcast).
    var targetDB: Double

    static func parse(from args: [String: Any]) -> NormalizeLoudnessRequest {
        let raw = (args["target_db"] as? Double)
            ?? (args["target_db"] as? Int).map(Double.init)
            ?? -16
        return NormalizeLoudnessRequest(targetDB: max(-40, min(raw, 0)))
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "normalize_loudness",
            description: "Analyze every source video's average loudness and attenuate per-segment volume so the final edit sits at target_db (typical values: -16 for podcast, -14 for YouTube). Only attenuates — never boosts — so it's safe to run repeatedly. Use when the user says 'make the audio consistent' or 'normalize volume'.",
            parameters: .init(
                type: "object",
                properties: [
                    "target_db": .init(
                        type: "number",
                        description: "Target average dB. Defaults to -16 when omitted. Clamped to [-40, 0].",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}
