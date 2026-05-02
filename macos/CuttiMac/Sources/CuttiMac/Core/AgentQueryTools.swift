import Foundation
import CuttiKit

// MARK: - Agent Query Tools
//
// Read-only tools the AI Agent can call to inspect the current timeline /
// transcript before deciding what to edit. Pure functions — no mutations.
// Each tool returns a JSON-serializable payload. The Agent loop encodes the
// payload as the tool message content and feeds it back to the LLM.

/// Default English + Chinese filler words. Lower-cased; matched against
/// stripped subtitle words (punctuation removed, lower-cased).
enum AgentDefaults {
    static let fillerWords: [String] = [
        // English
        "uh", "um", "uhh", "umm", "uhm", "er", "erm", "ah", "ahh",
        "like", "you know", "i mean", "sort of", "kind of", "basically",
        // Chinese
        "嗯", "啊", "呃", "那个", "这个", "然后", "就是", "其实",
    ]
}

/// One match returned by `find_filler_words` or `find_by_transcript`.
struct AgentSubtitleMatch: Codable, Equatable, Sendable {
    let subtitleID: String
    let composedStart: Double
    let composedEnd: Double
    let text: String
    /// Which segment (UUID) the cue belongs to.
    let segmentID: String
    /// Which filler word matched (only set for find_filler_words).
    let matchedTerm: String?
}

/// Aggregate output for `get_timeline_summary`.
struct AgentTimelineSummary: Codable, Equatable, Sendable {
    let totalDurationSeconds: Double
    let segmentCount: Int
    let subtitleCount: Int
    let fillerWordCount: Int
    let sourceVideos: [String]
    /// Top-N longest segments (composed seconds), useful for "trim the boring
    /// long takes" prompts.
    let longestSegments: [LongSegment]

    struct LongSegment: Codable, Equatable, Sendable {
        let segmentID: String
        let composedStart: Double
        let composedEnd: Double
        let durationSeconds: Double
    }
}

/// Detailed snapshot of a single timeline segment. Returned by the
/// `get_segment_detail` tool so the agent can reason about volume /
/// speed / fades / transforms before issuing targeted edits.
struct AgentSegmentDetail: Codable, Equatable, Sendable {
    let segmentID: String
    let segmentIndex: Int
    let sourceVideoID: String
    let sourceName: String?
    let composedStart: Double
    let composedEnd: Double
    let durationSeconds: Double
    let sourceStart: Double
    let sourceEnd: Double
    let volumeLevel: Double
    let speedRate: Double
    let isVideoHidden: Bool
    let audioFadeInDuration: Double
    let audioFadeOutDuration: Double
    let rotation: Int
    let flipHorizontal: Bool
    let flipVertical: Bool
    let brightness: Double
    let contrast: Double
    let saturation: Double
    let subtitleCount: Int
    let text: String
    /// Set of distinct speaker ids referenced by this segment's
    /// subtitle cues. Empty when diarization hasn't run.
    let speakers: [Int]
}

// MARK: - Pure search helpers

enum AgentQuery {
    /// Iterates all subtitle cues across the composed timeline, projecting
    /// each cue into composed-time space (accounting for per-segment speed).
    /// Returns `(segment, entry, composedStart, composedEnd)` tuples.
    static func walkComposedSubtitles(
        _ segments: [TimelineSegment]
    ) -> [(segment: TimelineSegment, entry: SubtitleEntry, start: Double, end: Double)] {
        var out: [(TimelineSegment, SubtitleEntry, Double, Double)] = []
        var offset = 0.0
        for segment in segments {
            let speed = max(0.0001, segment.normalizedSpeedRate)
            for entry in segment.subtitles {
                let absStart = offset + entry.relativeStart / speed
                let absEnd = absStart + entry.relativeDuration / speed
                out.append((segment, entry, absStart, absEnd))
            }
            offset += segment.durationSeconds
        }
        return out
    }

    /// Find every cue whose word list contains any of the configured filler
    /// terms. Multi-word terms (e.g. "you know") are matched as substrings of
    /// the cue text after lowercasing both sides.
    static func findFillerWords(
        in segments: [TimelineSegment],
        fillerTerms: [String]
    ) -> [AgentSubtitleMatch] {
        let normalized = fillerTerms
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return [] }

        var matches: [AgentSubtitleMatch] = []
        for cue in walkComposedSubtitles(segments) {
            let lowered = cue.entry.text.lowercased()
            // Tokenize on whitespace + punctuation for single-word filters,
            // but also do a substring fallback so multi-word terms match.
            let words = lowered.unicodeScalars
                .split { !CharacterSet.letters.union(.decimalDigits).contains($0) }
                .map { String($0) }
            for term in normalized {
                let matched: Bool
                if term.contains(" ") {
                    matched = lowered.contains(term)
                } else {
                    matched = words.contains(term)
                }
                if matched {
                    matches.append(AgentSubtitleMatch(
                        subtitleID: cue.entry.id.uuidString,
                        composedStart: cue.start,
                        composedEnd: cue.end,
                        text: cue.entry.text,
                        segmentID: cue.segment.id.uuidString,
                        matchedTerm: term
                    ))
                    break
                }
            }
        }
        return matches
    }

    /// Substring search across all subtitle text. Case-insensitive.
    static func findByTranscript(
        query: String,
        in segments: [TimelineSegment]
    ) -> [AgentSubtitleMatch] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var matches: [AgentSubtitleMatch] = []
        for cue in walkComposedSubtitles(segments) {
            if cue.entry.text.lowercased().contains(needle) {
                matches.append(AgentSubtitleMatch(
                    subtitleID: cue.entry.id.uuidString,
                    composedStart: cue.start,
                    composedEnd: cue.end,
                    text: cue.entry.text,
                    segmentID: cue.segment.id.uuidString,
                    matchedTerm: nil
                ))
            }
        }
        return matches
    }

    /// Build a detailed snapshot of every segment whose id appears in
    /// `segmentIDs`. Unknown ids are silently dropped. If `segmentIDs`
    /// is empty, every segment in the timeline is returned.
    static func segmentDetails(
        _ segments: [TimelineSegment],
        ids: [UUID],
        sourceNamesByID: [UUID: String]
    ) -> [AgentSegmentDetail] {
        let wanted = Set(ids)
        var offset: Double = 0
        var out: [AgentSegmentDetail] = []
        for (index, seg) in segments.enumerated() {
            let composedStart = offset
            let composedEnd = offset + seg.durationSeconds
            offset = composedEnd
            if !wanted.isEmpty && !wanted.contains(seg.id) { continue }
            let speakers = Array(Set(seg.subtitles.compactMap(\.speakerID))).sorted()
            out.append(AgentSegmentDetail(
                segmentID: seg.id.uuidString,
                segmentIndex: index,
                sourceVideoID: seg.sourceVideoID.uuidString,
                sourceName: sourceNamesByID[seg.sourceVideoID],
                composedStart: composedStart,
                composedEnd: composedEnd,
                durationSeconds: seg.durationSeconds,
                sourceStart: seg.range.startSeconds,
                sourceEnd: seg.range.endSeconds,
                volumeLevel: seg.volumeLevel,
                speedRate: seg.normalizedSpeedRate,
                isVideoHidden: seg.isVideoHidden,
                audioFadeInDuration: seg.effects.audioFadeInDuration,
                audioFadeOutDuration: seg.effects.audioFadeOutDuration,
                rotation: seg.effects.rotation,
                flipHorizontal: seg.effects.flipHorizontal,
                flipVertical: seg.effects.flipVertical,
                brightness: seg.effects.brightness,
                contrast: seg.effects.contrast,
                saturation: seg.effects.saturation,
                subtitleCount: seg.subtitles.count,
                text: seg.text,
                speakers: speakers
            ))
        }
        return out
    }

    /// Build a high-level summary the Agent can use for planning.
    static func summarize(
        segments: [TimelineSegment],
        sourceNamesByID: [UUID: String],
        fillerTerms: [String] = AgentDefaults.fillerWords,
        topLongestCount: Int = 5
    ) -> AgentTimelineSummary {
        let total = segments.reduce(0.0) { $0 + $1.durationSeconds }
        let subtitleCount = segments.reduce(0) { $0 + $1.subtitles.count }
        let fillerCount = findFillerWords(in: segments, fillerTerms: fillerTerms).count

        var sources: [String] = []
        var seen = Set<UUID>()
        for seg in segments where !seen.contains(seg.sourceVideoID) {
            seen.insert(seg.sourceVideoID)
            sources.append(sourceNamesByID[seg.sourceVideoID] ?? seg.sourceVideoID.uuidString.prefix(8).description)
        }

        var offset = 0.0
        var withTimes: [(TimelineSegment, Double, Double)] = []
        for seg in segments {
            withTimes.append((seg, offset, offset + seg.durationSeconds))
            offset += seg.durationSeconds
        }
        let longest = withTimes
            .sorted { $0.0.durationSeconds > $1.0.durationSeconds }
            .prefix(topLongestCount)
            .map { (seg, s, e) in
                AgentTimelineSummary.LongSegment(
                    segmentID: seg.id.uuidString,
                    composedStart: s,
                    composedEnd: e,
                    durationSeconds: seg.durationSeconds
                )
            }

        return AgentTimelineSummary(
            totalDurationSeconds: total,
            segmentCount: segments.count,
            subtitleCount: subtitleCount,
            fillerWordCount: fillerCount,
            sourceVideos: sources,
            longestSegments: Array(longest)
        )
    }
}

// MARK: - Tool definitions for OpenAI function-calling

extension AgentQuery {
    static let findFillerWordsTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "find_filler_words",
            description: "Search every subtitle cue in the current timeline for filler words (uh, um, like, you know, 嗯, 啊, etc.). Returns a list of matching cues with composed-time ranges. Call this BEFORE asking the user whether to delete fillers — never invent counts.",
            parameters: .init(
                type: "object",
                properties: [
                    "extra_terms": .init(
                        type: "array",
                        description: "Optional additional filler words to search for, on top of the built-in list.",
                        items: .init(type: "string", properties: nil, required: nil)
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )

    static let findByTranscriptTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "find_by_transcript",
            description: "Find every subtitle cue whose text contains the query string (case-insensitive substring match). Use this when the user references content by what was said (e.g. \"the part where I talk about pricing\").",
            parameters: .init(
                type: "object",
                properties: [
                    "query": .init(
                        type: "string",
                        description: "Substring to search for in subtitle text.",
                        items: nil
                    )
                ],
                required: ["query"],
                items: nil
            )
        )
    )

    static let getTimelineSummaryTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "get_timeline_summary",
            description: "Return high-level stats about the current timeline: total duration, segment count, subtitle count, filler-word count, source video list, and the longest segments. Use this when the user asks vague questions like \"how long is my edit?\" or \"what's bloated?\".",
            parameters: .init(
                type: "object",
                properties: [:],
                required: nil,
                items: nil
            )
        )
    )

    static let getSegmentDetailTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "get_segment_detail",
            description: "Return per-segment state (volume, speed, fades, color, rotation, speakers, subtitle count) for the given segment ids. Call this BEFORE issuing edit_timeline actions on a specific clip so you know what to change. Pass an empty list to get details for ALL segments (use sparingly on long timelines).",
            parameters: .init(
                type: "object",
                properties: [
                    "segment_ids": .init(
                        type: "array",
                        description: "List of segment UUIDs to inspect. Empty list = every segment (bounded by timeline size).",
                        items: .init(type: "string", properties: nil, required: nil)
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}

// MARK: - JSON helpers

enum AgentToolJSON {
    /// Encode any `Encodable` payload as a compact JSON string. The Agent
    /// loop feeds this string back as a `tool` role message, so the LLM can
    /// re-read its own tool result on the next step.
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    static func encodeError(_ message: String) -> String {
        encode(["error": message])
    }
}
