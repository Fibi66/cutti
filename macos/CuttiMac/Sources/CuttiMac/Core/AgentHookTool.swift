import Foundation
import CuttiKit

// MARK: - score_hook_candidates tool
//
// Read-only AI agent tool that ranks "opening-hook" candidates across
// every source recording in the project. Pure local — calls into the
// deterministic stage-1 scorer (`HookCandidateScorer`) in CuttiKit. No
// LLM call here; stage-2 LLM rerank lives in PR 4.
//
// Why a separate file from `AgentQueryTools.swift`? This tool is going
// to grow neighbours (`add_hook_teaser` orchestrator, candidate-card
// payloads) — keeping the hook-feature surface together makes it easier
// to remove or feature-flag later.

enum AgentHook {

    /// Result returned by the `score_hook_candidates` tool. Encoded as
    /// JSON and surfaced back to the LLM as a `tool` message; also fed
    /// directly into a candidate-card view (PR 6).
    struct Result: Codable, Equatable, Sendable {
        let candidates: [HookCandidate]
        let stats: HookCandidateStats
    }

    /// Build `[HookSource]` from the project's media records. Sources
    /// without a sentence-level transcript fall back to gluing a
    /// word-level transcript when one is available, so transcribe-only
    /// or partial sources still contribute candidates.
    static func collectSources(from records: [MediaAssetRecord]) -> [HookSource] {
        var out: [HookSource] = []
        for record in records {
            guard record.kind == .video else { continue }
            guard let snapshot = record.copilot,
                  let duration = record.analysis?.durationSeconds,
                  duration > 0
            else { continue }
            let transcript: [TranscriptSegment]
            if let sentenceLevel = snapshot.transcript, !sentenceLevel.isEmpty {
                transcript = sentenceLevel
            } else if let words = snapshot.wordTranscript, !words.isEmpty {
                transcript = HookCandidateScorer.synthesize(fromWords: words)
            } else {
                transcript = []
            }
            let sourceName = record.sourcePath
                .components(separatedBy: "/")
                .last
            out.append(HookSource(
                sourceVideoID: record.id,
                sourceName: sourceName,
                durationSeconds: duration,
                transcript: transcript,
                energyCurve: snapshot.audioEnergyCurve
            ))
        }
        return out
    }

    static let scoreHookCandidatesTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "score_hook_candidates",
            description: """
                Rank "opening-hook" / cold-open teaser candidates across every \
                source recording in the project. Returns top-K candidates with \
                per-dimension sub-scores (length, position, anti-filler, energy) \
                and a 1-line reason. Use this when the user asks the AI to \
                CHOOSE a punchy line for the cold open (e.g. "AI 自己挑一句开场金句", \
                "帮我挑个 hook"). Don't use it when the user has already pointed at \
                a specific line — for those, find_by_transcript is the right tool. \
                The tool only inspects raw recordings; it does NOT mutate the \
                timeline. Pair the result with insertSourceClip (via edit_timeline) \
                to actually splice the chosen candidate into the cold-open slot.
                """,
            parameters: .init(
                type: "object",
                properties: [
                    "top_k": .init(
                        type: "integer",
                        description: "Number of candidates to return (default 20, capped at 50).",
                        items: nil
                    ),
                    "min_duration": .init(
                        type: "number",
                        description: "Minimum candidate duration in seconds (default 2.5).",
                        items: nil
                    ),
                    "max_duration": .init(
                        type: "number",
                        description: "Maximum candidate duration in seconds (default 10.0).",
                        items: nil
                    ),
                    "ideal_duration": .init(
                        type: "number",
                        description: "Target duration the length-fit term peaks at (default 5.0). Must satisfy min ≤ ideal ≤ max.",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}
