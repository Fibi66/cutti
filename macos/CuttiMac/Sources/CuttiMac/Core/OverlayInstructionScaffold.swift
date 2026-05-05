import Foundation

/// Builds the "## Distilled signals" Markdown block that goes at the
/// TOP of the Stage-2 overlay-agent instruction. This is the agent's
/// authoritative source for screen text — heading, item labels, quote
/// body, comparison sides, etc. The transcript that follows is for
/// `atSeconds` timing only.
///
/// The block format mirrors the mini-formats defined in
/// `BRollSuggestionService.swift` so the agent sees the same shape it
/// was trained on. Skips fields that are nil/empty so legacy
/// suggestions (no `userTitle` or no `agent_hint`) degrade gracefully
/// to whatever signal IS present.
enum OverlayInstructionScaffold {

    /// Returns the structured-signals Markdown block, or nil when no
    /// usable signals are available at all.
    static func structuredSignalsBlock(
        userTitle: String?,
        parsed: ParsedAgentHint,
        sectionRole: String?,
        isEnglish: Bool
    ) -> String? {
        var lines: [String] = []

        if let title = userTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            lines.append(isEnglish
                ? "- **Card title** (already distilled by Stage-1, ≤20 chars; use as `heading` / overlay title verbatim — DO NOT paraphrase): \"\(title)\""
                : "- **卡片标题**（已被 Stage-1 蒸馏，≤20 字；直接作为 `heading` / overlay 标题，不要改写）：\"\(title)\""
            )
        }

        switch parsed {
        case .enumeration(let items):
            lines.append(formattedItemList(
                heading: isEnglish
                    ? "**List items** (\(items.count) items parsed from `agent_hint`; use these LITERALLY as the SequenceSteps `items[].label`)"
                    : "**列表项**（共 \(items.count) 项，已从 `agent_hint` 解析；**直接**作为 SequenceSteps 的 `items[].label`）",
                items: items
            ))
        case .process(let steps):
            lines.append(formattedItemList(
                heading: isEnglish
                    ? "**Process steps** (\(steps.count) steps in order; use these LITERALLY as the SequenceSteps `items[].label`, layout=\"flow\")"
                    : "**流程步骤**（共 \(steps.count) 步，按顺序；**直接**作为 SequenceSteps 的 `items[].label`，layout=\"flow\"）",
                items: steps
            ))
        case .chronology(let entries):
            let rendered = entries.enumerated().map { idx, e in
                "  \(idx + 1). \(e.year)\(isEnglish ? ": " : "：")\(e.label)"
            }.joined(separator: "\n")
            lines.append(isEnglish
                ? "- **Chronology entries** (\(entries.count) year-anchored items; use as SequenceSteps layout=\"timeline\" with the year as a prefix on each label):\n\(rendered)"
                : "- **年表条目**（共 \(entries.count) 项；使用 SequenceSteps layout=\"timeline\"，每条 label 以年份为前缀）：\n\(rendered)"
            )
        case .quote(let text, let attribution):
            let attribStr: String = {
                guard let a = attribution else { return "" }
                return isEnglish ? " — \(a)" : " — \(a)"
            }()
            lines.append(isEnglish
                ? "- **Quote** (use Quote template; `text` = exact words below, NO paraphrase): \"\(text)\"\(attribStr)"
                : "- **金句**（使用 Quote 模板；`text` 字段直接用下面这句，**不要**改写）：\"\(text)\"\(attribStr)"
            )
        case .comparison(let l, let r):
            lines.append(isEnglish
                ? "- **Comparison** (use Comparison template; map directly to `leftLabel` / `rightLabel`):\n  - LEFT  → \"\(l)\"\n  - RIGHT → \"\(r)\""
                : "- **对比**（使用 Comparison 模板，直接映射到 `leftLabel` / `rightLabel`）：\n  - 左 → \"\(l)\"\n  - 右 → \"\(r)\""
            )
        case .data(let bars):
            let rendered = bars.map { "  - \($0.label) = \($0.value)" }.joined(separator: "\n")
            lines.append(isEnglish
                ? "- **Data points** (\(bars.count) bars; consider TitleCard with the headline stat as `subtitle`, or SkillMeter if there's a sweet-spot story):\n\(rendered)"
                : "- **数据点**（共 \(bars.count) 项；优先 TitleCard 把核心数字放 `subtitle`，若是「过多反而不好」叙事用 SkillMeter）：\n\(rendered)"
            )
        case .freeform(let text):
            lines.append(isEnglish
                ? "- **Hint payload** (Stage-1 produced this freeform — could not auto-parse a structure; use as inspiration but DISTILL into clean labels, do not lift verbatim if the wording is awkward): \"\(text)\""
                : "- **结构化信号**（Stage-1 给的自由文本，未能解析；可作为内容启发，但仍需蒸馏成干净的 label，文字若拗口不要原样使用）：\"\(text)\""
            )
        case .empty:
            break
        }

        if let role = sectionRole?.trimmingCharacters(in: .whitespacesAndNewlines),
           !role.isEmpty, role != "other" {
            lines.append(isEnglish
                ? "- **Section role** → \(routingHintForRole(role, isEnglish: true))"
                : "- **段落类型** → \(routingHintForRole(role, isEnglish: false))"
            )
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Maps a canonical Stage-1 section role to a suggested
    /// template_id (and layout, when relevant). Used inline inside
    /// the structured-signals block so the agent's first read of
    /// `sectionRole` already carries the routing nudge.
    static func routingHintForRole(_ role: String, isEnglish: Bool) -> String {
        switch role.lowercased() {
        case "enumeration":
            return "SequenceSteps layout=\"list\""
        case "process", "flow":
            return "SequenceSteps layout=\"flow\""
        case "chronology":
            return "SequenceSteps layout=\"timeline\""
        case "quote":
            return "Quote"
        case "comparison":
            return "Comparison"
        case "thesis":
            return isEnglish ? "TitleCard or Quote (single memorable line)" : "TitleCard 或 Quote（一句金句）"
        case "intro":
            return isEnglish ? "TitleCard (~2-3s, tight; do NOT span the full anchor window)" : "TitleCard（约 2-3s，紧凑；**不要**撑满整个 anchor 窗口）"
        case "transition", "chapter_break":
            return isEnglish ? "ChapterTitle (~2-3s, tight)" : "ChapterTitle（约 2-3s，紧凑）"
        case "conclusion":
            return isEnglish ? "TitleCard (closing) or ChapterTitle" : "TitleCard（结尾）或 ChapterTitle"
        case "data", "chart":
            return isEnglish
                ? "TitleCard with the headline figure in `subtitle`, or SkillMeter for a sweet-spot story"
                : "TitleCard 把核心数字放 `subtitle`，或 SkillMeter（「过多反而不好」叙事）"
        case "example", "anecdote":
            return isEnglish ? "PromptTyping or ChatBubble (showing the moment as dialog)" : "PromptTyping 或 ChatBubble（把例子做成对话/输入）"
        case "emotional":
            return isEnglish ? "Quote or TitleCard (emphasize one phrase)" : "Quote 或 TitleCard（突出一句话）"
        case "setup":
            return isEnglish ? "ChapterTitle (frames the upcoming section)" : "ChapterTitle（为后面的内容铺垫）"
        default:
            return isEnglish ? "agent's choice (no deterministic mapping)" : "由 agent 选择（无确定映射）"
        }
    }

    /// Universal "do not extract from transcript" guard rail. Tucked
    /// into a static helper so all 4 instruction branches phrase it
    /// identically — the wording matters; rewording per branch is how
    /// behavior drifts.
    static func transcriptGuardRail(isEnglish: Bool) -> String {
        if isEnglish {
            return """
            ## Transcript usage rules (read carefully)
            - The transcript below is **TIMING REFERENCE ONLY**. Use the \
            relative timestamps to set `atSeconds` on SequenceSteps items \
            so each item lands when the speaker says it.
            - DO NOT lift filler / partial ASR fragments / opening phatic \
            phrases ("so here is…", "you know", "I mean", "kind of") \
            from the transcript into headings or item labels. \
            Verbatim fragments make the overlay look like raw captions.
            - The DISTILLED SIGNALS block above is the source of truth \
            for `heading`, `items[].label`, quote `text`, comparison \
            `leftLabel`/`rightLabel`. Use them as written.
            """
        } else {
            return """
            ## 字幕使用规则（请仔细看）
            - 下面的字幕**仅作为时间参考**。请用相对时间戳给 SequenceSteps 的每个 item 设 `atSeconds`，让 item 在讲者说到该点时落下。
            - **不要**把字幕里的口头禅 / ASR 残片 / 起头语气词（"那 / 就是 / 你知道 / 我的意思是 / 然后呢"）抽到 heading 或 item 的 label。原文片段会让 overlay 看起来像原始字幕。
            - 上面的**蒸馏信号**块是 `heading`、`items[].label`、quote 的 `text`、comparison 的 `leftLabel`/`rightLabel` 的权威来源，**直接照抄**这些字段。
            """
        }
    }

    // MARK: - Internal

    private static func formattedItemList(heading: String, items: [String]) -> String {
        let body = items.enumerated().map { idx, item in
            "  \(idx + 1). \(item)"
        }.joined(separator: "\n")
        return "- \(heading):\n\(body)"
    }
}
