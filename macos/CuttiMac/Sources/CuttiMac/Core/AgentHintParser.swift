import Foundation

/// Parses the structured `agent_hint` mini-format produced by the
/// Stage-1 B-roll suggestion service into a typed value the Stage-2
/// overlay agent can consume directly.
///
/// The mini-format protocol is defined in `BRollSuggestionService.swift`
/// (search for "agent_hint — extracted structured signal"). Keep these
/// two files in sync — adding a new format here without updating the
/// upstream system prompt produces orphan branches; the reverse means
/// the Stage-2 instruction silently falls back to `.freeform` when it
/// could be using a richer structure.
enum ParsedAgentHint: Equatable {
    /// `item1 | item2 | item3` — bullets / takeaways with no implied order.
    case enumeration(items: [String])
    /// `step1 → step2 → step3` — directed flow.
    case process(steps: [String])
    /// `2020: founded | 2022: series A | 2024: ipo` — chronological entries.
    case chronology(entries: [ChronologyEntry])
    /// `"<sentence>" — <attribution>` (attribution optional).
    case quote(text: String, attribution: String?)
    /// `LEFT: <label> :: RIGHT: <label>`
    case comparison(left: String, right: String)
    /// `bar 2022=10 | bar 2023=14 | bar 2024=22`
    case data(bars: [DataBar])
    /// Hint was non-empty but didn't match any mini-format. Stage-2
    /// shows it as inspiration but warns the agent it still needs to
    /// distill rather than lift verbatim.
    case freeform(text: String)
    /// No agent_hint, or trimmed to empty. Stage-2 falls back to
    /// transcript-driven extraction with a strong "no filler" warning.
    case empty

    struct ChronologyEntry: Equatable {
        let year: String
        let label: String
    }

    struct DataBar: Equatable {
        let label: String
        let value: Double
    }
}

enum AgentHintParser {

    /// Parse a Stage-1 `agent_hint` payload using the section role as
    /// a routing nudge (e.g. role:"process" prefers `→` even when `|`
    /// is also present). Returns `.empty` for nil/blank input and
    /// `.freeform` when the input is non-empty but doesn't match any
    /// mini-format.
    static func parse(_ raw: String?, role: String?) -> ParsedAgentHint {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let canonical = (role ?? "other").lowercased()

        // Quote first — quote payloads can contain "|" inside the
        // sentence, so the pipe-split would mangle them.
        if canonical == "quote" || isLikelyQuote(trimmed) {
            if let q = parseQuote(trimmed) { return q }
        }

        // Comparison: distinctive `::` separator.
        if canonical == "comparison" || trimmed.contains("::") {
            if let c = parseComparison(trimmed) { return c }
        }

        // Data: "bar X=N" segments.
        if canonical == "data" || canonical == "chart" || isLikelyData(trimmed) {
            if let d = parseData(trimmed) { return d }
        }

        // Process: arrow-separated steps. Use full-width arrow tolerance.
        let arrowSeparated = splitByArrow(trimmed)
        if (canonical == "process" || canonical == "flow") && arrowSeparated.count >= 2 {
            return .process(steps: arrowSeparated)
        }
        if arrowSeparated.count >= 2 {
            return .process(steps: arrowSeparated)
        }

        // Chronology: pipe segments where each begins with a 4-digit year.
        if canonical == "chronology" || isLikelyChronology(trimmed) {
            if let ch = parseChronology(trimmed) { return ch }
        }

        // Default: pipe-delimited enumeration.
        let pipeItems = splitByPipe(trimmed)
        if pipeItems.count >= 2 {
            // Process role with pipe instead of arrow → still treat as
            // process. Otherwise generic enumeration.
            if canonical == "process" || canonical == "flow" {
                return .process(steps: pipeItems)
            }
            return .enumeration(items: pipeItems)
        }

        return .freeform(text: trimmed)
    }

    // MARK: - Sub-parsers

    private static func isLikelyQuote(_ s: String) -> Bool {
        let normalized = normalizeQuotes(s)
        let count = normalized.filter { $0 == "\"" }.count
        return count >= 2 && normalized.hasPrefix("\"")
    }

    private static func isLikelyData(_ s: String) -> Bool {
        // "bar foo=1" anywhere
        return s.range(
            of: #"(?i)\bbar\s+\S+\s*=\s*[0-9]"#,
            options: .regularExpression
        ) != nil
    }

    private static func isLikelyChronology(_ s: String) -> Bool {
        // First non-space chars are 4 digits + ":" or "：".
        return s.range(
            of: #"^\s*\d{4}(?:[-–]\d{2,4})?\s*[:：]"#,
            options: .regularExpression
        ) != nil
    }

    private static func parseQuote(_ raw: String) -> ParsedAgentHint? {
        let s = normalizeQuotes(raw)
        guard let q1 = s.firstIndex(of: "\""),
              let q2 = s.index(q1, offsetBy: 1, limitedBy: s.endIndex).flatMap({ s.range(of: "\"", range: $0..<s.endIndex)?.lowerBound })
        else { return nil }
        let text = String(s[s.index(after: q1)..<q2])
        guard !text.isEmpty else { return nil }
        // Attribution: anything after the closing quote, stripped of
        // dash separators and surrounding whitespace.
        let tail = String(s[s.index(after: q2)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attribution: String? = {
            let cleaned = tail
                .trimmingCharacters(in: CharacterSet(charactersIn: "—–-").union(.whitespacesAndNewlines))
            return cleaned.isEmpty ? nil : cleaned
        }()
        return .quote(text: text, attribution: attribution)
    }

    private static func parseComparison(_ raw: String) -> ParsedAgentHint? {
        let parts = raw.components(separatedBy: "::")
        guard parts.count == 2 else { return nil }
        let left = stripSidePrefix(parts[0], prefixes: ["LEFT", "左", "Left"])
        let right = stripSidePrefix(parts[1], prefixes: ["RIGHT", "右", "Right"])
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return .comparison(left: left, right: right)
    }

    private static func stripSidePrefix(_ side: String, prefixes: [String]) -> String {
        var s = side.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in prefixes where s.uppercased().hasPrefix(p.uppercased()) {
            s = String(s.dropFirst(p.count))
            s = s.trimmingCharacters(
                in: CharacterSet(charactersIn: ":：").union(.whitespacesAndNewlines)
            )
            break
        }
        return s
    }

    private static func parseChronology(_ raw: String) -> ParsedAgentHint? {
        let segments = splitByPipe(raw)
        guard !segments.isEmpty else { return nil }
        var entries: [ParsedAgentHint.ChronologyEntry] = []
        for seg in segments {
            guard let r = seg.range(
                of: #"^(\d{4}(?:[-–]\d{2,4})?)\s*[:：]\s*(.+)$"#,
                options: .regularExpression
            ) else { continue }
            let m = String(seg[r])
            // Split on the first colon (full-width or ASCII).
            guard let colonIndex = m.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let year = String(m[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = String(m[m.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !year.isEmpty, !label.isEmpty else { continue }
            entries.append(.init(year: year, label: label))
        }
        guard entries.count >= 2 else { return nil }
        return .chronology(entries: entries)
    }

    private static func parseData(_ raw: String) -> ParsedAgentHint? {
        let segments = splitByPipe(raw)
        var bars: [ParsedAgentHint.DataBar] = []
        for seg in segments {
            guard let r = seg.range(
                of: #"(?i)^bar\s+(\S+)\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$"#,
                options: .regularExpression
            ) else { continue }
            let m = String(seg[r])
            // Drop the literal "bar " prefix (case-insensitive).
            let withoutBar = m.replacingOccurrences(
                of: #"(?i)^bar\s+"#,
                with: "",
                options: .regularExpression
            )
            let parts = withoutBar.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  let v = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            bars.append(.init(label: label, value: v))
        }
        guard bars.count >= 2 else { return nil }
        return .data(bars: bars)
    }

    // MARK: - Splitters

    private static func splitByPipe(_ s: String) -> [String] {
        s.split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func splitByArrow(_ s: String) -> [String] {
        // Matches both ASCII-style "->", U+2192 "→", and full-width "＞" rare.
        let normalized = s
            .replacingOccurrences(of: "->", with: "→")
            .replacingOccurrences(of: "—>", with: "→")
        return normalized.split(separator: "→", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{201C}", with: "\"")
         .replacingOccurrences(of: "\u{201D}", with: "\"")
         .replacingOccurrences(of: "\u{300C}", with: "\"")
         .replacingOccurrences(of: "\u{300D}", with: "\"")
    }

    // MARK: - Edited-prompt classifier

    /// Classifies a hand-edited prompt as either a *title-only* tweak
    /// (the user adjusted the popover seed, which is itself the
    /// `userTitle`) or a *structural override* (they pasted a full
    /// payload that should replace the parsed `agent_hint`).
    ///
    /// Heuristic: structural payloads carry a delimiter that the
    /// mini-formats use (`|`, `→`, `::`, year-colon, or a quoted
    /// sentence). A short single-line edit without any of those is
    /// almost always a title rewrite — we must NOT then drop the
    /// parsed items, or a 3-bullet enumeration silently collapses
    /// into a single-bullet card.
    static func editLooksStructural(_ edit: String) -> Bool {
        let s = edit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        if s.contains("|") { return true }
        if s.contains("→") || s.contains("->") { return true }
        if s.contains("::") { return true }
        if s.range(of: #"\d{4}\s*[:：]"#, options: .regularExpression) != nil { return true }
        // Quote pattern: opening quote + ≥ one closing quote.
        let normalized = s
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        if normalized.filter({ $0 == "\"" }).count >= 2 { return true }
        // Multi-line lists also count as structural.
        if s.contains("\n") { return true }
        return false
    }
}
