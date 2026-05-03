import Foundation
import CuttiKit

/// Agent-facing `translate_subtitles` tool — lets the LLM populate
/// `SubtitleEntry.translations[targetLocale]` for every cue on the
/// timeline (or a caller-chosen subset) by batching the source text
/// through the same OpenAI client every other agent tool uses.
///
/// The tool itself is deliberately narrow: it is *only* responsible for
/// producing translation strings and writing them onto cues. The
/// bilingual-display toggle (`SubtitleStyle.bilingual`) is a separate
/// concern the agent sets via `edit_timeline` before or after calling
/// this tool — the renderer decides whether to actually show the
/// translation line based on the style.
struct TranslateSubtitlesRequest: Equatable, Sendable {
    /// BCP-47 locale to translate into (e.g. `"zh-Hans"`, `"ja"`).
    /// Normalized through `Locale(identifier:)` before use so
    /// formatting variations (`zh-hans`, `zh_Hans`, `zh-Hans-CN`) all
    /// resolve onto the same `"zh-Hans"` / `"ja"` canonical key.
    var targetLocale: String

    /// Optional subset filter. When present, only cues whose id appears
    /// here are translated. Empty / nil means "every cue on every
    /// primary-track segment".
    var cueIDs: [UUID]?

    /// When true, re-translate cues that already have an entry for
    /// `targetLocale`. Default false keeps the tool idempotent so the
    /// agent can safely call it again after a partial failure.
    var force: Bool

    static func parse(from args: [String: Any]) -> TranslateSubtitlesRequest? {
        guard let raw = (args["target_locale"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        let normalized = Self.normalize(locale: raw)
        guard !normalized.isEmpty else { return nil }

        let cueIDs: [UUID]?
        if let strings = args["cue_ids"] as? [String] {
            let parsed = strings.compactMap(UUID.init(uuidString:))
            cueIDs = parsed.isEmpty ? nil : parsed
        } else {
            cueIDs = nil
        }

        let force = (args["force"] as? Bool) ?? false

        return TranslateSubtitlesRequest(
            targetLocale: normalized,
            cueIDs: cueIDs,
            force: force
        )
    }

    /// Canonicalize a BCP-47 tag. Delegates to the shared
    /// `BilingualDisplayOptions.normalizeLocale` so the translate tool
    /// and the style patch / renderers always agree on a single
    /// dictionary key — asymmetric normalization silently blanks the
    /// bilingual second line.
    static func normalize(locale input: String) -> String {
        BilingualDisplayOptions.normalizeLocale(input)
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "translate_subtitles",
            description: """
            Translate every subtitle cue on the timeline (or a subset) \
            into the requested BCP-47 locale. Translations are stored \
            additively on each cue — the original language line is never \
            replaced, so bilingual display stays a rendering choice on \
            `SubtitleStyle.bilingual`. Call this after (or before) \
            `edit_timeline` flips `subtitle_style.bilingual` so the \
            bilingual subtitles show up in preview and export. Idempotent: \
            cues already carrying a translation for the target locale are \
            skipped unless `force=true`.
            """,
            parameters: .init(
                type: "object",
                properties: [
                    "target_locale": .init(
                        type: "string",
                        description: "BCP-47 tag such as \"zh-Hans\", \"zh-Hant\", \"en-US\", \"ja\", \"ko\", \"es\", \"fr\", \"de\", \"ru\", \"pt\", \"it\". Required.",
                        items: nil
                    ),
                    "cue_ids": .init(
                        type: "array",
                        description: "Optional UUID subset. When omitted the tool translates every cue on every primary segment.",
                        items: ToolDefinition.JSONSchema.ItemSchema(
                            type: "string",
                            properties: nil,
                            required: nil
                        )
                    ),
                    "force": .init(
                        type: "boolean",
                        description: "When true, re-translate cues that already have an entry for `target_locale`. Default false.",
                        items: nil
                    ),
                ],
                required: ["target_locale"],
                items: nil
            )
        )
    )
}

/// Shape the LLM-facing tool result takes so the agent can summarize
/// across retries. Serialized via `AgentToolJSON.encode` on the way back
/// to the model.
struct TranslateSubtitlesToolResult: Codable {
    let ok: Bool
    /// Locale the translations are stored under.
    let locale: String
    /// Cues we attempted to translate (missing-or-forced).
    let attempted: Int
    /// Cues with a populated translation after this call.
    let translated: Int
    /// Cues skipped because they already carried a translation (only
    /// present when `force=false`).
    let skipped: Int
    /// Cues whose translation round-trip failed after retries. The
    /// agent can surface these to the user so they know which cues
    /// still need attention.
    let failedCueIDs: [String]
}

/// Translation batch engine — a plain actor (not @MainActor) so the
/// agent tool can spin up concurrent OpenAI calls without blocking the
/// UI thread.
///
/// Responsibilities:
/// 1. Splits the input list into batches of `batchSize` cues.
/// 2. Runs at most `maxConcurrency` batches at a time via a TaskGroup.
/// 3. Returns a `[cueID: translation]` map and the ids of cues that
///    failed after one retry. The caller is responsible for writing
///    the translations back onto the project on the main actor.
actor SubtitleTranslationEngine {

    struct CueInput: Sendable {
        let id: UUID
        let text: String
    }

    struct BatchOutcome: Sendable {
        /// cueID → translated text. Missing keys mean "failed".
        let translations: [UUID: String]
        let failedIDs: [UUID]
    }

    let client: OpenAIClient
    /// LLM model override. Nil uses `client.configuration.model` (the
    /// same default every other tool uses). Translations benefit from a
    /// slightly warmer temperature than timeline-editing calls so the
    /// target text reads natural rather than literal.
    let temperature: Double
    let batchSize: Int
    let maxConcurrency: Int

    init(
        client: OpenAIClient,
        temperature: Double = 0.3,
        batchSize: Int = 20,
        maxConcurrency: Int = 3
    ) {
        self.client = client
        self.temperature = temperature
        self.batchSize = batchSize
        self.maxConcurrency = maxConcurrency
    }

    /// Translate `cues` into `locale`, reporting progress at batch
    /// granularity via `onBatchComplete`. Callbacks run on whatever
    /// executor the caller is on — the engine itself is isolated as an
    /// actor so progress ordering is sequential even when batches run
    /// concurrently.
    func translate(
        cues: [CueInput],
        into locale: String,
        onBatchComplete: (@Sendable (_ completedSoFar: Int, _ total: Int) async -> Void)? = nil
    ) async -> BatchOutcome {
        guard !cues.isEmpty else {
            return BatchOutcome(translations: [:], failedIDs: [])
        }

        // Chunk into batches of `batchSize`.
        var batches: [[CueInput]] = []
        var i = 0
        while i < cues.count {
            let end = min(i + batchSize, cues.count)
            batches.append(Array(cues[i..<end]))
            i = end
        }

        var aggregated: [UUID: String] = [:]
        var failed: [UUID] = []
        var completed = 0
        let total = cues.count
        let concurrency = max(1, maxConcurrency)

        // Semi-manual TaskGroup windowing: keep `concurrency` tasks in
        // flight at any time. Swift's TaskGroup has no built-in
        // concurrency cap, so we add one by only spawning a new task
        // once an old one has finished.
        await withTaskGroup(of: BatchOutcome.self) { group in
            var batchIdx = 0
            var inflight = 0

            // Launch initial batch of concurrent tasks.
            while batchIdx < batches.count && inflight < concurrency {
                let batch = batches[batchIdx]
                batchIdx += 1
                inflight += 1
                group.addTask { [client, temperature] in
                    await Self.runOneBatch(
                        batch: batch,
                        locale: locale,
                        client: client,
                        temperature: temperature
                    )
                }
            }

            // Drain-and-refill loop: whenever a task finishes, kick
            // off the next one until `batches` is exhausted.
            while let outcome = await group.next() {
                inflight -= 1
                for (id, text) in outcome.translations {
                    aggregated[id] = text
                }
                failed.append(contentsOf: outcome.failedIDs)
                completed += outcome.translations.count + outcome.failedIDs.count
                if let cb = onBatchComplete {
                    await cb(completed, total)
                }
                if batchIdx < batches.count {
                    let batch = batches[batchIdx]
                    batchIdx += 1
                    inflight += 1
                    group.addTask { [client, temperature] in
                        await Self.runOneBatch(
                            batch: batch,
                            locale: locale,
                            client: client,
                            temperature: temperature
                        )
                    }
                }
            }
        }

        return BatchOutcome(translations: aggregated, failedIDs: failed)
    }

    /// Translate one batch through OpenAI, with one retry on failure.
    /// Parses the model's JSON reply into a `[cueID: text]` map and
    /// returns any ids that were absent from the reply as failures.
    private static func runOneBatch(
        batch: [CueInput],
        locale: String,
        client: OpenAIClient,
        temperature: Double
    ) async -> BatchOutcome {
        let systemPrompt = """
        You are a professional subtitle translator. Translate each cue into \
        the target locale preserving tone, register, punctuation style, and \
        any placeholders / stop-words verbatim. Do not summarize, shorten, \
        or re-segment the cues. Return ONE JSON object whose keys are the \
        cue UUIDs and whose values are the translated strings. No prose, no \
        code fences, no trailing explanation.
        Target locale (BCP-47): \(locale)
        """

        // Build a compact JSON array for the user turn — keys are the
        // cue UUIDs (short enough that each cue fits in ~50 tokens).
        var lines: [String] = []
        for cue in batch {
            // Escape double quotes / backslashes minimally; the model
            // deals fine with the rest.
            let escaped = cue.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("  \"\(cue.id.uuidString)\": \"\(escaped)\"")
        }
        let userContent = "{\n" + lines.joined(separator: ",\n") + "\n}"

        let messages: [ChatMessage] = [
            .system(systemPrompt),
            .user(userContent)
        ]

        for attempt in 0..<2 {
            do {
                let response = try await client.chatCompletion(
                    messages: messages,
                    tools: nil,
                    toolChoice: nil,
                    temperature: temperature,
                    task: .translate
                )
                guard let content = response.content?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty
                else {
                    throw OpenAIClientError.networkError("empty completion")
                }
                if let parsed = parseResponse(content, expected: batch) {
                    // Success when we got at least one cue back — partial
                    // maps are treated as success for the returned ids
                    // and failure for the missing ones.
                    let returnedIDs = Set(parsed.keys)
                    let failedIDs = batch.compactMap { cue in
                        returnedIDs.contains(cue.id) ? nil : cue.id
                    }
                    return BatchOutcome(
                        translations: parsed,
                        failedIDs: failedIDs
                    )
                }
                // Parsing failed — retry once. Log so we don't lose the
                // hint when the retry also fails; the aggregate result
                // only reports failed cue ids, not parse context.
                print("⚠️ SubtitleTranslationEngine: parse failed (attempt \(attempt + 1), locale=\(locale), cues=\(batch.count))")
            } catch is CancellationError {
                // Caller cancelled — treat as a clean empty result, not
                // a translation failure. Downstream writes the cue back
                // unchanged on the next attempt.
                return BatchOutcome(translations: [:], failedIDs: [])
            } catch {
                // Never swallow silently: surfaces the provider error so
                // the operator can tell "5 cues failed" apart from
                // "provider returned 401" or "network timed out". The
                // project convention is `print("⚠️ ...")`.
                print("⚠️ SubtitleTranslationEngine: batch failed (attempt \(attempt + 1), locale=\(locale), cues=\(batch.count)): \(error.localizedDescription)")
                if attempt == 1 {
                    return BatchOutcome(
                        translations: [:],
                        failedIDs: batch.map(\.id)
                    )
                }
            }
        }
        return BatchOutcome(translations: [:], failedIDs: batch.map(\.id))
    }

    /// Extract `[UUID: String]` from a model reply. Tolerates markdown
    /// fences ("```json"), stray prose before the JSON object, and
    /// both flat-dict and wrapped `{"translations": {...}}` shapes.
    private static func parseResponse(
        _ raw: String,
        expected: [CueInput]
    ) -> [UUID: String]? {
        // Strip code fences if the model ignored the instruction.
        var trimmed = raw
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .drop(while: { $0 == "`" })
                .drop(while: { $0 != "{" && $0 != "\n" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("json") { trimmed.removeFirst(4) }
            // Drop the trailing ``` if present.
            if let range = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<range.lowerBound])
            }
        }
        // Find the first `{` and last `}` — anything outside that
        // range is prose the model sometimes adds.
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else { return nil }
        let jsonSlice = String(trimmed[start...end])

        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        // Accept either `{"uuid": "text", ...}` or
        // `{"translations": {"uuid": "text", ...}}`.
        let flat: [String: Any]?
        if let dict = obj as? [String: Any] {
            if let nested = dict["translations"] as? [String: Any] {
                flat = nested
            } else {
                flat = dict
            }
        } else {
            flat = nil
        }
        guard let map = flat else { return nil }

        var out: [UUID: String] = [:]
        out.reserveCapacity(map.count)
        for (key, value) in map {
            guard let uuid = UUID(uuidString: key),
                  let text = value as? String
            else { continue }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }
            out[uuid] = trimmedText
        }

        // If none of the returned ids line up with what we asked for,
        // the model probably hallucinated the entire payload. Treat as
        // parse failure so the retry kicks in.
        let expectedIDs = Set(expected.map(\.id))
        let overlap = out.keys.filter { expectedIDs.contains($0) }
        guard !overlap.isEmpty else { return nil }
        return out.filter { expectedIDs.contains($0.key) }
    }
}
