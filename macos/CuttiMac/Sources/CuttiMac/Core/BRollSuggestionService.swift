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
        guard let sections = await analyzeStructureWithFallback(
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

    /// Closed set of role labels the LLM is constrained to. Anything
    /// outside this set is normalized to `"other"` before persistence
    /// so downstream string-equality routing stays deterministic.
    static let allowedRoles: Set<String> = [
        "intro", "thesis", "setup", "enumeration", "process",
        "chronology", "example", "comparison", "quote", "data",
        "anecdote", "emotional", "transition", "conclusion", "other",
    ]

    /// Canonicalize a free-form role string from the LLM into the
    /// closed set above. Trims whitespace, lowercases, and collapses
    /// anything unrecognized to `"other"`. Preserves nil-ness so a
    /// section parser can still flag "no role" separately if it wants.
    static func canonicalRole(_ raw: String?) -> String {
        guard let raw else { return "other" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowedRoles.contains(trimmed) ? trimmed : "other"
    }

    /// Visual-benefit rating (replaces the old `benefits_visual: bool`).
    /// Phase 2 fires on `>= medium` so thesis/quote-eligible sections
    /// that the boolean used to drop now make it through.
    enum VisualBenefit: String, Sendable {
        case none, low, medium, high

        var rank: Int {
            switch self {
            case .none: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            }
        }

        static func parse(_ raw: Any?) -> VisualBenefit {
            // Tolerate the legacy `benefits_visual: bool` shape too —
            // a model that hasn't been updated to the new schema can
            // still produce useful output by mapping true→high, false→none.
            if let b = raw as? Bool { return b ? .high : .none }
            guard let s = (raw as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            else { return .none }
            return VisualBenefit(rawValue: s) ?? .none
        }
    }

    private struct Section: Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let role: String
        let summary: String
        let visualBenefit: VisualBenefit
        let visualReason: String

        var benefitsVisual: Bool { visualBenefit.rank >= VisualBenefit.medium.rank }
    }

    /// Run phase 1, retrying once at the more expensive `.creative` tier
    /// if the cheap-tier output looks degenerate (≤1 section on a
    /// non-trivial transcript, ≥80% of sections collapsed to `other`,
    /// or zero sections that would qualify for phase 2). Worst case
    /// pays for 2 phase-1 calls; common case pays for 1 cheap call.
    private func analyzeStructureWithFallback(
        keptSegments: [TranscriptSegment],
        lowerBound: Double,
        upperBound: Double
    ) async -> [Section]? {
        let cheap = await analyzeStructure(
            keptSegments: keptSegments,
            lowerBound: lowerBound,
            upperBound: upperBound,
            task: .firstCut
        )
        if let cheap, !Self.isDegenerate(sections: cheap, transcriptLines: keptSegments.count) {
            return cheap
        }
        // Either nil (call failed) or degenerate (model under-thought it).
        // One retry at .creative; we accept whatever comes back.
        if let cheap {
            print("ℹ️ BRollSuggestionService phase-1 cheap-tier output looked degenerate (\(cheap.count) sections); retrying at .creative")
        } else {
            print("ℹ️ BRollSuggestionService phase-1 cheap-tier failed; retrying at .creative")
        }
        return await analyzeStructure(
            keptSegments: keptSegments,
            lowerBound: lowerBound,
            upperBound: upperBound,
            task: .creative
        )
    }

    /// Heuristic for "the cheap model didn't really try". We trigger
    /// the .creative retry on:
    ///   • a non-trivial transcript (≥ 12 segments) collapsed to ≤1 section
    ///   • ≥ 80% of sections labeled `other`
    ///   • zero sections at `>= medium` visual benefit on a non-trivial transcript
    /// Short transcripts (< 12 segments) are allowed to legitimately
    /// produce a single section without triggering retry.
    private static func isDegenerate(sections: [Section], transcriptLines: Int) -> Bool {
        let nonTrivial = transcriptLines >= 12
        if sections.isEmpty { return true }
        if nonTrivial && sections.count <= 1 { return true }
        if !sections.isEmpty {
            let otherCount = sections.filter { $0.role == "other" }.count
            if Double(otherCount) / Double(sections.count) >= 0.8 { return true }
        }
        if nonTrivial {
            let medOrAbove = sections.filter { $0.benefitsVisual }.count
            if medOrAbove == 0 { return true }
        }
        return false
    }

    private func analyzeStructure(
        keptSegments: [TranscriptSegment],
        lowerBound: Double,
        upperBound: Double,
        task: OpenAIClient.TaskHint
    ) async -> [Section]? {
        let transcriptText = Self.formatTranscript(keptSegments)
        let messages: [ChatMessage] = [
            .system(Self.structureSystemPrompt),
            .user("Kept transcript (after first-cut). Segment it into semantic sections and rate which would benefit from a visual aid.\n\n" + transcriptText),
        ]

        let response: ChatCompletionResponse
        do {
            response = try await client.chatCompletion(
                messages: messages,
                tools: [Self.structureTool],
                toolChoice: .required(name: "analyze_structure"),
                temperature: 0.2,
                task: task
            )
        } catch {
            print("⚠️ BRollSuggestionService phase-1 (\(task.rawValue)) failed — \(error)")
            return nil
        }

        guard let toolCall = response.toolCalls.first,
              let data = toolCall.function.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = args["sections"] as? [[String: Any]]
        else { return nil }

        let parsed: [Section] = raw.compactMap { row in
            guard let summary = (row["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty,
                  let startRaw = (row["start_s"] as? Double) ?? (row["start_s"] as? Int).map(Double.init),
                  let endRaw = (row["end_s"] as? Double) ?? (row["end_s"] as? Int).map(Double.init)
            else { return nil }
            // Canonicalize role here so downstream consumers — both the
            // routing in the propose_visuals user message and the
            // persisted `BRollSuggestion.sectionRole` — never see an
            // off-schema string.
            let role = Self.canonicalRole(row["role"] as? String)
            // Tolerate either the new `visual_benefit: string` shape or
            // the legacy `benefits_visual: bool` shape so an older
            // deployment that hasn't been updated still produces useful
            // output instead of returning zero sections.
            let benefit = VisualBenefit.parse(row["visual_benefit"] ?? row["benefits_visual"])
            let start = max(lowerBound, min(startRaw, upperBound))
            let end = max(start + 0.1, min(endRaw, upperBound))
            let reason = ((row["visual_reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Section(
                startSeconds: start,
                endSeconds: end,
                role: role,
                summary: summary,
                visualBenefit: benefit,
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
        // Diversity awareness: tell this section about other ±2 sections
        // that ALSO got flagged as visual-benefitting. Phase-2 calls run
        // in parallel so they don't see each other's outputs, but they
        // can at least see that "the section before me also gets a
        // visual" and pick a register that isn't a third back-to-back
        // numbered list.
        let nearbyVisualPeers: [Section] = (max(0, sectionIndex - 2)...min(allSections.count - 1, sectionIndex + 2))
            .filter { $0 != sectionIndex }
            .map { allSections[$0] }
            .filter { $0.benefitsVisual }
        if !nearbyVisualPeers.isEmpty {
            let peerLines = nearbyVisualPeers.map { "  • [\($0.role)] \($0.summary)" }
            contextLines.append("Other nearby sections (±2) also flagged as visual-benefitting (vary your visual register so the viewer doesn't see three back-to-back lists):")
            contextLines.append(contentsOf: peerLines)
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
                temperature: 0.3,
                task: .creative
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

            // user_title / agent_hint are optional — the model may
            // legitimately omit them on `kind: .other` content where
            // there's nothing structured to extract. Empty strings are
            // treated the same as nil so a lazy `""` from the model
            // doesn't show up as a blank line in the popover.
            let userTitle: String? = {
                guard let raw = (row["user_title"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                return raw
            }()
            let agentHint: String? = {
                guard let raw = (row["agent_hint"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                return raw
            }()

            return BRollSuggestion(
                sourceVideoID: sourceVideoID,
                sourceStartSeconds: start,
                sourceEndSeconds: end,
                kind: kind,
                prompt: prompt,
                rationale: rationale,
                userTitle: userTitle,
                agentHint: agentHint,
                sectionRole: Self.canonicalRole(section.role)
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
    • `visual_benefit` — one of `none` | `low` | `medium` | `high`. A
      4-level rating of how much a visual aid (chart, animation, image,
      screen recording, map, data table) would clearly improve this
      section. Use `medium` or `high` when a visual would teach the
      viewer something the speech alone doesn't already convey
      visually; use `low` for "minor lift, optional"; use `none` for
      purely conversational / emotional / transition content. The
      downstream pass only follows up on `>= medium`.
    • `visual_reason` — one sentence. If `visual_benefit >= medium`,
      say what kind of visual pattern applies (enumeration → numbered
      list animation; process → flow diagram; data → chart; quote →
      pull-quote card; comparison → two-column; etc.). Otherwise, say
      why a visual would be filler here.

    Favor fewer, larger sections over many tiny ones. A 3-minute
    speaker monologue is rarely more than 6–10 sections.

    Call `analyze_structure` exactly once.
    """

    private static let structureTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "analyze_structure",
            description: "Divide the kept transcript into semantic sections and rate each one's visual-aid benefit on a 4-level scale.",
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
                                "summary": .init(type: "string", description: "1–2 sentences describing this section's content, in the transcript's own language.", items: nil),
                                "visual_benefit": .init(type: "string", description: "One of: none, low, medium, high. Downstream visual-proposal pass only fires on `>= medium`.", items: nil),
                                "visual_reason": .init(type: "string", description: "One sentence: what kind of visual, or why none fits.", items: nil),
                            ],
                            required: ["start_s", "end_s", "role", "summary", "visual_benefit", "visual_reason"]
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

    ## LANGUAGE — non-negotiable

    `prompt`, `rationale`, `user_title`, and `agent_hint` MUST be in
    the SAME language as the transcript. If the transcript is Chinese,
    these fields are Chinese. If the transcript mixes languages, match
    the dominant language of THIS section. The downstream UI shows
    `user_title` to the speaker in their own popover; mismatched
    language is a user-visible bug.

    ## Per-anchor fields

    - `kind` — one of: chart, animation, image, screenRecording,
      mapGraphic, dataTable, other. Favor `animation` for enumerations,
      processes, chronologies, pull-quotes, and A-vs-B comparisons —
      those render great as Remotion motion graphics.
    - `prompt` — concrete natural-language description of what the
      visual should SHOW. Treated as inspiration by the downstream
      agent (it may rephrase). 1–2 sentences.
    - `user_title` — short card title (≤ 20 characters incl. punctuation,
      ≤ 12 CJK glyphs) ready to display verbatim in the editor's
      popover. This is what the user sees and may edit. Make it crisp
      and human; this is NOT the place for a "horizontal step flow with
      arrows" engineering description — that goes in `prompt`.
    - `agent_hint` — extracted structured signal the next-stage agent
      can lift directly into overlay props. Format depends on `kind`
      / section role; pick the matching mini-format below or omit if
      the content doesn't fit any pattern (truly freeform `kind: other`
      can leave this empty):
        • enumeration  →  `item1 | item2 | item3`
        • process      →  `step1 → step2 → step3`
        • chronology   →  `2020: founded | 2022: series A | 2024: ipo`
        • quote        →  `"<sentence>" — <attribution>` (attribution
                          optional; omit the dash when absent)
        • comparison   →  `LEFT: <label> :: RIGHT: <label>`
        • data / chart →  `bar 2022=10 | bar 2023=14 | bar 2024=22`
        • image / map  →  may be empty
      Item labels MUST be in the transcript's language. Use literal
      wording from the transcript whenever possible (these are the
      words the speaker actually said — don't paraphrase).
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

    ## Examples

    English:
      kind: animation
      prompt: "numbered list animation: 1) Prepare stories 2) Read the room 3) Ask sharp questions"
      user_title: "Three small bets"
      agent_hint: "Prepare stories | Read the room | Ask sharp questions"
      rationale: "Speaker enumerates three concrete tactics; a numbered list cements the structure."

      kind: animation
      prompt: "horizontal step flow with arrows: Record → Transcribe → Edit → Publish"
      user_title: "The 4-step pipeline"
      agent_hint: "Record → Transcribe → Edit → Publish"

      kind: animation
      prompt: "pull-quote card: 'Stay hungry, stay foolish.' — Steve Jobs"
      user_title: "Stay hungry"
      agent_hint: "\"Stay hungry, stay foolish.\" — Steve Jobs"

      kind: chart
      prompt: "bar chart with three bars labelled 2022/2023/2024, flat style, dark background"
      user_title: "Revenue 2022–2024"
      agent_hint: "bar 2022=10 | bar 2023=14 | bar 2024=22"

    Chinese (note: every visible field in the speaker's language):
      kind: animation
      prompt: "三步流程动画：录制 → 转写 → 剪辑"
      user_title: "三步剪辑流程"
      agent_hint: "录制 → 转写 → 剪辑"
      rationale: "讲者明确说了"先录、再转写、最后剪辑"，流程动画把这条线显现出来。"

      kind: animation
      prompt: "对比卡片：本地剪辑 vs 云端剪辑"
      user_title: "本地 vs 云端"
      agent_hint: "LEFT: 本地剪辑 :: RIGHT: 云端剪辑"
      rationale: "整段都在对比两种方案的取舍，左右两栏比纯口述清楚。"

    ## Diversity

    If a sibling section nearby (you'll see them under "Other nearby
    sections (±2) also flagged as visual-benefitting") already implies
    a list-style visual, prefer a different register here unless the
    content strictly requires another list. Three back-to-back
    SequenceSteps overlays make the viewer numb.

    ## Anti-filler

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
                                "prompt": .init(type: "string", description: "Concrete description of the visual's content, in the transcript's language.", items: nil),
                                "user_title": .init(type: "string", description: "Short card title (≤20 chars / ≤12 CJK glyphs) shown to the user in the popover, in the transcript's language.", items: nil),
                                "agent_hint": .init(type: "string", description: "Extracted structured signal for the next-stage agent, in the transcript's language. Use the per-kind mini-format described in the system prompt; omit (empty string) for kind:other or freeform image/map content.", items: nil),
                                "rationale": .init(type: "string", description: "One-sentence reason this visual helps, in the transcript's language.", items: nil),
                            ],
                            required: ["source_start_s", "source_end_s", "kind", "prompt", "user_title", "rationale"]
                        )
                    )
                ],
                required: ["suggestions"],
                items: nil
            )
        )
    )
}
