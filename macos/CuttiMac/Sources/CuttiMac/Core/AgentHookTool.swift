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
        /// Stage-2 LLM rerank outcome: `"ok"`, `"skipped"` (rerank not
        /// attempted — too few candidates / no LLM client), or
        /// `"fallback"` (rerank attempted but failed). `"ok"` means
        /// `candidates[*].llmPunchScore` and `llmReasoning` are
        /// populated; the other two states leave them `nil`.
        let rerankStatus: String
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
                source recording in the project. Two-stage: stage-1 deterministic \
                scorer (length, position, anti-filler, energy) shortlists \
                candidates; stage-2 LLM rerank picks the final top_k by \
                short-form-video-producer rubric (self-contained, anti-spoiler, \
                punchy, etc.) and attaches a 1–10 punch_score and 1–2-sentence \
                reasoning to each. When stage-2 isn't available (no LLM client \
                / quota / network), result.rerank_status = "fallback" or \
                "skipped" and only stage-1 ordering is returned. Use this when \
                the user asks the AI to CHOOSE a punchy line for the cold open \
                (e.g. "AI 自己挑一句开场金句", "帮我挑个 hook"). Don't use it when \
                the user has already pointed at a specific line — for those, \
                find_by_transcript is the right tool. **The tool does NOT mutate \
                the timeline**, but as a side effect it does persist the latest \
                shortlist as `highlight` markers (origin = `ai`) on each source \
                recording's copilot snapshot, so the Highlights panel and any \
                future timeline-lane visualization can read them directly. \
                These markers replace any prior AI-origin `highlight` markers \
                from earlier runs (latest result wins); manual-origin highlights \
                that the user saved by hand are always preserved. Pair the \
                result with add_hook_teaser to actually splice the chosen \
                candidate into the cold-open slot.
                """,
            parameters: .init(
                type: "object",
                properties: [
                    "top_k": .init(
                        type: "integer",
                        description: "Final number of candidates to return AFTER stage-2 LLM rerank (default 5, capped at 20). Stage-1 internally pulls a larger pool — you don't need to manage that.",
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

    // MARK: - Highlight markers (PR 7)

    /// Per-record diff produced by `computeHighlightMarkerUpdates`. The
    /// dispatcher loads a fresh manifest at save time and applies these
    /// updates on top — never persisting a stale full snapshot.
    struct HighlightMarkerUpdate: Equatable, Sendable {
        let recordID: UUID
        /// Replacement set for the record's `.highlight` markers.
        /// Sorted by `seconds` ascending so equality comparison is
        /// stable regardless of candidate input order.
        let newHighlights: [AICopilotMarker]
    }

    /// Computes the per-record `.highlight`-marker diff that the
    /// dispatcher should persist after `score_hook_candidates` finishes.
    ///
    /// Replacement semantics: every candidate's `[sourceStart,
    /// sourceEnd]` becomes one new highlight marker on its source
    /// record. Prior **AI-origin** highlights on every record are
    /// dropped — the latest tool invocation is the source of truth for
    /// AI-curated highlights, including for records that *no longer*
    /// have a candidate (so stale AI highlights are cleared globally,
    /// not unioned). **Manual-origin highlights are never touched** by
    /// this helper — the user's saved highlights survive any number of
    /// `score_hook_candidates` reruns. Other marker kinds (`.scene`,
    /// `.suggestion`, `.warning`) are also never touched.
    ///
    /// Records that lack a copilot snapshot are skipped — we do not
    /// fabricate one just to attach markers. Records whose prior +
    /// proposed AI-highlight sets match (after sorting on `seconds`
    /// and `endSeconds`) are also skipped, so a re-run that produces
    /// the same shortlist won't trigger a redundant manifest write.
    ///
    /// Pure / synchronous so it's testable without instantiating the
    /// full view model.
    static func computeHighlightMarkerUpdates(
        candidates: [HookCandidate],
        records: [MediaAssetRecord]
    ) -> [HighlightMarkerUpdate] {
        let bySource = Dictionary(grouping: candidates, by: \.sourceVideoID)
        var out: [HighlightMarkerUpdate] = []
        for record in records {
            guard let snapshot = record.copilot else { continue }
            // Only the AI-origin highlight subset participates in the
            // replacement comparison. Manual-origin highlights are
            // invisible to this helper and the dispatcher's filter
            // step preserves them as well.
            let prevSorted = snapshot.markers
                .filter { $0.kind == .highlight && $0.origin == .ai }
                .sorted { lhs, rhs in
                    if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
                    return (lhs.endSeconds ?? 0) < (rhs.endSeconds ?? 0)
                }
            let newSorted: [AICopilotMarker] = (bySource[record.id] ?? []).map { c in
                AICopilotMarker(
                    kind: .highlight,
                    seconds: c.sourceStart,
                    endSeconds: c.sourceEnd,
                    label: makeHighlightLabel(from: c.text),
                    origin: .ai
                )
            }.sorted { lhs, rhs in
                if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
                return (lhs.endSeconds ?? 0) < (rhs.endSeconds ?? 0)
            }
            if prevSorted == newSorted { continue }
            out.append(HighlightMarkerUpdate(
                recordID: record.id,
                newHighlights: newSorted
            ))
        }
        return out
    }

    /// Normalises a candidate's transcript text into a single-line,
    /// length-capped marker label. Keeps the persisted manifest readable
    /// (no embedded newlines/tabs) and bounded (avoids manifest bloat
    /// when a candidate is unusually long).
    static func makeHighlightLabel(from text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(60))
    }

    // MARK: - add_hook_teaser orchestrator (PR 5)

    /// Parsed + validated arguments for the `add_hook_teaser` tool.
    /// Built by `parseHookTeaserArgs` from a raw JSON dict so the
    /// dispatcher case stays small and the validation is unit-testable
    /// without instantiating a `MediaCoreViewModel`.
    struct HookTeaserInputs: Equatable {
        let sourceVideoID: UUID
        let sourceName: String?
        let sourceStart: Double
        let sourceEnd: Double
        /// Audio fade-out duration on the inserted clip's tail. Creates
        /// a soft acoustic transition between the hook and the body.
        /// NOT a true silence gap — the body's first frame still
        /// follows immediately. Clamped to [0, 2.0].
        let audioTailSeconds: Double
        /// Audio fade-in duration on the clip head. Clamped to [0, 1.0].
        let fadeInSeconds: Double
        /// User-facing summary baked into the ProposedBatch card title.
        let explanation: String
    }

    enum HookTeaserError: Error, Equatable {
        case missingArg(String)
        case invalidUUID(String)
        case invalidRange(start: Double, end: Double)
        case sourceNotFound(UUID)
        case sourceNotVideo(UUID)
        case sourceRangeOutOfBounds(start: Double, end: Double, sourceDuration: Double)

        var userMessage: String {
            switch self {
            case .missingArg(let name):
                return "Missing required argument: \(name)"
            case .invalidUUID(let raw):
                return "Invalid UUID format: \(raw)"
            case .invalidRange(let s, let e):
                return "Invalid source range: source_start=\(s) must be < source_end=\(e)"
            case .sourceNotFound(let id):
                return "Source video \(id.uuidString) is not in this project."
            case .sourceNotVideo(let id):
                return "Source \(id.uuidString) is not a video asset."
            case .sourceRangeOutOfBounds(let s, let e, let dur):
                return "Source range [\(s), \(e)] is outside the clip's duration (0 — \(dur)s)."
            }
        }
    }

    /// Pure parser. Extracted so the dispatcher case is thin and the
    /// validation is unit-testable without a VM. Performs:
    ///   - argument presence + type checks
    ///   - UUID parsing
    ///   - range sanity (start < end, both >= 0)
    ///   - record lookup (must exist + be a video asset)
    ///   - bounds check against the source's analyzed duration
    static func parseHookTeaserArgs(
        args: [String: Any],
        records: [MediaAssetRecord]
    ) -> Swift.Result<HookTeaserInputs, HookTeaserError> {
        guard let sourceIDStr = args["source_video_id"] as? String, !sourceIDStr.isEmpty else {
            return .failure(.missingArg("source_video_id"))
        }
        guard let sourceID = UUID(uuidString: sourceIDStr) else {
            return .failure(.invalidUUID(sourceIDStr))
        }
        guard let sourceStart = doubleArg(args["source_start"]) else {
            return .failure(.missingArg("source_start"))
        }
        guard let sourceEnd = doubleArg(args["source_end"]) else {
            return .failure(.missingArg("source_end"))
        }
        guard sourceStart >= 0, sourceEnd > sourceStart else {
            return .failure(.invalidRange(start: sourceStart, end: sourceEnd))
        }
        guard let record = records.first(where: { $0.id == sourceID }) else {
            return .failure(.sourceNotFound(sourceID))
        }
        guard record.kind == .video else {
            return .failure(.sourceNotVideo(sourceID))
        }
        if let duration = record.analysis?.durationSeconds, duration > 0 {
            // Allow tiny epsilon for floating-point rounding from the LLM.
            guard sourceEnd <= duration + 0.05 else {
                return .failure(.sourceRangeOutOfBounds(
                    start: sourceStart,
                    end: sourceEnd,
                    sourceDuration: duration
                ))
            }
        }
        let audioTail = clamp(doubleArg(args["audio_tail_seconds"]) ?? 0.4, low: 0, high: 2.0)
        let fadeIn = clamp(doubleArg(args["fade_in_seconds"]) ?? 0.15, low: 0, high: 1.0)
        let sourceName = record.sourcePath.components(separatedBy: "/").last
        let duration = sourceEnd - sourceStart
        let defaultExplanation = String(
            format: "Add opening hook teaser (%.1fs%@)",
            duration,
            sourceName.map { " from \($0)" } ?? ""
        )
        let explanation: String = {
            if let raw = args["explanation"] as? String, !raw.isEmpty {
                return raw
            }
            return defaultExplanation
        }()
        return .success(HookTeaserInputs(
            sourceVideoID: sourceID,
            sourceName: sourceName,
            sourceStart: sourceStart,
            sourceEnd: sourceEnd,
            audioTailSeconds: audioTail,
            fadeInSeconds: fadeIn,
            explanation: explanation
        ))
    }

    /// Build the single-action `AIActionBatch` that the dispatcher will
    /// dry-run + wrap in a ProposedBatch. The `composedInsertAt = 0` is
    /// hardcoded — the orchestrator's whole purpose is "put this at the
    /// head of the timeline". Audio tail = `fadeOutSeconds` on the
    /// inserted clip.
    static func buildHookBatch(_ inputs: HookTeaserInputs) -> AIActionBatch {
        AIActionBatch(
            actions: [.insertSourceClip(
                sourceVideoID: inputs.sourceVideoID,
                sourceStart: inputs.sourceStart,
                sourceEnd: inputs.sourceEnd,
                composedInsertAt: 0,
                fadeInSeconds: inputs.fadeInSeconds,
                fadeOutSeconds: inputs.audioTailSeconds
            )],
            explanation: inputs.explanation
        )
    }

    static let addHookTeaserTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "add_hook_teaser",
            description: """
                Add an opening-hook (cold-open teaser) clip at composed time 0. \
                The selected source span is sliced from its origin recording and \
                spliced in front of the existing edit; the body that was at 0 \
                slides right by the hook's duration. Always produces a Pending \
                proposal that the user must Apply — never auto-applies, even in \
                auto-apply mode (opening hooks are high-stakes). \
                Use this AFTER score_hook_candidates returns and the user has \
                picked a candidate. Pass that candidate's source_video_id, \
                source_start, source_end. If the user wants a Quote overlay or \
                SFX punch on the hook, call generate_overlay / SFX tools \
                AFTER the user clicks Apply on this proposal — those are \
                separate tool calls, not part of this batch. Do NOT chain \
                further destructive edits in the same turn; wait for the user \
                to confirm.
                """,
            parameters: .init(
                type: "object",
                properties: [
                    "source_video_id": .init(
                        type: "string",
                        description: "UUID of the source media record (from a score_hook_candidates result).",
                        items: nil
                    ),
                    "source_start": .init(
                        type: "number",
                        description: "Start of the span to clip from the source, in seconds. Must satisfy 0 ≤ start < end ≤ source_duration.",
                        items: nil
                    ),
                    "source_end": .init(
                        type: "number",
                        description: "End of the span to clip from the source, in seconds. Must satisfy 0 ≤ start < end ≤ source_duration.",
                        items: nil
                    ),
                    "audio_tail_seconds": .init(
                        type: "number",
                        description: "Audio fade-out duration on the hook's tail (default 0.4, clamped [0, 2]). NOTE: this is an audio fade only — it does NOT insert a silence gap; the body's first frame follows immediately.",
                        items: nil
                    ),
                    "fade_in_seconds": .init(
                        type: "number",
                        description: "Audio fade-in on the hook's head (default 0.15, clamped [0, 1]).",
                        items: nil
                    ),
                    "explanation": .init(
                        type: "string",
                        description: "Optional human-readable card title. Defaults to 'Add opening hook teaser (Xs from name.mov)'.",
                        items: nil
                    )
                ],
                required: ["source_video_id", "source_start", "source_end"],
                items: nil
            )
        )
    )

    // MARK: - Helpers

    private static func doubleArg(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func clamp(_ x: Double, low: Double, high: Double) -> Double {
        max(low, min(high, x))
    }
}
