import Foundation
import CuttiKit

// MARK: - Agent Generative Tools
//
// Read-only "suggest" tools the LLM uses to produce short pieces of
// generative content (title, chapter markers) derived from the
// timeline. They DO NOT mutate the project — they just return text
// the user can inspect. The actual insertion (as a title card,
// chapter marker, or description block) is a separate explicit
// action the user has to confirm.
//
// Keeping these as tool calls (rather than free-form chat) means we
// get:
//   • a consistent shape the UI can render as a card,
//   • an audit trail inside the agent trace, and
//   • a cheap hook to validate / redact the suggestions later.

struct SuggestTitleRequest: Equatable, Sendable {
    /// Maximum length in characters. Platform convention:
    /// YouTube 60, TikTok 80, Twitch 140. Clamped to [10, 140].
    var maxLength: Int
    /// Language hint ("zh" / "en" / "auto"). The agent is responsible
    /// for honoring this; we just forward it to the tool result so
    /// it's visible in the trace.
    var language: String

    static func parse(from args: [String: Any]) -> SuggestTitleRequest {
        let rawMax = (args["max_length"] as? Int)
            ?? (args["max_length"] as? Double).map(Int.init)
            ?? 60
        let lang = (args["language"] as? String) ?? "auto"
        return SuggestTitleRequest(
            maxLength: max(10, min(rawMax, 140)),
            language: lang
        )
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "suggest_title",
            description: "Return 3 short title candidates for the current edit, derived from the subtitle transcript. Does NOT modify the project — it's a generative aid for the user. Call when the user asks 'give me a title', 'what should I name this', etc. The returned JSON includes the transcript excerpt used as input so the caller can verify.",
            parameters: .init(
                type: "object",
                properties: [
                    "max_length": .init(
                        type: "number",
                        description: "Max characters per candidate. 60 = YouTube, 80 = TikTok. Default 60.",
                        items: nil
                    ),
                    "language": .init(
                        type: "string",
                        description: "Language tag for the output (\"zh\", \"en\", \"auto\"). Default auto.",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}

struct SuggestChaptersRequest: Equatable, Sendable {
    /// Approximate number of chapters to propose. 3…15.
    var targetCount: Int
    var language: String

    static func parse(from args: [String: Any]) -> SuggestChaptersRequest {
        let raw = (args["target_count"] as? Int)
            ?? (args["target_count"] as? Double).map(Int.init)
            ?? 5
        let lang = (args["language"] as? String) ?? "auto"
        return SuggestChaptersRequest(
            targetCount: max(3, min(raw, 15)),
            language: lang
        )
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "suggest_chapters",
            description: "Return chapter markers (composed_time + short label) for the current edit, derived from the transcript. The agent is expected to partition the timeline into target_count natural sections. Does NOT modify the project — this is a suggestion surface.",
            parameters: .init(
                type: "object",
                properties: [
                    "target_count": .init(
                        type: "number",
                        description: "Approximate number of chapters. Clamped to [3, 15]. Default 5.",
                        items: nil
                    ),
                    "language": .init(
                        type: "string",
                        description: "Language tag for chapter labels.",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}

/// Helper that builds the transcript excerpt we feed back to the LLM
/// when it invokes suggest_title / suggest_chapters. We don't actually
/// CALL the LLM from inside the tool (that would be an extra round
/// trip); instead the tool returns the transcript + timeline stats as
/// structured data and relies on the NEXT assistant turn to produce
/// the creative output, which then shows up in the chat as a normal
/// assistant message.
enum AgentGenerativeInput {
    struct TranscriptBundle: Codable, Sendable {
        let totalDurationSeconds: Double
        let language: String
        /// Full transcript lines (composed time + text). Capped at
        /// ~200 cues to keep the tool result under token budget.
        let cues: [Cue]
        struct Cue: Codable, Sendable {
            let start: Double
            let end: Double
            let text: String
        }
    }

    static func transcript(
        from segments: [TimelineSegment],
        language: String,
        cap: Int = 200
    ) -> TranscriptBundle {
        let walked = AgentQuery.walkComposedSubtitles(segments)
        let trimmed = walked.prefix(cap)
        let cues = trimmed.map { TranscriptBundle.Cue(start: $0.start, end: $0.end, text: $0.entry.text) }
        let total = segments.reduce(0.0) { $0 + $1.durationSeconds }
        return TranscriptBundle(
            totalDurationSeconds: total,
            language: language,
            cues: cues
        )
    }
}
