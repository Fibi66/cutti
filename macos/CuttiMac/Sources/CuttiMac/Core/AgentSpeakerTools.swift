import Foundation
import CuttiKit

// MARK: - Agent Speaker Tools
//
// Exposes speaker-aware capabilities to the LLM:
//   • detect_speakers — run pause-based diarization
//   • find_by_speaker — list all cues for a given speaker id
//   • mute_speaker    — set volume=0 on every primary segment whose
//                       cues are predominantly that speaker
//
// All tools operate on the `speakerID` field that diarization stamps
// onto each `SubtitleEntry`.

struct DetectSpeakersRequest: Equatable, Sendable {
    /// Minimum pause (seconds) that marks a speaker boundary.
    var pauseThreshold: Double
    /// How many speakers the diarizer cycles through. 2 is a common
    /// interview / two-host podcast assumption.
    var speakerCount: Int

    static func parse(from args: [String: Any]) -> DetectSpeakersRequest {
        let pause = (args["pause_threshold"] as? Double)
            ?? (args["pause_threshold"] as? Int).map(Double.init)
            ?? 1.5
        let count = (args["speaker_count"] as? Int)
            ?? (args["speaker_count"] as? Double).map(Int.init)
            ?? 2
        return DetectSpeakersRequest(
            pauseThreshold: max(0.3, min(pause, 10)),
            speakerCount: max(2, min(count, 6))
        )
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "detect_speakers",
            description: "Run pause-based speaker diarization over the current timeline. Assigns a speaker_id to every subtitle cue so downstream tools (find_by_speaker, mute_speaker) can reference them. Heuristic: a gap longer than pause_threshold seconds between two cues marks a speaker change. Use when the user says 'who's talking when', 'label the speakers', or before speaker-scoped edits.",
            parameters: .init(
                type: "object",
                properties: [
                    "pause_threshold": .init(
                        type: "number",
                        description: "Minimum silence gap that marks a speaker change. Default 1.5s, clamped to [0.3, 10].",
                        items: nil
                    ),
                    "speaker_count": .init(
                        type: "number",
                        description: "How many distinct speakers to cycle through. Default 2, clamped to [2, 6].",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}

struct FindBySpeakerRequest: Equatable, Sendable {
    var speakerID: Int

    static func parse(from args: [String: Any]) -> FindBySpeakerRequest? {
        guard let raw = (args["speaker_id"] as? Int)
            ?? (args["speaker_id"] as? Double).map(Int.init) else { return nil }
        return FindBySpeakerRequest(speakerID: max(0, raw))
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "find_by_speaker",
            description: "Return every subtitle cue whose speaker_id matches. Call detect_speakers first if diarization hasn't run yet. Useful for 'show me everything the host said' or 'what did speaker B say about X'.",
            parameters: .init(
                type: "object",
                properties: [
                    "speaker_id": .init(
                        type: "number",
                        description: "Zero-based speaker index assigned by detect_speakers.",
                        items: nil
                    )
                ],
                required: ["speaker_id"],
                items: nil
            )
        )
    )
}

struct MuteSpeakerRequest: Equatable, Sendable {
    var speakerID: Int
    /// When true, muted segments keep their video but drop audio to 0.
    /// When false (default), segments dominated by the speaker are
    /// queued for deletion via a pending proposal.
    var muteAudioOnly: Bool

    static func parse(from args: [String: Any]) -> MuteSpeakerRequest? {
        guard let raw = (args["speaker_id"] as? Int)
            ?? (args["speaker_id"] as? Double).map(Int.init) else { return nil }
        let mute = (args["mute_audio_only"] as? Bool) ?? true
        return MuteSpeakerRequest(speakerID: max(0, raw), muteAudioOnly: mute)
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "mute_speaker",
            description: "Silence every primary-track segment whose subtitle cues are predominantly spoken by the given speaker. When mute_audio_only is true (default) the segments stay visible but play muted; when false they are marked for deletion (still goes through the manual Apply/Reject gate). Use for 'remove everything my co-host said' or 'mute speaker B'.",
            parameters: .init(
                type: "object",
                properties: [
                    "speaker_id": .init(
                        type: "number",
                        description: "Zero-based speaker index to mute.",
                        items: nil
                    ),
                    "mute_audio_only": .init(
                        type: "boolean",
                        description: "true = keep video, set volume to 0. false = delete the segments entirely.",
                        items: nil
                    )
                ],
                required: ["speaker_id"],
                items: nil
            )
        )
    )
}

enum AgentSpeakerQuery {
    /// Find every cue whose speakerID matches.
    static func findBySpeaker(
        speakerID: Int,
        in segments: [TimelineSegment]
    ) -> [AgentSubtitleMatch] {
        var out: [AgentSubtitleMatch] = []
        var offset = 0.0
        for segment in segments {
            let speed = max(0.0001, segment.normalizedSpeedRate)
            for entry in segment.subtitles where entry.speakerID == speakerID {
                let absStart = offset + entry.relativeStart / speed
                let absEnd = absStart + entry.relativeDuration / speed
                out.append(AgentSubtitleMatch(
                    subtitleID: entry.id.uuidString,
                    composedStart: absStart,
                    composedEnd: absEnd,
                    text: entry.text,
                    segmentID: segment.id.uuidString,
                    matchedTerm: nil
                ))
            }
            offset += segment.durationSeconds
        }
        return out
    }

    /// Return every primary-track segment where the *majority* of its
    /// subtitle cues belong to the given speaker. Used by mute_speaker
    /// to decide which segments to drop / silence.
    static func segmentsDominatedBy(
        speakerID: Int,
        in segments: [TimelineSegment]
    ) -> [UUID] {
        var out: [UUID] = []
        for segment in segments {
            let total = segment.subtitles.count
            guard total > 0 else { continue }
            let matching = segment.subtitles.filter { $0.speakerID == speakerID }.count
            if matching * 2 > total {
                out.append(segment.id)
            }
        }
        return out
    }
}
