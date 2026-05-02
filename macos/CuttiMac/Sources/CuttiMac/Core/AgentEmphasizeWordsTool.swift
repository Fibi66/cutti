import Foundation
import CuttiKit

/// Agent-facing `emphasize_words` tool — lets the LLM apply per-run
/// styling (weight / size / color / underline / highlight) to selected
/// words or character ranges inside a single subtitle cue.
///
/// The tool is deliberately synchronous and non-LLM: it does not hop
/// back through OpenAI. The agent provides structured args in the first
/// call, the main-actor dispatcher in `MediaCoreViewModel` resolves the
/// cue, maps `words` / `utf16_ranges` to concrete UTF-16 ranges, and
/// delegates to `MediaCoreViewModel.applyEmphasisToSubtitle(...)`.
///
/// Design notes:
/// - `words` is the preferred input: each entry is a substring search
///   (UTF-16) against the cue text. Every occurrence is emphasized,
///   which lines up with how users phrase requests ("把所有的'重要'标红",
///   "emphasize every 'okay'").
/// - `utf16_ranges` is the escape hatch when the LLM has already
///   computed absolute offsets (e.g. after a query tool returned them).
/// - `style` mirrors `SubtitleRunStyle`: every field is optional so the
///   tool composes cleanly with multi-intent requests — "make X red AND
///   Y bold" is two separate calls, neither of which wipes the other.
/// - `replace=true` switches from merge to overwrite: it zeros every
///   other run field on the matched ranges. Useful for "clear just
///   these words' styling" but deliberately not the default.
/// - `clear_all=true` is a shortcut for wiping every run on the cue.
///   When set, style / words / ranges are ignored.
struct EmphasizeWordsRequest: Equatable, Sendable {
    let cueID: UUID?
    let atTime: Double?
    let words: [String]
    let utf16Ranges: [NSRange]
    let style: SubtitleRunStyle
    let replace: Bool
    let clearAll: Bool

    /// True when no targeting info was supplied (no words, no ranges,
    /// no clear_all). Parsing rejects these before dispatch.
    var hasTargeting: Bool {
        clearAll || !words.isEmpty || !utf16Ranges.isEmpty
    }

    static func parse(from args: [String: Any]) -> EmphasizeWordsRequest? {
        let cueID = (args["cue_id"] as? String).flatMap(UUID.init(uuidString:))
        let atTime = Self.number(args["at_time"])

        guard cueID != nil || atTime != nil else { return nil }

        let clearAll = (args["clear_all"] as? Bool) ?? false
        let replace = (args["replace"] as? Bool) ?? false

        let words: [String] = {
            guard let raw = args["words"] as? [String] else { return [] }
            return raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }()

        var ranges: [NSRange] = []
        // Preferred shape (matches the schema we publish): array of
        // {start, end} objects.
        if let rawRanges = args["utf16_ranges"] as? [[String: Any]] {
            for pair in rawRanges {
                guard let start = Self.integer(pair["start"]),
                      let end = Self.integer(pair["end"]),
                      end > start
                else { continue }
                ranges.append(NSRange(location: start, length: end - start))
            }
        }
        // Legacy/tolerant shape: array of [start, end] pairs. Older
        // prompts and the existing tests still emit this form, so keep
        // accepting it instead of failing the whole call.
        if ranges.isEmpty, let rawRanges = args["utf16_ranges"] as? [[Any]] {
            for pair in rawRanges {
                guard pair.count == 2,
                      let start = Self.integer(pair[0]),
                      let end = Self.integer(pair[1]),
                      end > start
                else { continue }
                ranges.append(NSRange(location: start, length: end - start))
            }
        }

        let style = Self.parseStyle(args["style"] as? [String: Any]) ?? .empty

        let req = EmphasizeWordsRequest(
            cueID: cueID,
            atTime: atTime,
            words: words,
            utf16Ranges: ranges,
            style: style,
            replace: replace,
            clearAll: clearAll
        )

        guard req.hasTargeting else { return nil }
        // When not clearing, we need *some* style override — otherwise
        // the call would be a no-op that still pushes a revision. Reject
        // early so the agent sees the error and retries with a real style.
        if !clearAll, style.isEmpty { return nil }
        return req
    }

    // MARK: Style parsing

    static func parseStyle(_ raw: [String: Any]?) -> SubtitleRunStyle? {
        guard let raw else { return nil }
        var style = SubtitleRunStyle.empty

        if let fontName = (raw["font_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fontName.isEmpty {
            style.fontName = fontName
        }

        if let mult = number(raw["size_multiplier"]) {
            // Clamp to a reasonable range so a hallucinated 99x doesn't
            // blow out the layout.
            style.sizeMultiplier = max(0.25, min(4.0, mult))
        }

        if let weightRaw = (raw["weight"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let weight = SubtitleRunStyle.Weight(rawValue: weightRaw) {
            style.weight = weight
        }

        if let hex = raw["text_color"] as? String,
           let color = parseHexColor(hex) {
            style.textColor = color
        }

        if let hex = raw["highlight_background"] as? String,
           let color = parseHexColor(hex) {
            style.highlightBackground = color
        }

        if let underline = raw["underline"] as? Bool {
            style.underline = underline
        }

        return style
    }

    /// Parse `#RRGGBB`, `#RRGGBBAA`, `RRGGBB`, or `RRGGBBAA` into an
    /// sRGB RGBAColor. Returns nil for anything else so the agent can
    /// retry with a well-formed value.
    static func parseHexColor(_ raw: String) -> SubtitleStyle.RGBAColor? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        guard let value = UInt64(s, radix: 16) else { return nil }

        let r: Double
        let g: Double
        let b: Double
        let a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        } else {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        }
        return SubtitleStyle.RGBAColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func number(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? NSNumber { return v.doubleValue }
        if let v = raw as? String, let parsed = Double(v) { return parsed }
        return nil
    }

    private static func integer(_ raw: Any?) -> Int? {
        if let v = raw as? Int { return v }
        if let v = raw as? Double { return Int(v) }
        if let v = raw as? NSNumber { return v.intValue }
        if let v = raw as? String, let parsed = Int(v) { return parsed }
        return nil
    }

    // MARK: Tool definition

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "emphasize_words",
            description: """
            Apply per-word styling (bold/size/color/underline/highlight) \
            to selected words inside one subtitle cue. Use this for \
            "make 'important' red", "bold 我 in every cue" (call once per \
            cue), "highlight 'now' yellow". Every style field is optional \
            and composes additively — calling the tool twice with \
            different fields layers the overrides (CSS-style). Pass \
            `replace=true` to overwrite existing run styles on the \
            matched ranges instead of merging. Pass `clear_all=true` to \
            reset the whole cue to plain text (ignores other params). \
            Prefer `words` (substring search) over `utf16_ranges` \
            (explicit offsets). Target the cue with `cue_id` (from \
            get_timeline_summary / find_by_transcript) or `at_time` \
            (timeline seconds).
            """,
            parameters: .init(
                type: "object",
                properties: [
                    "cue_id": .init(
                        type: "string",
                        description: "Target subtitle cue UUID. Prefer this over `at_time` when known.",
                        items: nil
                    ),
                    "at_time": .init(
                        type: "number",
                        description: "Final-video timeline seconds; resolves to the cue active at that moment. Fallback when `cue_id` is unknown.",
                        items: nil
                    ),
                    "words": .init(
                        type: "array",
                        description: "Array of substrings to find inside the cue text. Every occurrence (case-sensitive UTF-16 match) is emphasized. Supports single characters (\"我\"), words (\"important\"), and phrases (\"really cool\"). Use the exact casing from the cue text.",
                        items: ToolDefinition.JSONSchema.ItemSchema(
                            type: "string",
                            properties: nil,
                            required: nil
                        )
                    ),
                    "utf16_ranges": .init(
                        type: "array",
                        description: "Explicit UTF-16 offset ranges inside the cue text. Each item is an object with `start` (inclusive) and `end` (exclusive). Use only when a prior tool returned offsets; otherwise prefer `words`.",
                        items: ToolDefinition.JSONSchema.ItemSchema(
                            type: "object",
                            properties: [
                                "start": ToolDefinition.JSONSchema.Property(
                                    type: "integer",
                                    description: "Inclusive UTF-16 start offset.",
                                    items: nil
                                ),
                                "end": ToolDefinition.JSONSchema.Property(
                                    type: "integer",
                                    description: "Exclusive UTF-16 end offset; must be greater than `start`.",
                                    items: nil
                                ),
                            ],
                            required: ["start", "end"]
                        )
                    ),
                    "style": .init(
                        type: "object",
                        description: """
                        Style overrides. All fields optional. `weight`: \
                        regular|medium|semibold|bold|heavy|black. \
                        `size_multiplier`: relative to cue size (0.25–4.0, \
                        clamped; e.g. 1.4 = 40% bigger). `text_color`: \
                        hex string like \"#FFD700\" or \"#FFD700FF\". \
                        `highlight_background`: hex string for the \
                        pill-shaped highlight behind the glyphs. \
                        `underline`: boolean. `font_name`: PostScript \
                        font family (usually omit).
                        """,
                        items: nil
                    ),
                    "replace": .init(
                        type: "boolean",
                        description: "Overwrite existing run styles on the matched ranges (default false = merge).",
                        items: nil
                    ),
                    "clear_all": .init(
                        type: "boolean",
                        description: "When true, wipes every emphasis on the cue and ignores style / words / ranges.",
                        items: nil
                    ),
                ],
                required: [],
                items: nil
            )
        )
    )
}

/// LLM-facing JSON result shape. Encoded via `AgentToolJSON.encode`.
struct EmphasizeWordsToolResult: Codable {
    let ok: Bool
    let cueID: String
    let rangesApplied: Int
    let wordsMatched: [String]
    let wordsNotFound: [String]
    let cleared: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case cueID = "cue_id"
        case rangesApplied = "ranges_applied"
        case wordsMatched = "words_matched"
        case wordsNotFound = "words_not_found"
        case cleared
    }
}

/// Pure resolver for `words` → UTF-16 ranges inside a cue. Extracted
/// from the dispatcher so it can be unit-tested without standing up a
/// whole MediaCoreViewModel.
///
/// Semantics:
/// - Each word is searched as a literal substring in the cue text.
/// - Every non-overlapping occurrence is collected (a second occurrence
///   overlapping the first is skipped; second occurrence adjacent to
///   the first is kept).
/// - Returned ranges are sorted ascending and de-duplicated, so the VM
///   can hand them straight to `applyEmphasisToSubtitle(...)`.
/// - `wordsNotFound` contains input words with zero matches, in
///   original order, de-duplicated.
struct EmphasizeWordsMatcher {
    struct Result: Equatable {
        let ranges: [NSRange]
        let wordsMatched: [String]
        let wordsNotFound: [String]
    }

    static func resolve(words: [String], inCueText cueText: String) -> Result {
        let ns = cueText as NSString
        let haystackLen = ns.length

        var seen: Set<String> = []  // de-dup preserving first-seen order
        var dedupedWords: [String] = []
        for w in words where !seen.contains(w) {
            seen.insert(w)
            dedupedWords.append(w)
        }

        var allRanges: [NSRange] = []
        var matched: [String] = []
        var notFound: [String] = []

        for word in dedupedWords {
            let needle = word as NSString
            guard needle.length > 0, needle.length <= haystackLen else {
                notFound.append(word)
                continue
            }

            var searchStart = 0
            var foundAny = false
            while searchStart < haystackLen {
                let searchRange = NSRange(
                    location: searchStart,
                    length: haystackLen - searchStart
                )
                let hit = ns.range(of: word, options: [.literal], range: searchRange)
                if hit.location == NSNotFound { break }
                allRanges.append(hit)
                foundAny = true
                searchStart = hit.location + max(hit.length, 1)
            }

            if foundAny {
                matched.append(word)
            } else {
                notFound.append(word)
            }
        }

        // Sort + drop exact duplicates + drop ranges that are fully
        // contained in an earlier range.
        let sorted = allRanges.sorted { a, b in
            if a.location != b.location { return a.location < b.location }
            return a.length > b.length
        }
        var compact: [NSRange] = []
        for r in sorted {
            if let last = compact.last,
               NSMaxRange(last) >= NSMaxRange(r),
               last.location <= r.location {
                continue
            }
            compact.append(r)
        }

        return Result(ranges: compact, wordsMatched: matched, wordsNotFound: notFound)
    }
}
