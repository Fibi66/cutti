import Foundation
import CuttiKit

fileprivate struct IndexedRangeInput {
    let range: TimeRange
    let sourceIndex: Int
}

/// Builds a complete `AICopilotSnapshot` by merging local analysis results
/// with LLM editing decisions.
struct CopilotSnapshotBuilder: Sendable {

    /// Build a snapshot from local analysis only (no LLM).
    /// Useful as an intermediate state while waiting for LLM results.
    static func fromLocalAnalysis(_ local: LocalAnalysisResult) -> AICopilotSnapshot {
        let transcriptPreview = local.transcript
            .prefix(5)
            .map(\.text)
            .joined(separator: " ")

        return AICopilotSnapshot(
            semanticTags: local.semanticTags,
            summary: buildSummary(local),
            transcriptPreview: transcriptPreview.isEmpty ? nil : String(transcriptPreview.prefix(300)),
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: local.audioIssues,
            suggestions: [],
            markers: buildSceneMarkers(local),
            transcript: local.transcript.isEmpty ? nil : local.transcript,
            wordTranscript: local.rawWordTranscript.isEmpty ? nil : local.rawWordTranscript,
            audioEnergyCurve: local.audioEnergyCurve
        )
    }

    /// Build a complete snapshot from local analysis + LLM editing decisions.
    static func fromAnalysisAndEdit(
        local: LocalAnalysisResult,
        editDecision: LLMEditorService.EditDecision
    ) -> AICopilotSnapshot {
        let transcriptPreview = local.transcript
            .prefix(5)
            .map(\.text)
            .joined(separator: " ")

        // Build suggestions from LLM cut reasons
        let suggestions = editDecision.cuts.prefix(5).map { cut -> AICopilotSuggestion in
            let segmentText: String
            if cut.index < local.transcript.count {
                let seg = local.transcript[cut.index]
                segmentText = String(format: " (%.1fs–%.1fs)", seg.startSeconds, seg.endSeconds)
            } else {
                segmentText = ""
            }
            return AICopilotSuggestion(
                title: "Cut segment \(cut.index)\(segmentText)",
                detail: cut.reason
            )
        }

        // Build markers from both scenes and cuts
        var markers = buildSceneMarkers(local)
        for cut in editDecision.cuts {
            guard cut.index < local.transcript.count else { continue }
            let seg = local.transcript[cut.index]
            markers.append(AICopilotMarker(
                kind: .suggestion,
                seconds: seg.startSeconds,
                label: cut.reason
            ))
        }

        // Compute suggested in/out only when kept segments are contiguous
        let suggestedIn: Double?
        let suggestedOut: Double?
        var keptRanges: [TimeRange] = []
        var keptTexts: [String] = []
        var keptAlternatives: [[AlternativeTake]] = []

        if !editDecision.keepIndices.isEmpty {
            // Map each transcript index that is part of a duplicate group
            // to the group's `chosen` index, and build the alternate list
            // attached to each chosen.
            var indexToChosen: [Int: Int] = [:]
            var alternatesByChosen: [Int: [AlternativeTake]] = [:]
            for group in editDecision.duplicateGroups {
                guard group.chosenIndex < local.transcript.count else { continue }
                indexToChosen[group.chosenIndex] = group.chosenIndex
                var alts: [AlternativeTake] = []
                for altIdx in group.alternativeIndices {
                    guard altIdx < local.transcript.count else { continue }
                    indexToChosen[altIdx] = group.chosenIndex
                    let altSeg = local.transcript[altIdx]
                    alts.append(AlternativeTake(
                        sourceVideoID: altSeg.sourceVideoID ?? UUID(),
                        startSeconds: altSeg.startSeconds,
                        endSeconds: altSeg.endSeconds,
                        text: altSeg.text,
                        reason: group.reason.isEmpty ? nil : group.reason
                    ))
                }
                alternatesByChosen[group.chosenIndex] = alts
            }

            // Exclude alternates from the "chosen" keep list used to
            // build ranges — they'll live on the chosen's segment as
            // AlternativeTake metadata, not as their own timeline range.
            let alternateIndices = Set(editDecision.duplicateGroups.flatMap(\.alternativeIndices))
            let sortedKeep = editDecision.keepIndices
                .filter { !alternateIndices.contains($0) }
                .sorted()

            // Build ranges per-keepIndex so we can keep track of
            // which keepIndex each range originates from (needed to
            // attach alternates correctly after merging).
            var indexedRanges: [IndexedRangeInput] = []
            for keepIdx in sortedKeep {
                guard keepIdx < local.transcript.count else { continue }
                let seg = local.transcript[keepIdx]
                let range = TimeRange(startSeconds: seg.startSeconds, endSeconds: seg.endSeconds)
                let splitRanges = Self.splitInternalSilence(
                    range: range,
                    words: local.rawWordTranscript,
                    silentRanges: local.silentRanges,
                    minimumSilenceToSplit: 0.45
                )

                let produced: [TimeRange]
                if !splitRanges.isEmpty {
                    produced = splitRanges
                } else {
                    let tightened = Self.tightenToWordBoundaries(
                        range: range,
                        words: local.rawWordTranscript,
                        leadingPadding: 0.04,
                        trailingPadding: 0.08
                    )
                    produced = [
                        Self.trimSilence(
                            from: tightened,
                            silentRanges: local.silentRanges,
                            breathingRoom: 0.04
                        )
                    ]
                }

                for (i, r) in produced.enumerated()
                where r.endSeconds > r.startSeconds + 0.1 {
                    // Only the first sub-range of a split-chosen
                    // carries the alternates so the swap UI doesn't
                    // duplicate the badge across every sub-range.
                    indexedRanges.append(
                        IndexedRangeInput(range: r, sourceIndex: i == 0 ? keepIdx : -1)
                    )
                }
            }

            // Merge overlapping or near-adjacent ranges while preserving
            // provenance. When two indexed ranges merge, union their
            // source indices so either can contribute alternates.
            let merged = Self.mergeIndexedOverlapping(indexedRanges)
            keptRanges = merged.map(\.range)

            // Build text labels for each merged range. Prefer word-level text so
            // split ranges don't all inherit the full parent sentence text.
            keptTexts = keptRanges.map { range in
                let wordText = Self.joinSegmentText(
                    local.rawWordTranscript
                        .filter { word in
                            word.endSeconds > range.startSeconds &&
                            word.startSeconds < range.endSeconds
                        }
                        .map(\.text)
                )
                if !wordText.isEmpty {
                    return wordText
                }

                let overlapping = local.transcript.filter { seg in
                    seg.endSeconds > range.startSeconds && seg.startSeconds < range.endSeconds
                }
                return Self.joinSegmentText(overlapping.map(\.text))
            }

            // Attach alternates: for each merged range, concatenate
            // alternates from every contributing chosen index.
            keptAlternatives = merged.map { indexed in
                var alts: [AlternativeTake] = []
                for idx in indexed.sourceIndices {
                    if let list = alternatesByChosen[idx] { alts.append(contentsOf: list) }
                }
                return alts
            }

            let isContiguous = sortedKeep.count <= 1 || zip(sortedKeep, sortedKeep.dropFirst()).allSatisfy { $1 == $0 + 1 }
            if isContiguous {
                suggestedIn = keptRanges.first?.startSeconds
                suggestedOut = keptRanges.last?.endSeconds
            } else {
                suggestedIn = nil
                suggestedOut = nil
            }
        } else {
            suggestedIn = nil
            suggestedOut = nil
        }

        // Build summary
        let keptCount = editDecision.keepIndices.count
        let cutCount = editDecision.cuts.count
        let totalCount = local.transcript.count
        var summary = buildSummary(local)
        if totalCount > 0 {
            summary += String(format: " AI recommends keeping %d/%d segments (cutting %d).", keptCount, totalCount, cutCount)
        }

        // Build edit log for UI display
        var logLines: [String] = []
        logLines.append("✅ Kept \(keptCount)/\(totalCount) segments:")
        for idx in editDecision.keepIndices.sorted() {
            if idx < local.transcript.count {
                let seg = local.transcript[idx]
                logLines.append("  [\(idx)] \(seg.text)")
            }
        }
        logLines.append("")
        logLines.append("❌ Removed \(cutCount) segments:")
        for cut in editDecision.cuts {
            if cut.index < local.transcript.count {
                let seg = local.transcript[cut.index]
                logLines.append("  [\(cut.index)] \(seg.text)")
                logLines.append("    → \(cut.reason)")
            }
        }
        let editLog = logLines.joined(separator: "\n")

        return AICopilotSnapshot(
            semanticTags: local.semanticTags,
            summary: summary,
            transcriptPreview: transcriptPreview.isEmpty ? nil : String(transcriptPreview.prefix(300)),
            suggestedInSeconds: suggestedIn,
            suggestedOutSeconds: suggestedOut,
            issues: local.audioIssues,
            suggestions: suggestions,
            markers: markers,
            keptRanges: keptRanges.isEmpty ? nil : keptRanges,
            keptTexts: keptTexts.isEmpty ? nil : keptTexts,
            keptAlternativesPerRange: keptAlternatives.isEmpty ? nil : keptAlternatives,
            transcript: local.transcript.isEmpty ? nil : local.transcript,
            wordTranscript: local.rawWordTranscript.isEmpty ? nil : local.rawWordTranscript,
            editLog: editLog,
            audioEnergyCurve: local.audioEnergyCurve
        )
    }

    // MARK: - Private

    private static func buildSummary(_ local: LocalAnalysisResult) -> String {
        var parts: [String] = []

        if local.hasTalkingHead {
            parts.append("Talking head clip detected.")
        }

        let segCount = local.transcript.count
        if segCount > 0 {
            let totalDuration = local.transcript.reduce(0.0) { $0 + $1.durationSeconds }
            parts.append(String(format: "%d transcript segments (%.0fs total).", segCount, totalDuration))
        } else {
            parts.append("No speech detected.")
        }

        if !local.sceneBoundaries.isEmpty {
            parts.append("\(local.sceneBoundaries.count) scene change(s) detected.")
        }

        return parts.joined(separator: " ")
    }

    private static func buildSceneMarkers(_ local: LocalAnalysisResult) -> [AICopilotMarker] {
        local.sceneBoundaries.map { boundary in
            AICopilotMarker(
                kind: .scene,
                seconds: boundary.seconds,
                label: boundary.label
            )
        }
    }

    /// Merge overlapping or near-adjacent time ranges into consolidated ranges.
    private static func mergeOverlapping(_ ranges: [TimeRange]) -> [TimeRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.startSeconds < $1.startSeconds }
        var merged: [TimeRange] = [sorted[0]]
        let adjacencyTolerance = 0.12

        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.startSeconds <= last.endSeconds + adjacencyTolerance {
                merged[merged.count - 1] = TimeRange(
                    startSeconds: last.startSeconds,
                    endSeconds: max(last.endSeconds, range.endSeconds)
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Same as `mergeOverlapping` but preserves the set of source
    /// keep-indices that contributed to each merged range so we can
    /// attach per-chosen alternates correctly.
    struct MergedIndexedRange { let range: TimeRange; let sourceIndices: [Int] }
    fileprivate static func mergeIndexedOverlapping(_ input: [IndexedRangeInput]) -> [MergedIndexedRange] {
        guard !input.isEmpty else { return [] }
        let sorted = input.sorted { $0.range.startSeconds < $1.range.startSeconds }
        var merged: [MergedIndexedRange] = [
            MergedIndexedRange(
                range: sorted[0].range,
                sourceIndices: sorted[0].sourceIndex >= 0 ? [sorted[0].sourceIndex] : []
            )
        ]
        let adjacencyTolerance = 0.12

        for entry in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if entry.range.startSeconds <= last.range.endSeconds + adjacencyTolerance {
                var indices = last.sourceIndices
                if entry.sourceIndex >= 0 && !indices.contains(entry.sourceIndex) {
                    indices.append(entry.sourceIndex)
                }
                merged[merged.count - 1] = MergedIndexedRange(
                    range: TimeRange(
                        startSeconds: last.range.startSeconds,
                        endSeconds: max(last.range.endSeconds, entry.range.endSeconds)
                    ),
                    sourceIndices: indices
                )
            } else {
                merged.append(MergedIndexedRange(
                    range: entry.range,
                    sourceIndices: entry.sourceIndex >= 0 ? [entry.sourceIndex] : []
                ))
            }
        }
        return merged
    }

    private static func tightenToWordBoundaries(
        range: TimeRange,
        words: [TranscriptSegment],
        leadingPadding: Double,
        trailingPadding: Double
    ) -> TimeRange {
        let overlappingWords = words.filter { word in
            word.endSeconds > range.startSeconds + 0.01 &&
            word.startSeconds < range.endSeconds - 0.01 &&
            !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard let firstWord = overlappingWords.first,
              let lastWord = overlappingWords.last else {
            return range
        }

        return TimeRange(
            startSeconds: max(0, firstWord.startSeconds - leadingPadding),
            endSeconds: lastWord.endSeconds + trailingPadding
        )
    }

    private static func splitInternalSilence(
        range: TimeRange,
        words: [TranscriptSegment],
        silentRanges: [ClosedRange<Double>],
        minimumSilenceToSplit: Double
    ) -> [TimeRange] {
        let tightened = tightenToWordBoundaries(
            range: range,
            words: words,
            leadingPadding: 0.04,
            trailingPadding: 0.08
        )

        let splitSilences = mergeSilentGaps(
            audioSilences: silentRanges,
            wordSilences: wordGapRanges(
                in: tightened,
                words: words,
                minimumGap: minimumSilenceToSplit
            ),
            within: tightened,
            minimumDuration: minimumSilenceToSplit
        )

        guard !splitSilences.isEmpty else { return [] }

        var speechRanges: [TimeRange] = []
        var cursor = tightened.startSeconds

        for silence in splitSilences {
            let candidate = TimeRange(startSeconds: cursor, endSeconds: silence.lowerBound)
            if let finalized = finalizeSpeechChunk(candidate, words: words, silentRanges: silentRanges) {
                speechRanges.append(finalized)
            }
            cursor = silence.upperBound
        }

        let tail = TimeRange(startSeconds: cursor, endSeconds: tightened.endSeconds)
        if let finalized = finalizeSpeechChunk(tail, words: words, silentRanges: silentRanges) {
            speechRanges.append(finalized)
        }

        return speechRanges
    }

    private static func finalizeSpeechChunk(
        _ candidate: TimeRange,
        words: [TranscriptSegment],
        silentRanges: [ClosedRange<Double>]
    ) -> TimeRange? {
        guard candidate.endSeconds > candidate.startSeconds + 0.08 else { return nil }

        let tightened = tightenToWordBoundaries(
            range: candidate,
            words: words,
            leadingPadding: 0.04,
            trailingPadding: 0.08
        )
        let trimmed = trimSilence(
            from: tightened,
            silentRanges: silentRanges,
            breathingRoom: 0.04
        )
        guard trimmed.endSeconds > trimmed.startSeconds + 0.08 else { return nil }
        return trimmed
    }

    private static func mergeSilentGaps(
        audioSilences: [ClosedRange<Double>],
        wordSilences: [ClosedRange<Double>],
        within range: TimeRange,
        minimumDuration: Double
    ) -> [ClosedRange<Double>] {
        let clipped = (audioSilences + wordSilences).compactMap { silence -> ClosedRange<Double>? in
            let start = max(range.startSeconds, silence.lowerBound)
            let end = min(range.endSeconds, silence.upperBound)
            guard end > start + minimumDuration else { return nil }
            guard start > range.startSeconds + 0.05 else { return nil }
            guard end < range.endSeconds - 0.05 else { return nil }
            return start...end
        }
        .sorted { $0.lowerBound < $1.lowerBound }

        guard var current = clipped.first else { return [] }
        var merged: [ClosedRange<Double>] = []

        for silence in clipped.dropFirst() {
            if silence.lowerBound <= current.upperBound + 0.05 {
                current = current.lowerBound...max(current.upperBound, silence.upperBound)
            } else {
                merged.append(current)
                current = silence
            }
        }

        merged.append(current)
        return merged
    }

    private static func wordGapRanges(
        in range: TimeRange,
        words: [TranscriptSegment],
        minimumGap: Double
    ) -> [ClosedRange<Double>] {
        let overlappingWords = words.filter { word in
            word.endSeconds > range.startSeconds &&
            word.startSeconds < range.endSeconds &&
            !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard overlappingWords.count > 1 else { return [] }

        return zip(overlappingWords, overlappingWords.dropFirst()).compactMap { previous, next in
            let gapStart = previous.endSeconds
            let gapEnd = next.startSeconds
            guard gapEnd > gapStart + minimumGap else { return nil }
            return gapStart...gapEnd
        }
    }

    private static func joinSegmentText(_ parts: [String]) -> String {
        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var result = cleaned.first else { return "" }

        for token in cleaned.dropFirst() {
            if shouldJoinWithoutSpace(previous: result.last, next: token.first) {
                result += token
            } else {
                result += " " + token
            }
        }

        return result
    }

    private static func shouldJoinWithoutSpace(previous: Character?, next: Character?) -> Bool {
        guard let previous, let next else { return false }
        if isCJK(previous) && isCJK(next) { return true }
        if isCJK(previous) && isPunctuation(next) { return true }
        if isPunctuation(previous) && isCJK(next) { return true }
        return false
    }

    private static func isCJK(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    private static func isPunctuation(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    /// Trim leading/trailing silence from a range, keeping breathingRoom seconds
    /// of silence so speech doesn't feel unnaturally cut.
    private static func trimSilence(
        from range: TimeRange,
        silentRanges: [ClosedRange<Double>],
        breathingRoom: Double,
        trailingBreathingRoom: Double? = nil
    ) -> TimeRange {
        var start = range.startSeconds
        var end = range.endSeconds
        // Chinese sentence-final syllables routinely trail 300-500ms of
        // decaying audio that the silence detector classifies as silence.
        // If we trim that to a tiny breathing room the last character's
        // audio gets lopped off. Keep the trailing trim generous enough
        // to match our upstream tail-pad (400ms) — bleed-through is
        // already prevented because paddedEnd is clamped to
        // `nextWord.start - epsilon`.
        let tailRoom = trailingBreathingRoom ?? max(breathingRoom, 0.5)

        // Trim leading silence
        for silence in silentRanges {
            if silence.lowerBound <= start + 0.05 && silence.upperBound > start && silence.upperBound < end {
                start = max(start, silence.upperBound - breathingRoom)
            }
        }

        // Trim trailing silence (preserve the tail-pad)
        for silence in silentRanges {
            if silence.upperBound >= end - 0.05 && silence.lowerBound < end && silence.lowerBound > start {
                end = min(end, silence.lowerBound + tailRoom)
            }
        }

        return TimeRange(startSeconds: max(0, start), endSeconds: end)
    }
}
