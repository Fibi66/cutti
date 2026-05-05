import Foundation
import CuttiKit

/// Calls the OpenAI API to make transcript-based editing decisions.
///
/// This is a direct port of the Python backend's `llm_editor.py`.
/// The LLM receives a numbered transcript and returns structured
/// keep/cut decisions via function calling.
struct LLMEditorService: Sendable {

    let client: OpenAIClient

    init(client: OpenAIClient) {
        self.client = client
    }

    // MARK: - Result

    struct EditDecision: Sendable {
        struct Cut: Sendable {
            let index: Int
            let reason: String
        }
        /// A set of transcript segments the LLM considers equivalent
        /// takes of the same idea (restart-duplicates or rewordings).
        /// The `chosenIndex` is the best version — the one that ends
        /// up on the timeline. `alternativeIndices` are the other takes
        /// that stay available as swap candidates but are not played
        /// back-to-back on the timeline.
        struct DuplicateGroup: Sendable, Equatable {
            let chosenIndex: Int
            let alternativeIndices: [Int]
            let reason: String
        }
        let keepIndices: [Int]
        let cuts: [Cut]
        let duplicateGroups: [DuplicateGroup]

        init(
            keepIndices: [Int],
            cuts: [Cut],
            duplicateGroups: [DuplicateGroup] = []
        ) {
            self.keepIndices = keepIndices
            self.cuts = cuts
            self.duplicateGroups = duplicateGroups
        }
    }

    // MARK: - Public

    /// Ask the LLM which transcript segments to keep and which to cut.
    /// Runs three passes: initial selection, restart-duplicate review,
    /// then completeness review.
    ///
    /// - Parameters:
    ///   - segments: All transcript segments (may span multiple source videos).
    ///   - sourceNames: Optional mapping of sourceVideoID → display name for multi-video.
    func selectSegments(
        _ segments: [TranscriptSegment],
        sourceNames: [UUID: String] = [:]
    ) async throws -> EditDecision {
        guard !segments.isEmpty else {
            return EditDecision(keepIndices: [], cuts: [], duplicateGroups: [])
        }

        let isMultiSource = Set(segments.compactMap(\.sourceVideoID)).count > 1

        // Pass 1: Initial selection
        let prompt = isMultiSource ? Self.multiVideoEditorSystemPrompt : Self.editorSystemPrompt
        let firstPass = try await runSelection(segments: segments, prompt: prompt, sourceNames: sourceNames)

        // Pass 2: Restart-duplicate review — catch the "said half,
        // then restarted from the same opening and finished it"
        // pattern that initial selection commonly misses. Instead of
        // cutting the weaker take, group the takes and pick the best
        // one to play on the timeline — the user can still swap.
        let restartReviewed = await reviewKeptSegments(
            baseDecision: firstPass,
            segments: segments,
            sourceNames: sourceNames,
            prompt: Self.restartDuplicateReviewPrompt,
            userInstruction: "以下是第一轮保留的 \(firstPass.keepIndices.count) 个片段。请检查是否有“前面先说半句，后面又从差不多的开头重说并补完整”的重启式重复（通常紧邻或在列表中距离 ≤ 2 格）。把每一组重启式重复归到 duplicate_groups 里：`chosen_index` 是最完整/最流畅的那条（会出现在时间线上），其余的放进 `alternative_indices`（作为备选保留，不剪掉）。说话人中间思考停顿很久没关系，时间距离不限。",
            synthesizedReason: "与另一处保留片段属于重启式重复，复核时保留更完整版本。",
            logLabel: "Restart duplicate review"
        )

        // Pass 3: Same-meaning rewording review — detect takes that
        // express the same idea with different wording (not a restart
        // of the same opening). Groups only; never cut in this pass.
        let rewordingReviewed = await reviewKeptSegments(
            baseDecision: restartReviewed,
            segments: segments,
            sourceNames: sourceNames,
            prompt: Self.rewordingEquivalenceReviewPrompt,
            userInstruction: "以下是经过重启式去重后保留的 \(restartReviewed.keepIndices.count) 个片段。请再扫一遍：是否还有“措辞不同但意思基本相同”的多次讲述（例如把同一个观点用两种说法各讲了一遍）。把这些归到 duplicate_groups，`chosen_index` 选最顺畅/最清晰/信息最完整的一条，其余进 `alternative_indices`。这一遍**不要**输出任何 cuts；也不要把仅仅话题相关但内容不同的片段当成等价。",
            synthesizedReason: "",
            logLabel: "Rewording equivalence review"
        )

        // Pass 4: Completeness review — drop half-sentence residue
        // and obvious bad-transcription remnants. Only evaluate the
        // "chosen" take of each equivalent-take group; alternates
        // should not be scrutinised as residue because they're
        // intentionally redundant.
        let alternateIndices = Set(rewordingReviewed.duplicateGroups.flatMap(\.alternativeIndices))
        let completenessScope = EditDecision(
            keepIndices: rewordingReviewed.keepIndices.filter { !alternateIndices.contains($0) },
            cuts: rewordingReviewed.cuts,
            duplicateGroups: rewordingReviewed.duplicateGroups
        )
        let completenessPartial = await reviewKeptSegments(
            baseDecision: completenessScope,
            segments: segments,
            sourceNames: sourceNames,
            prompt: Self.completenessReviewPrompt,
            userInstruction: "以下是去重后保留的 \(completenessScope.keepIndices.count) 个片段。请只检查这些片段连起来读时，是否还有被剪残的半句话、孤立残句、只剩前缀但没有独立意义的片段，或明显坏转写残留。不要重新做主题筛选，也不要为了压缩时长继续删有意义的内容。",
            synthesizedReason: "作为单独保留片段时语义不完整或已经被剪残，完整性复核时移除。",
            logLabel: "Completeness review"
        )

        // Merge alternates back: completeness pass only saw chosens,
        // so add each still-valid alternate back into keep. Drop any
        // group whose chosen got cut (promote the first surviving
        // alternate to chosen if possible, otherwise dissolve the
        // group entirely).
        let survivingChosens = Set(completenessPartial.keepIndices)
        var finalGroups: [EditDecision.DuplicateGroup] = []
        var finalKeepSet = survivingChosens
        for group in rewordingReviewed.duplicateGroups {
            if survivingChosens.contains(group.chosenIndex) {
                finalGroups.append(group)
                for a in group.alternativeIndices { finalKeepSet.insert(a) }
            } else if let promoted = group.alternativeIndices.first {
                let remaining = Array(group.alternativeIndices.dropFirst())
                if !remaining.isEmpty {
                    finalGroups.append(.init(
                        chosenIndex: promoted,
                        alternativeIndices: remaining,
                        reason: group.reason
                    ))
                }
                finalKeepSet.insert(promoted)
                for a in remaining { finalKeepSet.insert(a) }
            }
        }

        let completenessReviewed = EditDecision(
            keepIndices: Array(finalKeepSet).sorted(),
            cuts: completenessPartial.cuts,
            duplicateGroups: finalGroups
        )

        return completenessReviewed
    }

    private func runSelection(
        segments: [TranscriptSegment],
        prompt: String,
        sourceNames: [UUID: String] = [:]
    ) async throws -> EditDecision {
        let transcriptText = formatTranscript(segments, sourceNames: sourceNames)

        let sourceCount = Set(segments.compactMap(\.sourceVideoID)).count
        let userMessage: String
        if sourceCount > 1 {
            userMessage = "以下是 \(sourceCount) 段视频的合并逐字稿，共 \(segments.count) 个片段。每个片段标注了来源视频和在该视频中的时间戳：\n\n\(transcriptText)"
        } else {
            userMessage = "以下是完整逐字稿，共 \(segments.count) 个片段：\n\n\(transcriptText)"
        }

        let messages: [ChatMessage] = [
            .system(prompt),
            .user(userMessage),
        ]

        let response = try await client.chatCompletion(
            messages: messages,
            tools: [Self.selectSegmentsTool],
            toolChoice: .required(name: "select_segments"),
            temperature: 0.1,
            task: .firstCut
        )

        guard let toolCall = response.toolCalls.first,
              let data = toolCall.function.arguments.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return EditDecision(
                keepIndices: Array(0..<segments.count),
                cuts: [],
                duplicateGroups: []
            )
        }

        let validRange = Set(0..<segments.count)

        let keep = (args["keep"] as? [Int] ?? []).filter { validRange.contains($0) }
        let rawCuts = args["cuts"] as? [[String: Any]] ?? []
        let cuts = rawCuts.compactMap { raw -> EditDecision.Cut? in
            guard let index = raw["index"] as? Int,
                  validRange.contains(index),
                  let reason = raw["reason"] as? String else { return nil }
            return EditDecision.Cut(index: index, reason: reason)
        }

        let rawGroups = args["duplicate_groups"] as? [[String: Any]] ?? []
        let groups = Self.parseDuplicateGroups(rawGroups, validRange: validRange)

        // If the LLM contradicts itself by listing the same index in both
        // keep and cuts, cuts win — we err on the side of removing
        // flagged content rather than silently keeping a duplicate.
        let cutIndices = Set(cuts.map(\.index))
        let reconciledKeep = keep.filter { !cutIndices.contains($0) }

        return EditDecision(keepIndices: reconciledKeep, cuts: cuts, duplicateGroups: groups)
    }

    // MARK: - Transcript formatting

    private func formatTranscript(_ segments: [TranscriptSegment], sourceNames: [UUID: String] = [:]) -> String {
        segments.enumerated().map { i, s in
            let duration = s.endSeconds - s.startSeconds
            let srcLabel = s.sourceVideoID.flatMap { sourceNames[$0] } ?? ""
            let prefix = srcLabel.isEmpty ? "" : "[\(srcLabel)] "
            return "[\(i)] \(prefix)\(String(format: "%.1f", s.startSeconds))s–\(String(format: "%.1f", s.endSeconds))s (\(String(format: "%.1f", duration))s): \(s.text)"
        }.joined(separator: "\n")
    }

    private func reviewKeptSegments(
        baseDecision: EditDecision,
        segments: [TranscriptSegment],
        sourceNames: [UUID: String],
        prompt: String,
        userInstruction: String,
        synthesizedReason: String,
        logLabel: String
    ) async -> EditDecision {
        guard baseDecision.keepIndices.count > 1 else { return baseDecision }

        let keptText = formatSegments(
            baseDecision.keepIndices.sorted(),
            in: segments,
            sourceNames: sourceNames
        )

        let reviewMessages: [ChatMessage] = [
            .system(prompt),
            .user("\(userInstruction)\n\n完整片段列表：\n\n\(keptText)")
        ]

        do {
            let reviewResponse = try await client.chatCompletion(
                messages: reviewMessages,
                tools: [Self.selectSegmentsTool],
                toolChoice: .required(name: "select_segments"),
                temperature: 0.1,
                task: .firstCut
            )

            guard let toolCall = reviewResponse.toolCalls.first,
                  let data = toolCall.function.arguments.data(using: .utf8),
                  let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return baseDecision
            }

            let validIndices = Set(baseDecision.keepIndices)
            let reviewKeep = (args["keep"] as? [Int] ?? []).filter { validIndices.contains($0) }
            let reviewRawCuts = args["cuts"] as? [[String: Any]] ?? []
            let reviewCuts = reviewRawCuts.compactMap { raw -> EditDecision.Cut? in
                guard let index = raw["index"] as? Int,
                      validIndices.contains(index),
                      let reason = raw["reason"] as? String else { return nil }
                return EditDecision.Cut(index: index, reason: reason)
            }

            let rawGroups = args["duplicate_groups"] as? [[String: Any]] ?? []
            let reviewGroups = Self.parseDuplicateGroups(rawGroups, validRange: validIndices)

            let reviewed = Self.mergeReviewDecision(
                baseDecision: baseDecision,
                reviewKeep: reviewKeep,
                reviewCuts: reviewCuts,
                reviewGroups: reviewGroups,
                synthesizedReason: synthesizedReason
            )

            let removedCount = baseDecision.keepIndices.count - reviewed.keepIndices.count
            let addedGroups = reviewed.duplicateGroups.count - baseDecision.duplicateGroups.count
            if addedGroups > 0 {
                print("🔄 \(logLabel): removed \(removedCount) segment(s), added \(addedGroups) equivalent-take group(s)")
            } else {
                print("🔄 \(logLabel): removed \(removedCount) segment(s)")
            }
            return reviewed
        } catch {
            print("⚠️ \(logLabel) failed: \(error)")
            return baseDecision
        }
    }

    private func formatSegments(
        _ indices: [Int],
        in segments: [TranscriptSegment],
        sourceNames: [UUID: String]
    ) -> String {
        indices.compactMap { idx -> String? in
            guard idx < segments.count else { return nil }
            let s = segments[idx]
            let srcLabel = s.sourceVideoID.flatMap { sourceNames[$0] } ?? ""
            let prefix = srcLabel.isEmpty ? "" : "[\(srcLabel)] "
            return "[\(idx)] \(prefix)\(String(format: "%.1f", s.startSeconds))s–\(String(format: "%.1f", s.endSeconds))s: \(s.text)"
        }
        .joined(separator: "\n")
    }

    static func mergeReviewDecision(
        baseDecision: EditDecision,
        reviewKeep: [Int],
        reviewCuts: [EditDecision.Cut],
        reviewGroups: [EditDecision.DuplicateGroup] = [],
        synthesizedReason: String
    ) -> EditDecision {
        let validIndices = Set(baseDecision.keepIndices)
        let reviewCutSet = Set(reviewCuts.map(\.index)).intersection(validIndices)
        let normalizedKeep = Array(
            Set(reviewKeep.filter { validIndices.contains($0) })
                .subtracting(reviewCutSet)
        ).sorted()

        // Only fall back to base keep when the review returned nothing
        // actionable at all (empty keep AND empty cuts AND empty groups).
        // If the review produced cuts but no keep list, honour the cuts.
        let finalKeep: [Int]
        if normalizedKeep.isEmpty && reviewCutSet.isEmpty && reviewGroups.isEmpty {
            finalKeep = baseDecision.keepIndices.sorted()
        } else if normalizedKeep.isEmpty {
            finalKeep = validIndices.subtracting(reviewCutSet).sorted()
        } else {
            finalKeep = normalizedKeep
        }

        // Merge duplicate groups: keep the base groups, then add any new
        // groups whose chosen/alternative indices are still in keep and
        // that don't conflict with an existing group's membership.
        let finalKeepSet = Set(finalKeep)
        let alreadyGroupedMembers: Set<Int> = Set(
            baseDecision.duplicateGroups.flatMap { [$0.chosenIndex] + $0.alternativeIndices }
        )
        var groupedMembers = alreadyGroupedMembers
        var mergedGroups = baseDecision.duplicateGroups
        for group in reviewGroups {
            let members = [group.chosenIndex] + group.alternativeIndices
            guard members.allSatisfy({ finalKeepSet.contains($0) }) else { continue }
            guard members.allSatisfy({ !groupedMembers.contains($0) }) else { continue }
            mergedGroups.append(group)
            for m in members { groupedMembers.insert(m) }
        }

        let removedByReview = validIndices.subtracting(finalKeep)
        let existingCutIndices = Set(baseDecision.cuts.map(\.index)).union(reviewCuts.map(\.index))
        let synthesizedCuts = removedByReview
            .sorted()
            .filter { !existingCutIndices.contains($0) }
            .map { index in
                EditDecision.Cut(index: index, reason: synthesizedReason)
            }

        return EditDecision(
            keepIndices: finalKeep,
            cuts: deduplicatedCuts(baseDecision.cuts + reviewCuts + synthesizedCuts),
            duplicateGroups: mergedGroups
        )
    }

    static func parseDuplicateGroups(
        _ raw: [[String: Any]],
        validRange: Set<Int>
    ) -> [EditDecision.DuplicateGroup] {
        var groups: [EditDecision.DuplicateGroup] = []
        var seen = Set<Int>()
        for entry in raw {
            guard let chosen = entry["chosen_index"] as? Int,
                  validRange.contains(chosen),
                  !seen.contains(chosen) else { continue }
            let altsRaw = entry["alternative_indices"] as? [Int] ?? []
            let alts = altsRaw.filter { validRange.contains($0) && $0 != chosen && !seen.contains($0) }
            guard !alts.isEmpty else { continue }
            let reason = (entry["reason"] as? String) ?? ""
            groups.append(.init(chosenIndex: chosen, alternativeIndices: alts, reason: reason))
            seen.insert(chosen)
            for a in alts { seen.insert(a) }
        }
        return groups
    }

    private static func deduplicatedCuts(_ cuts: [EditDecision.Cut]) -> [EditDecision.Cut] {
        var seen = Set<Int>()
        var deduplicated: [EditDecision.Cut] = []

        for cut in cuts {
            if seen.insert(cut.index).inserted {
                deduplicated.append(cut)
            }
        }

        return deduplicated
    }

    // MARK: - Prompt (ported from Python backend)

    // MARK: - Chapter generation

    /// Ask the LLM to split the *edited* (post-cut) timeline into a small
    /// number of titled chapters. Times in the returned chapters are in
    /// edited-timeline seconds, NOT source seconds.
    ///
    /// `cutTranscript` should already be in playback order; each entry's
    /// `startSeconds`/`endSeconds` should already be on the composed
    /// timeline.
    func generateChapters(
        cutTranscript: [TranscriptSegment],
        totalDuration: Double
    ) async throws -> [VideoChapter] {
        guard totalDuration > 1, !cutTranscript.isEmpty else { return [] }

        // Adaptive target chapter count: ~1 chapter per 1.5 minutes,
        // clamped to [3, 12]. This is a soft hint to the LLM.
        let durationMin = totalDuration / 60.0
        let target = max(3, min(12, Int((durationMin / 1.5).rounded())))

        let transcriptText = cutTranscript.enumerated().map { i, s in
            "[\(i)] \(String(format: "%.1f", s.startSeconds))s–\(String(format: "%.1f", s.endSeconds))s: \(s.text)"
        }.joined(separator: "\n")

        let userMessage = """
        以下是一段已经剪辑过的视频的逐字稿（共 \(cutTranscript.count) 个片段，总时长 \(String(format: "%.1f", totalDuration)) 秒）。请把它分成大约 \(target) 个章节（可以略多或略少，关键是按内容自然切分）。
        每个章节给一个**简短的标题**：中文 ≤ 8 个字，英文 ≤ 4 个词，**不要任何标点符号、不要序号**。
        章节必须按时间顺序、首尾相接、覆盖整段时间轴：
        - 第一个章节 start_seconds = 0
        - 最后一个章节 end_seconds = \(String(format: "%.2f", totalDuration))
        - 任意相邻章节之间没有间隔、不重叠
        - 每个章节时长建议 ≥ 5 秒
        标题语言**与逐字稿主体语言保持一致**。

        逐字稿：

        \(transcriptText)
        """

        let messages: [ChatMessage] = [
            .system(Self.chaptersSystemPrompt),
            .user(userMessage),
        ]

        let response = try await client.chatCompletion(
            messages: messages,
            tools: [Self.generateChaptersTool],
            toolChoice: .required(name: "generate_chapters"),
            temperature: 0.2,
            task: .firstCut
        )

        guard let toolCall = response.toolCalls.first,
              let data = toolCall.function.arguments.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = args["chapters"] as? [[String: Any]]
        else {
            return []
        }

        let parsed: [VideoChapter] = raw.compactMap { entry in
            guard let start = (entry["start_seconds"] as? Double)
                    ?? (entry["start_seconds"] as? Int).map(Double.init),
                  let end = (entry["end_seconds"] as? Double)
                    ?? (entry["end_seconds"] as? Int).map(Double.init),
                  let title = (entry["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { return nil }
            return VideoChapter(startSeconds: start, endSeconds: end, title: title)
        }

        return Self.normalizeChapters(parsed, totalDuration: totalDuration)
    }

    /// Clamp, sort, fix overlaps and gaps, drop too-short chapters, and
    /// stretch the last chapter to cover `totalDuration`.
    static func normalizeChapters(
        _ raw: [VideoChapter],
        totalDuration: Double,
        minChapterSeconds: Double = 1.0
    ) -> [VideoChapter] {
        guard totalDuration > 0 else { return [] }

        // Clamp + drop nonsense.
        var work = raw
            .map { c -> VideoChapter in
                var copy = c
                copy.startSeconds = max(0, min(totalDuration, c.startSeconds))
                copy.endSeconds = max(0, min(totalDuration, c.endSeconds))
                return copy
            }
            .filter { $0.endSeconds > $0.startSeconds }
            .sorted { $0.startSeconds < $1.startSeconds }

        guard !work.isEmpty else {
            return [VideoChapter(startSeconds: 0, endSeconds: totalDuration, title: "Chapter")]
        }

        // Snap first start to 0; fix overlaps/gaps by aligning each
        // chapter's start to the previous chapter's end.
        work[0].startSeconds = 0
        for i in 1..<work.count {
            work[i].startSeconds = work[i - 1].endSeconds
            if work[i].endSeconds <= work[i].startSeconds {
                work[i].endSeconds = min(totalDuration, work[i].startSeconds + minChapterSeconds)
            }
        }
        // Snap last end to total.
        work[work.count - 1].endSeconds = totalDuration

        // Drop chapters that are still too short by merging into next.
        var compacted: [VideoChapter] = []
        for c in work {
            if c.durationSeconds < minChapterSeconds, !compacted.isEmpty {
                compacted[compacted.count - 1].endSeconds = c.endSeconds
            } else {
                compacted.append(c)
            }
        }
        if let last = compacted.last, last.durationSeconds < minChapterSeconds, compacted.count > 1 {
            compacted[compacted.count - 2].endSeconds = last.endSeconds
            compacted.removeLast()
        }
        // Final guarantee: cover the whole timeline.
        if !compacted.isEmpty {
            compacted[0].startSeconds = 0
            compacted[compacted.count - 1].endSeconds = totalDuration
        }
        return compacted
    }

    private static let chaptersSystemPrompt = """
    你是一个视频章节生成助手。你的工作是把一段**已经剪辑好**的口播视频按内容主题分成若干章节，并给每个章节起一个简短、贴切、可以放在屏幕底部进度条上的标题。

    你的工作不是改写、不是重新筛选，而是**根据已有内容做主题切分**。

    ## 章节标题规则
    - 中文标题 ≤ 8 个字；英文标题 ≤ 4 个词
    - **不要**任何标点符号（不要"："、"。"、"！"、"-"、引号、emoji、序号 1./2./等等）
    - 直接使用名词或短动词短语，描述这一段在讲什么
    - 标题语言与逐字稿主体语言保持一致

    ## 时间轴规则（必须严格遵守）
    - 章节按时间顺序排列
    - 第一个章节 start_seconds = 0
    - 最后一个章节 end_seconds = 视频总时长
    - 相邻章节首尾相接：上一章 end == 下一章 start
    - 不允许重叠、不允许留空隙
    - 每个章节时长尽量 ≥ 5 秒

    ## 切分原则
    - 按**话题/小节**切，不按句子切
    - 数量与视频时长相称，宁可少而清晰，不要碎成一堆
    - 一个明显的开场白可以是单独一章；结尾的总结也可以是单独一章

    请调用 generate_chapters 工具返回结果。
    """

    private static let generateChaptersTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "generate_chapters",
            description: "Submit the chapter list for the edited video. Chapter times are in edited-timeline seconds (post-cut) and must cover [0, totalDuration] contiguously.",
            parameters: .init(
                type: "object",
                properties: [
                    "chapters": .init(
                        type: "array",
                        description: "Ordered chapter list covering the entire edited timeline.",
                        items: .init(
                            type: "object",
                            properties: [
                                "start_seconds": .init(type: "number", description: "Chapter start in edited-timeline seconds.", items: nil),
                                "end_seconds": .init(type: "number", description: "Chapter end in edited-timeline seconds.", items: nil),
                                "title": .init(type: "string", description: "Short chapter title with no punctuation.", items: nil),
                            ],
                            required: ["start_seconds", "end_seconds", "title"]
                        )
                    )
                ],
                required: ["chapters"],
                items: nil
            )
        )
    )

    private static let editorSystemPrompt = """
    你是一个**保守型**口播视频剪辑师 AI。你会收到一段口播视频的完整逐字稿（含时间戳），你的任务是决定保留哪些片段、剪掉哪些片段。

    你的职责是做**内容级**的保留/删除判断，不是改写台词。
    系统会在后处理阶段根据本地语音模型的词级时间自动收紧片段边界并去掉前后静默，所以你**不要**为了"更短、更干净"而擅自删除原话里的词或把句子剪残。

    ## 重要：理解片段的局限性

    逐字稿是按照说话的停顿自动分段的，**一个片段不一定是一个完整的句子**。说话人的一句完整的话可能跨越多个片段。所以你在判断时要：
    - 把相邻的片段连起来读，理解完整的句意
    - 不要因为一个片段看起来短、像前缀、像口头词就剪掉它——它可能是一句话的前半部分、后半部分、承接词或语气重点
    - 如果拿不准，**保留**

    ## 你的剪辑原则（按优先级排序）

    1. **宁可多保留，不要误剪**：只有在“明确重复 / 明显跑题 / 明显口误 / 明显转写坏掉”时才剪。
    2. **严格去重复，但只删真正被覆盖的重复**：
       - 仔细对比**所有片段**的语义内容，包括你打算保留的片段之间
       - 如果两个片段表达的是同一个完整意思，并且其中一个明显更完整，才删除较差版本
       - 如果前一个片段只是开头半句，后一个片段又用几乎相同的开头重说一遍并继续完成，前一个属于**重启/重说**，应该剪掉前一个
       - 即使两个片段因为 ASR 错字、口语省略、同义换说而文字不完全一样，只要核心意思相同，也算重复
       - 如果后一个片段是在前一个片段基础上的**补充、展开、承接、结论、强调**，那就**不是重复**
       - **特别注意**：不要因为两个片段话题相关，就把其中一个删掉
    3. **不要擅自删除说话人原话中的词**：
       - 像“我觉得”“其实”“然后”“那”“这个”这类词，如果它们参与了句子的语义、语气、节奏或承接，就必须保留
       - 只有当一个片段**单独成段**，并且整段都只是孤立语气词/口头停顿、对前后语义完全没有贡献时，才可以剪
    4. **去废话/跑题**：跟正文内容明显无关的话可以剪
    5. **去明显坏转写**：如果片段里主要是空白、控制 token、乱码式重复、明显不成句的转写垃圾，可以剪
    6. **保留完整表达**：如果一个片段包含新的信息点、承接关系或让句子更完整的词，即使它很短也要保留

    ## 工作步骤

    1. 先通读所有片段，把相邻片段连起来理解完整句意
    2. 标记出所有**明确表达相同意思**的片段组（不管它们离多远）
    3. 对每组真正重复的内容，只保留最完整最流畅的一个版本，其余才剪掉
    4. **自检**：把你打算保留的片段连起来读，确保没有把一句话剪残，也没有删掉有意义的连接词
    5. 最终保留的片段连起来读应该是一个流畅、完整、尽量保留原话表达的叙述

    ## 输出要求

    - 调用 select_segments 工具
    - keep：你要保留的片段索引列表（按顺序）
    - cuts：你要剪掉的片段列表，每个包含索引和原因
    - 如果拿不准，就放进 keep
    - **不要**因为“听起来像口头禅”“有点短”“好像不够高级”就删词或删片段
    - **只剪掉真正重复的、废话的、口误的、或明显坏转写的片段**
    """

    private static let multiVideoEditorSystemPrompt = """
    你是一个**保守型**口播视频剪辑师 AI。你会收到**多段视频**的合并逐字稿（每个片段标注了来源视频名称和在该视频中的时间戳），你的任务是将这些视频剪辑合并成一个流畅、无重复、但尽量保留原话表达的最终视频。

    ## 重要：理解多视频的特殊性

    - 每个片段带有 `[视频名]` 标签，表示它来自哪个视频文件
    - 同一个视频内的时间戳是该视频自身的时间，不同视频的时间戳互相独立
    - 说话人可能在不同视频中讲了相同的内容（多次录制同一段话），你需要**跨视频去重**
    - 最终保留的片段按你给出的顺序排列
    - 系统会在后处理阶段根据词级时间自动收紧片段边界并去掉前后静默，所以你不要为了缩短时长而擅自删词

    ## 你的剪辑原则（按优先级排序）

    1. **宁可多保留，不要误剪**
    2. **跨视频去重**：不同视频中说的同一件事，只保留最完整、最流畅的版本
    3. **视频内去重**：同一视频内的重复也要去掉，但只删真正被覆盖的重复
       - 如果同一视频里前一个片段只是某句话的开头半句，而后一个片段又用几乎相同的开头重说并补完整，前一个属于重启/重说，应该剪掉
       - 即使因为 ASR 错字或换说导致字面不完全相同，只要核心意思相同，也算重复
    4. **不要擅自删除词或承接句**：短句、承接词、语气词、补充句只要对原意有贡献，就必须保留
    5. **去废话/跑题**：跟正文内容明显无关的话
    6. **去明显坏转写**：空白、控制 token、乱码式重复
    7. **保持逻辑顺序**：keep 列表中的片段顺序应该是最终视频的播放顺序，确保内容连贯

    ## 输出要求

    - 调用 select_segments 工具
    - keep：你要保留的片段索引列表（按最终播放顺序排列）
    - cuts：你要剪掉的片段列表，每个包含索引和原因
    - 如果拿不准，就放进 keep
    """

    private static let duplicateReviewPrompt = """
    你是一个视频剪辑 QA 审核员。你收到的片段已经经过第一轮筛选。

    你的**唯一任务**是检查这些片段之间是否还有**语义重复**，尤其是“重启式重复”和“轻微 ASR 错字下的同义重说”。

    ## 规则
    - 只有当两个片段表达的是**同一个完整意思**，并且一个明显被另一个覆盖时，才剪掉较差版本
    - 即使两个片段文字不完全一样，只要核心意思相同、只是 ASR 错字/口语换说/轻微改写，也算重复
    - 如果前一个片段只是开头半句，后一个片段用几乎相同的开头重说并补完整，前一个属于**重启式重复**，应该剪掉
    - 如果一个片段是另一个片段的补充、铺垫、结论、强调、承接或例子，**不要**剪
    - **不要**剪掉短但有意义的词、连接词、过渡语、口语节奏词
    - **不要**因为两个片段话题相关就剪掉——只有说的是**同一句话/同一个完整意思**才算重复
    - 如果拿不准，就把所有片段都放进 keep

    请调用 select_segments。
    """

    private static let restartDuplicateReviewPrompt = """
    你是一个视频剪辑 QA 审核员。你现在只负责检查**真正的重启式重复（restart-duplicate）**。

    ## 什么算重启式重复
    说话人开口说了半句或一整句，紧接着（中间可能停顿思考几秒）用几乎相同的开头把这句话从头重说一遍。两段 **开头几个字几乎一样**，核心讲的是 **同一件事**，后一段通常把它说得更完整/更顺。

    ## 你的唯一任务
    找出 "**相邻** + **开头重合** + **同一件事**" 的 restart 组，把它们归到一个 duplicate_group 里：
    - `chosen_index`：选**最完整、最流畅、信息最全**的那一条（会真正出现在时间线上）
    - `alternative_indices`：组内其他 take（作为备选保留，不剪掉）
    - 所有属于组的 index 也都要出现在 `keep` 里
    - 本轮**不要**产出 cuts，你的工作只有分组

    ## 判定要点（三条都大致符合即可归组，不必字字严格对齐）
    1. **相邻**：在给你的这份保留列表里，两段距离通常 ≤ 2 格（一般就是紧邻）。中间隔了好几个不同主题的片段的不算。说话人中间思考停顿很久没关系，时间距离不限。
    2. **开头重合**：两段开头的几个字（或 ASR 错字/口语省略下的等价起句）可以对上。开头明显不一样的不算 restart。
    3. **同一件事**：两段核心命题/述说的对象相同，后者明显是前者的 "重说 + 补完"。如果是承接（铺垫→展开、前提→结论、设问→回答）、或两段都有独立信息量，不算 restart。

    ## 必须归组的例子
    - A: 不会吧还有人觉得在北美 SD 面试里
      B: 不会吧还有人在不会吧还有人觉得在北美面试里最后 10 分钟的提问环节是走过场
      => 相邻 + 开头几乎逐字相同 + 同一件事 → group {chosen: B, alternatives: [A]}
    - A: 面试的怎么构成我觉得
      B: 我觉得面试的成过程就是让面试官喜欢你
      => group {chosen: B, alternatives: [A]}
    - A: 问题问得好直接反映了你个人的
      B: 问题问得好直接反映了个人的思想敏锐度
      => group {chosen: B, alternatives: [A]}
    - A: 第一种我最常见的问题呢第一种我最常问的问题呢
      B: 第一种我最常问的问题呢就是 sex 类
      C: 第一种我最常问的问题呢是 sex 类型的
      => group {chosen: C, alternatives: [A, B]}（三段一起归组，C 最顺最完整）

    ## 必须保留、不归组的例子
    - A: 一个好的开头和一个好的结尾
      B: 能给人留下最直观的好印象
      => 开头完全不同，是承接（前提→结论），不归组
    - A: 色温很奇怪
      B: 反向向面试官提问也是面试过程中很重要的一个环节
      => 完全不同主题，不归组

    ## 选 chosen 的规则
    在一组内，选“句子最完整、信息最全、ASR 错字最少、最后一版的复述”。一般就是最后说的那条。

    ## 输出
    - 把所有本来的保留 index 仍然放在 `keep` 里（包括同一组的全部成员）
    - 把识别出来的每组 restart 放进 `duplicate_groups`
    - 本轮 `cuts` 应该为空

    请调用 select_segments。
    """

    private static let rewordingEquivalenceReviewPrompt = """
    你是一个视频剪辑 QA 审核员。你的任务是识别**同义改写的多次讲述**：说话人把**同一个观点**在不同位置用**不同措辞**讲了两遍或多遍（不是重启式重复，开头也不一定相同）。

    ## 强默认：拿不准就不归组

    这一轮的"漏报"远比"误报"代价低。
    - 漏报 = 观众看到两段表达略近但语气不同的内容 → 用户可以手动删一条。
    - 误报 = 把观众必须听到的内容（比如开场、提纲、铺垫）藏进 alternative，用户以为被删了，体验灾难。

    **只要有一丝不确定，就不要归组。**

    ## 等价判定：Paraphrase Test

    能归为一组的充要条件是——你能用**一句中文**把这组片段共同要传达的那条信息写出来，且这句话能同时概括组里每一段。如果你发现需要用"而且"、"此外"、"然后"才能覆盖所有成员，它们就不是等价的，是承接关系，**不归组**。

    形式上通常要求：
    - **同一主语**（谁在做 / 谁在被描述）
    - **同一谓语或同一宾语核心**（表述可以换说法，但指向的概念必须是同一个）
    - **同一结论 / 同一情感倾向**

    三项里"同一主语 + 同一结论"是最硬的两项。只占宾语核心或只共享关键字**不够**。

    ## 必须避免的典型误判

    1. **共享关键词陷阱**：两段都含"提问"/"两类"/"面试"等高频词，但讲的不是一件事。
       - 例：「最后 10 分钟的提问环节是走过场」 vs 「反向向面试官提问是重要的一环」—— 都含"提问"但主语与结论完全相反，**不归组**。
    2. **提纲 → 展开**：一段先抛出分类/清单，下一段展开第一类。
       - 例：「两类问题」 vs 「分为两类问题一种是...另一种是...」—— 前者是标题，后者是正文，**不归组**。
    3. **铺垫 → 结论 / 前提 → 应用 / 例子 1 → 例子 2** 一律不是等价。
    4. **开场 hook**：视频开头用来抓注意力的段（尤其是第 0、1、2 个保留片段），除非和另一段文字高度雷同否则不要纳入任何组。

    ## 你的唯一任务

    - 只对**你能通过 Paraphrase Test** 的片段归组。
    - `chosen_index`：选最顺畅、最清晰、信息最全的一条
    - `alternative_indices`：其余同义讲述
    - `reason`：**用一句话写出这组共享的那条信息**（这句话应该能替换组里任何一段仍不失信息）。写不出干净的一句话就不要归组。
    - 所有属于组的 index 也要出现在 `keep` 里
    - 本轮**严禁输出任何 cuts**
    - 没有高置信的等价重复，`duplicate_groups` 留空是完全正确的答案

    请调用 select_segments。
    """


    private static let completenessReviewPrompt = """
    你是一个视频剪辑完整性 QA 审核员。你收到的片段已经通过内容筛选和去重。

    你的**唯一任务**是检查这些保留片段连起来读时，是否还有：
    - 被剪残的半句话
    - 孤立残句
    - 只剩前缀但没有独立语义价值的片段
    - 明显坏转写残留

    ## 规则
    - 不要重新做主题筛选
    - 不要重新做去重
    - 不要为了更短而主动删内容
    - 只有当一个片段**单独保留时已经没有独立语义价值**，或者明显是坏转写残留时，才可以剪
    - 如果它仍然承担承接、语气、铺垫、结论、强调作用，就必须保留
    - 如果拿不准，就保留

    请调用 select_segments。
    """

    // MARK: - Tool definition

    private static let selectSegmentsTool = ToolDefinition(
        type: "function",
        function: .init(
            name: "select_segments",
            description: "Submit the editing decision: which segments to keep, which to cut, and which (if any) are equivalent takes of the same idea that should be grouped as swap alternates.",
            parameters: .init(
                type: "object",
                properties: [
                    "keep": .init(
                        type: "array",
                        description: "Indices of segments to KEEP in the final cut, in order. For equivalent-take groups, include ALL members (both the chosen one and the alternates) in keep — they will still be grouped via duplicate_groups.",
                        items: .init(type: "integer", properties: nil, required: nil)
                    ),
                    "cuts": .init(
                        type: "array",
                        description: "Segments to CUT, with reason for each.",
                        items: .init(
                            type: "object",
                            properties: [
                                "index": .init(type: "integer", description: "Segment index", items: nil),
                                "reason": .init(type: "string", description: "Why this segment should be cut", items: nil),
                            ],
                            required: ["index", "reason"]
                        )
                    ),
                    "duplicate_groups": .init(
                        type: "array",
                        description: "Optional: groups of segments that are equivalent takes of the same sentence / same meaning (restart-duplicates and same-meaning rewordings). For each group pick `chosen_index` (the version that will land on the timeline) and list the other equivalent takes in `alternative_indices`. ALL members of every group MUST also appear in `keep`.",
                        items: .init(
                            type: "object",
                            properties: [
                                "chosen_index": .init(type: "integer", description: "Index of the best / most complete take (goes on the timeline).", items: nil),
                                "alternative_indices": .init(
                                    type: "array",
                                    description: "Indices of the other equivalent takes (kept as swap alternates).",
                                    items: .init(type: "integer", properties: nil, required: nil)
                                ),
                                "reason": .init(type: "string", description: "Short label for why these are equivalent (e.g. '重启重复'、'同义改写').", items: nil),
                            ],
                            required: ["chosen_index", "alternative_indices", "reason"]
                        )
                    ),
                ],
                required: ["keep", "cuts"],
                items: nil
            )
        )
    )
}
