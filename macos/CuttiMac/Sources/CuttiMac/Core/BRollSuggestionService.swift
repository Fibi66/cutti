import Foundation
import CuttiKit

/// Two-phase visual-aid suggestion agent.
///
/// A human editor doesn't look at raw transcript and immediately decide
/// "a chart goes here". They first read the whole piece, understand
/// what each section is doing (thesis, example, enumeration, call to
/// action…), then ask per section "would a visual help this?". This
/// agent mirrors that flow:
///
///   • **Phase 1 — `analyze_structure`** (1 LLM call): segments the
///     kept transcript into semantic sections with a role label, a
///     summary, and a `benefits_visual` yes/no. The model is NOT asked
///     to propose any visuals in this phase, so it can spend all its
///     reasoning on structural understanding.
///
///   • **Phase 2 — `propose_visuals`** (N parallel LLM calls, one per
///     section where `benefits_visual == true`): each call receives
///     the full transcript of that single section plus neighbour
///     summaries for cross-section awareness, and returns however many
///     anchors the content actually warrants (0..N, no hard cap).
///
/// Total round-trips = `1 + M` where M ≤ number of sections. Sections
/// the model flags as conversational / emotional are skipped entirely,
/// so a video with mostly talking-head content pays almost nothing
/// extra vs. the old single-shot pass.
struct BRollSuggestionService: Sendable {
    let client: OpenAIClient
    /// Called with high-level phase strings so the caller (chat bubble
    /// / progress bar) can surface what the agent is currently doing.
    /// Stays `nil` for callers that don't care.
    var onProgress: (@Sendable (String) -> Void)?

    init(
        client: OpenAIClient,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) {
        self.client = client
        self.onProgress = onProgress
    }

    /// Entry point. Runs phase 1, fan-outs phase 2 in parallel, merges
    /// and returns the suggestions. Failures at any stage degrade
    /// gracefully: a phase-2 failure drops that one section; a phase-1
    /// failure returns `[]` so the caller can't tell "failed" from
    /// "nothing warranted" — both are fine UX.
    func suggest(
        keptSegments: [TranscriptSegment],
        sourceVideoID: UUID
    ) async -> [BRollSuggestion] {
        guard !keptSegments.isEmpty else { return [] }
        let lowerBound = keptSegments.first?.startSeconds ?? 0
        let upperBound = keptSegments.last?.endSeconds ?? 0

        onProgress?("Reading through the cut to understand its structure…")
        guard let sections = await analyzeStructure(
            keptSegments: keptSegments,
            lowerBound: lowerBound,
            upperBound: upperBound
        ) else {
            return []
        }

        let visualCandidates = sections.enumerated()
            .filter { _, section in section.benefitsVisual }
            .map { ($0.offset, $0.element) }

        guard !visualCandidates.isEmpty else {
            onProgress?("Read the cut — no section reads as visual-benefiting.")
            return []
        }

        onProgress?("Proposing visuals for \(visualCandidates.count) section\(visualCandidates.count == 1 ? "" : "s")…")

        let anchors: [BRollSuggestion] = await withTaskGroup(
            of: [BRollSuggestion].self
        ) { group in
            for (idx, section) in visualCandidates {
                group.addTask {
                    await self.proposeVisuals(
                        for: section,
                        sectionIndex: idx,
                        allSections: sections,
                        keptSegments: keptSegments,
                        sourceVideoID: sourceVideoID,
                        lowerBound: lowerBound,
                        upperBound: upperBound
                    )
                }
            }
            var all: [BRollSuggestion] = []
            for await sectionAnchors in group {
                all.append(contentsOf: sectionAnchors)
            }
            return all
        }

        // Deterministic output order — by start time, then by kind so
        // reruns on the same transcript produce a stable list.
        return anchors.sorted {
            if $0.sourceStartSeconds != $1.sourceStartSeconds {
                return $0.sourceStartSeconds < $1.sourceStartSeconds
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    // MARK: - Phase 1

    private struct Section: Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let role: String
        let summary: String
        let benefitsVisual: Bool
        let visualReason: String
    }

    private func analyzeStructure(
        keptSegments: [TranscriptSegment],
        lowerBound: Double,
        upperBound: Double
    ) async -> [Section]? {
        let transcriptText = Self.formatTranscript(keptSegments)
        let messages: [ChatMessage] = [
            .system(Self.structureSystemPrompt),
            .user("Kept transcript (after first-cut). Segment it into semantic sections and flag which benefit from a visual aid.\n\n" + transcriptText),
        ]

        let response: ChatCompletionResponse
        do {
            response = try await client.chatCompletion(
                messages: messages,
                tools: [Self.structureTool],
                toolChoice: .required(name: "analyze_structure"),
                temperature: 0.2
            )
        } catch {
            print("⚠️ BRollSuggestionService phase-1 failed — \(error)")
            return nil
        }

        guard let toolCall = response.toolCalls.first,
              let data = toolCall.function.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = args["sections"] as? [[String: Any]]
        else { return nil }

        let parsed: [Section] = raw.compactMap { row in
            guard let role = (row["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !role.isEmpty,
                  let summary = (row["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty,
                  let benefits = row["benefits_visual"] as? Bool,
                  let startRaw = (row["start_s"] as? Double) ?? (row["start_s"] as? Int).map(Double.init),
                  let endRaw = (row["end_s"] as? Double) ?? (row["end_s"] as? Int).map(Double.init)
            else { return nil }
            let start = max(lowerBound, min(startRaw, upperBound))
            let end = max(start + 0.1, min(endRaw, upperBound))
            let reason = ((row["visual_reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Section(
                startSeconds: start,
                endSeconds: end,
                role: role,
                summary: summary,
                benefitsVisual: benefits,
                visualReason: reason
            )
        }
        return parsed.isEmpty ? nil : parsed
    }

    // MARK: - Phase 2

    private func proposeVisuals(
        for section: Section,
        sectionIndex: Int,
        allSections: [Section],
        keptSegments: [TranscriptSegment],
        sourceVideoID: UUID,
        lowerBound: Double,
        upperBound: Double
    ) async -> [BRollSuggestion] {
        let sectionSegments = keptSegments.filter { seg in
            seg.endSeconds > section.startSeconds && seg.startSeconds < section.endSeconds
        }
        guard !sectionSegments.isEmpty else { return [] }

        let prev = sectionIndex > 0 ? allSections[sectionIndex - 1] : nil
        let next = sectionIndex + 1 < allSections.count ? allSections[sectionIndex + 1] : nil

        var contextLines: [String] = []
        contextLines.append("Section role: \(section.role)")
        contextLines.append("Section summary: \(section.summary)")
        if !section.visualReason.isEmpty {
            contextLines.append("Why a visual could help (phase-1 note): \(section.visualReason)")
        }
        if let prev {
            contextLines.append("Previous section (\(prev.role)): \(prev.summary)")
        }
        if let next {
            contextLines.append("Next section (\(next.role)): \(next.summary)")
        }
        let context = contextLines.joined(separator: "\n")

        let sectionTranscript = Self.formatTranscript(sectionSegments)
        let userText = """
        \(context)

        Section transcript (\(String(format: "%.1f", section.startSeconds))s – \(String(format: "%.1f", section.endSeconds))s):
        \(sectionTranscript)

        Propose as many visual-aid anchors as this section genuinely warrants — zero is a valid answer. No upper limit; err on the side of adding one when the content clearly calls for it, and skip when it doesn't.
        """

        let messages: [ChatMessage] = [
            .system(Self.visualsSystemPrompt),
            .user(userText),
        ]

        let response: ChatCompletionResponse
        do {
            response = try await client.chatCompletion(
                messages: messages,
                tools: [Self.visualsTool],
                toolChoice: .required(name: "propose_visuals"),
                temperature: 0.3
            )
        } catch {
            print("⚠️ BRollSuggestionService phase-2 section \(sectionIndex) failed — \(error)")
            return []
        }

        guard let toolCall = response.toolCalls.first,
              let data = toolCall.function.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = args["suggestions"] as? [[String: Any]]
        else { return [] }

        return raw.compactMap { row in
            guard let kindRaw = row["kind"] as? String,
                  let prompt = (row["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty,
                  let rationale = (row["rationale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rationale.isEmpty,
                  let startRaw = (row["source_start_s"] as? Double) ?? (row["source_start_s"] as? Int).map(Double.init),
                  let endRaw = (row["source_end_s"] as? Double) ?? (row["source_end_s"] as? Int).map(Double.init)
            else { return nil }

            // Clamp to both the overall transcript AND the section
            // boundary — a Phase-2 call that drifted outside its own
            // section would indicate model confusion; pull it back in.
            let sectionStart = max(lowerBound, section.startSeconds)
            let sectionEnd = min(upperBound, section.endSeconds)
            let start = max(sectionStart, min(startRaw, sectionEnd))
            let end = max(start + 0.1, min(endRaw, sectionEnd))

            let kind = BRollSuggestion.Kind(rawValue: kindRaw) ?? .other
            return BRollSuggestion(
                sourceVideoID: sourceVideoID,
                sourceStartSeconds: start,
                sourceEndSeconds: end,
                kind: kind,
                prompt: prompt,
                rationale: rationale
            )
        }
    }

    // MARK: - Helpers

    private static func formatTranscript(_ segs: [TranscriptSegment]) -> String {
        segs.map { s in
            "[\(String(format: "%.1f", s.startSeconds))s–\(String(format: "%.1f", s.endSeconds))s] \(s.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Phase 1 prompt & tool

    private static let structureSystemPrompt: String = """
    You are reading a finished rough cut of a video and dividing its
    kept transcript into semantic SECTIONS — the way a human editor
    would outline the piece before deciding where visuals belong.

    Do NOT propose any visuals in this phase. Your only job is to
    understand what each section is doing.

    For every section return:
    • `start_s`, `end_s` — in source seconds, using the timestamps on
      each transcript line. A section must cover at least one full
      sentence; a single passing phrase isn't a section.
    • `role` — choose one of:
        intro          — opening hook, announces topic
        thesis         — the central claim / takeaway
        setup          — background / context before a point
        enumeration    — a list ("first…second…third", "三点是…")
        process        — a step-by-step flow / pipeline / how-to
        chronology     — events in time ("in 2020…2022…2024…")
        example        — a concrete story or anecdote supporting a claim
        comparison     — A vs B / before vs after / option 1 vs option 2
        quote          — a memorable single sentence worth pull-quoting
        data           — statistics, percentages, numeric results
        anecdote       — personal story, no clear teaching goal
        emotional      — venting, gratitude, purely reactive content
        transition     — segue / breath between bigger sections
        conclusion     — wrap-up, CTA, summary
        other          — doesn't fit cleanly (use sparingly)
    • `summary` — one to two sentences in the transcript's own language
      describing what the speaker does in this section.
    • `benefits_visual` — true ONLY if a visual aid (chart, animation,
      image, screen recording, map, data table) would clearly make
      this section clearer or more engaging. False for purely
      conversational / emotional / transition content.
    • `visual_reason` — one sentence. If `benefits_visual=true`, say
      what kind of visual pattern applies (enumeration → numbered list
      animation; process → flow diagram; data → chart; quote → pull-
      quote card; comparison → two-column; etc.). If false, say why a
      visual would be filler here.

    Favor fewer, larger sections over many tiny ones. A 3-minute
    speaker monologue is rarely more than 6–10 sections.

    Call `analyze_structure` exactly once.
    """

    private static let structureTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "analyze_structure",
            description: "Divide the kept transcript into semantic sections and flag visual-aid candidates.",
            parameters: .init(
                type: "object",
                properties: [
                    "sections": .init(
                        type: "array",
                        description: "Ordered sections covering the full transcript.",
                        items: .init(
                            type: "object",
                            properties: [
                                "start_s": .init(type: "number", description: "Section start in source seconds.", items: nil),
                                "end_s": .init(type: "number", description: "Section end in source seconds.", items: nil),
                                "role": .init(type: "string", description: "One of: intro, thesis, setup, enumeration, process, chronology, example, comparison, quote, data, anecdote, emotional, transition, conclusion, other.", items: nil),
                                "summary": .init(type: "string", description: "1–2 sentences describing this section's content.", items: nil),
                                "benefits_visual": .init(type: "boolean", description: "True iff a visual aid would genuinely help.", items: nil),
                                "visual_reason": .init(type: "string", description: "One sentence: what kind of visual, or why none fits.", items: nil),
                            ],
                            required: ["start_s", "end_s", "role", "summary", "benefits_visual", "visual_reason"]
                        )
                    )
                ],
                required: ["sections"],
                items: nil
            )
        )
    )

    // MARK: - Phase 2 prompt & tool

    private static let visualsSystemPrompt: String = """
    You are proposing concrete visual-aid anchors for a SINGLE section
    of a video that's already been flagged (in a prior pass) as likely
    to benefit from visuals. You receive the section's role, summary,
    neighbour context, and its full transcript.

    Your job: decide how many anchors this specific section warrants
    and return one entry per anchor. There is NO upper limit and NO
    lower limit — a tight two-sentence quote section may warrant one
    anchor; a long enumeration covering five items may warrant one big
    anchor that spans all five OR a few smaller ones. Use your judgment.
    If you genuinely don't think ANY anchor is justified (e.g. the
    phase-1 flag looks wrong in hindsight), return an empty list —
    that's a fine answer.

    Rules per anchor:
    - `kind` — one of: chart, animation, image, screenRecording,
      mapGraphic, dataTable, other. Favor `animation` for enumerations,
      processes, chronologies, pull-quotes, and A-vs-B comparisons —
      those render great as Remotion motion graphics.
    - `prompt` — a concrete natural-language description of what the
      visual should SHOW. Examples:
        "numbered list animation: 1) Prepare stories 2) Read the room
         3) Ask sharp questions"
        "horizontal step flow with arrows: Record → Transcribe → Edit
         → Publish"
        "pull-quote card: 'Stay hungry, stay foolish.' — Steve Jobs"
        "bar chart with three bars labelled 2022/2023/2024, flat
         style, dark background"
      Do NOT write Remotion template IDs — the downstream agent picks
      the template from your prompt.
    - `rationale` — one sentence: why this visual helps this moment.
    - `source_start_s`, `source_end_s` — span the ENTIRE content the
      visual represents, not just the triggering phrase. Stay within
      the section's own time range you were given. Rules of thumb:
        • enumeration / list → first mention through last item
        • process / step flow → first step through last step
        • chronology → first date through last date
        • quote / punchline → just that sentence
        • single stat / data point → just that mention
      When in doubt, err wider.

    Do NOT suggest generic mood B-roll, "talking head cutaway", or
    filler inserts. Visuals must teach the viewer something the speech
    alone doesn't already convey visually.

    Call `propose_visuals` exactly once with your list (possibly empty).
    """

    private static let visualsTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "propose_visuals",
            description: "Propose visual-aid anchors for a single section of the cut. Return as many or as few as the content actually warrants.",
            parameters: .init(
                type: "object",
                properties: [
                    "suggestions": .init(
                        type: "array",
                        description: "Anchors within this section. May be empty.",
                        items: .init(
                            type: "object",
                            properties: [
                                "source_start_s": .init(type: "number", description: "Start time in source seconds (within section bounds).", items: nil),
                                "source_end_s": .init(type: "number", description: "End time in source seconds (> start, within section bounds).", items: nil),
                                "kind": .init(type: "string", description: "One of: chart, animation, image, screenRecording, mapGraphic, dataTable, other.", items: nil),
                                "prompt": .init(type: "string", description: "Concrete description of the visual's content.", items: nil),
                                "rationale": .init(type: "string", description: "One-sentence reason this visual helps.", items: nil),
                            ],
                            required: ["source_start_s", "source_end_s", "kind", "prompt", "rationale"]
                        )
                    )
                ],
                required: ["suggestions"],
                items: nil
            )
        )
    )
}
