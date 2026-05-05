import Foundation

// MARK: - Hook candidate scorer (stage-1, deterministic, language-agnostic)
//
// Local-only scorer for cold-open / opening-hook discovery. Given the per-
// source transcript + (optional) audio energy curve, produces a ranked list
// of candidate spans the user could splice to composed time 0.
//
// Stage 2 (LLM rerank) lives separately — see `score_hook_candidates` /
// PR 4. Stage-1 alone is meant to be useful: it filters by length,
// position, filler density, and energy, and surfaces the top-K. That is
// enough to ship a working "AI 自己挑一个开场金句" UX even for users
// who run on BYOK and don't trigger the cloud rerank.
//
// Design notes (from the PR-3 rubber-duck pass):
//   * Anti-filler is COUNT-tiered, not ratio-based, so multi-word terms
//     ("you know") and Chinese tokenisation (no whitespace) don't inflate
//     or deflate the score in language-specific ways.
//   * Energy normalisation defaults to the curve's 95th percentile, not
//     `globalPeak` — one mic bump no longer flattens every other
//     candidate's energy score.
//   * Position prior is piecewise-linear (no cliff buckets).
//   * Sources lacking sentence-level transcripts can fall back to gluing
//     `wordTranscript` into chunks via `HookCandidateScorer.synthesize(...)`.

public struct HookSource: Sendable {
    public let sourceVideoID: UUID
    public let sourceName: String?
    public let durationSeconds: Double
    /// Sentence-level utterances. Each entry is one candidate before
    /// length / filler / energy filtering. Pass `[]` if you only have
    /// word-level data; call `HookCandidateScorer.synthesize(fromWords:)`
    /// to build chunks from a word transcript first.
    public let transcript: [TranscriptSegment]
    /// Optional. If present and `globalPeak > 0`, the energy term in the
    /// score uses this curve. Otherwise that term is a neutral 0.5.
    public let energyCurve: AudioEnergyCurve?

    public init(
        sourceVideoID: UUID,
        sourceName: String?,
        durationSeconds: Double,
        transcript: [TranscriptSegment],
        energyCurve: AudioEnergyCurve?
    ) {
        self.sourceVideoID = sourceVideoID
        self.sourceName = sourceName
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.energyCurve = energyCurve
    }
}

/// One ranked hook candidate. The natural identifier is the tuple
/// `(sourceVideoID, sourceStart, sourceEnd)` — that's what `insertSourceClip`
/// (PR 2) consumes. We deliberately do NOT carry a UUID `id` field because
/// stable-across-runs identifiers add complexity without real value here.
public struct HookCandidate: Codable, Equatable, Sendable {
    public let sourceVideoID: UUID
    public let sourceName: String?
    public let sourceStart: Double
    public let sourceEnd: Double
    public let text: String
    public let scoreOverall: Double
    public let scoreLength: Double
    public let scorePosition: Double
    public let scoreAntiFiller: Double
    public let scoreEnergy: Double
    /// Short human-readable summary of why this candidate ranks where it
    /// does, e.g. `"5.2s · 中段 · 高能量 · 0 填充词"`. UI / logs only.
    public let reason: String
    /// Stage-2 LLM rerank "punch" score on a 1–10 scale. Set by the
    /// optional rerank engine; `nil` when the rerank step was skipped
    /// or fell back to stage-1. Kept distinct from `scoreOverall` so
    /// logs preserve the heuristic-vs-taste split.
    public var llmPunchScore: Double?
    /// Stage-2 LLM 1–2 sentence reasoning for the rerank decision, in
    /// the candidate's own language. `nil` when rerank was skipped /
    /// fell back. Surfaced verbatim in the candidate-card UI (PR 6).
    public var llmReasoning: String?

    public init(
        sourceVideoID: UUID,
        sourceName: String?,
        sourceStart: Double,
        sourceEnd: Double,
        text: String,
        scoreOverall: Double,
        scoreLength: Double,
        scorePosition: Double,
        scoreAntiFiller: Double,
        scoreEnergy: Double,
        reason: String,
        llmPunchScore: Double? = nil,
        llmReasoning: String? = nil
    ) {
        self.sourceVideoID = sourceVideoID
        self.sourceName = sourceName
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.text = text
        self.scoreOverall = scoreOverall
        self.scoreLength = scoreLength
        self.scorePosition = scorePosition
        self.scoreAntiFiller = scoreAntiFiller
        self.scoreEnergy = scoreEnergy
        self.reason = reason
        self.llmPunchScore = llmPunchScore
        self.llmReasoning = llmReasoning
    }
}

/// Aggregate counters returned alongside the top-K. Surfaces "why so few?"
/// so the LLM / UI can explain (e.g. "no sources have transcripts yet —
/// run First Cut first").
public struct HookCandidateStats: Codable, Equatable, Sendable {
    public let sourcesScanned: Int
    public let sourcesWithoutTranscript: Int
    public let totalSegmentsConsidered: Int
    public let skippedByLength: Int
    public let skippedEmpty: Int
    public init(
        sourcesScanned: Int,
        sourcesWithoutTranscript: Int,
        totalSegmentsConsidered: Int,
        skippedByLength: Int,
        skippedEmpty: Int
    ) {
        self.sourcesScanned = sourcesScanned
        self.sourcesWithoutTranscript = sourcesWithoutTranscript
        self.totalSegmentsConsidered = totalSegmentsConsidered
        self.skippedByLength = skippedByLength
        self.skippedEmpty = skippedEmpty
    }
}

public enum HookCandidateScorer {

    public struct Bounds: Sendable, Equatable {
        public var minDuration: Double
        public var maxDuration: Double
        public var idealDuration: Double
        public init(
            minDuration: Double = 2.5,
            maxDuration: Double = 10.0,
            idealDuration: Double = 5.0
        ) {
            self.minDuration = minDuration
            self.maxDuration = maxDuration
            self.idealDuration = idealDuration
        }

        /// True iff bounds are positive and ordered: `0 < min ≤ ideal ≤ max`.
        public var isValid: Bool {
            minDuration > 0 && idealDuration >= minDuration && maxDuration >= idealDuration
        }
    }

    public struct Weights: Sendable, Equatable {
        public var length: Double
        public var position: Double
        public var antiFiller: Double
        public var energy: Double
        public init(
            length: Double = 0.30,
            position: Double = 0.10,
            antiFiller: Double = 0.30,
            energy: Double = 0.30
        ) {
            self.length = length
            self.position = position
            self.antiFiller = antiFiller
            self.energy = energy
        }
    }

    // MARK: - Public API

    /// Score every transcript segment in every source, return the top-K
    /// across all sources sorted by overall score (descending). Ties are
    /// broken by `sourceVideoID.uuidString` then `sourceStart`, so output
    /// is fully deterministic given the same inputs.
    public static func scoreSources(
        _ sources: [HookSource],
        fillerTerms: [String],
        weights: Weights = .init(),
        bounds: Bounds = .init(),
        topK: Int = 20
    ) -> (candidates: [HookCandidate], stats: HookCandidateStats) {
        guard bounds.isValid else {
            return ([], HookCandidateStats(
                sourcesScanned: sources.count,
                sourcesWithoutTranscript: 0,
                totalSegmentsConsidered: 0,
                skippedByLength: 0,
                skippedEmpty: 0
            ))
        }
        let normalizedFillers = normalizeFillerTerms(fillerTerms)

        var allCandidates: [HookCandidate] = []
        var sourcesWithoutTranscript = 0
        var totalConsidered = 0
        var skippedByLength = 0
        var skippedEmpty = 0

        for source in sources {
            if source.transcript.isEmpty {
                sourcesWithoutTranscript += 1
                continue
            }
            // p95 of windowRMSValues — robust against single-frame
            // outliers (laughter, mic bump). Falls back to globalPeak
            // when the curve is empty / nil.
            let energyDenominator: Double = {
                guard let curve = source.energyCurve, !curve.values.isEmpty else { return 0 }
                let p95 = curve.percentile(0.95)
                let peak = curve.globalPeak
                // Floor the denominator at 50% of globalPeak so an
                // exceptionally peaky episode still produces meaningful
                // ranks (otherwise p95 could be ~globalPeak anyway).
                return Swift.max(p95, peak * 0.5)
            }()

            for entry in source.transcript {
                totalConsidered += 1
                let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    skippedEmpty += 1
                    continue
                }
                let dur = entry.durationSeconds
                if dur < bounds.minDuration || dur > bounds.maxDuration {
                    skippedByLength += 1
                    continue
                }
                let lenScore = lengthFit(duration: dur, bounds: bounds)
                let posScore = positionPrior(
                    midpoint: (entry.startSeconds + entry.endSeconds) * 0.5,
                    sourceDuration: source.durationSeconds
                )
                let fillerHits = countFillerHits(in: trimmed, terms: normalizedFillers)
                let antiFiller = antiFillerScore(hits: fillerHits)
                let energyScore = energyTerm(
                    start: entry.startSeconds,
                    end: entry.endSeconds,
                    curve: source.energyCurve,
                    denominator: energyDenominator
                )
                let overall = clampUnit(
                    weights.length * lenScore
                    + weights.position * posScore
                    + weights.antiFiller * antiFiller
                    + weights.energy * energyScore
                )
                allCandidates.append(HookCandidate(
                    sourceVideoID: source.sourceVideoID,
                    sourceName: source.sourceName,
                    sourceStart: entry.startSeconds,
                    sourceEnd: entry.endSeconds,
                    text: trimmed,
                    scoreOverall: overall,
                    scoreLength: lenScore,
                    scorePosition: posScore,
                    scoreAntiFiller: antiFiller,
                    scoreEnergy: energyScore,
                    reason: makeReason(
                        duration: dur,
                        positionScore: posScore,
                        energyScore: energyScore,
                        fillerHits: fillerHits
                    )
                ))
            }
        }

        // Deterministic descending sort.
        allCandidates.sort { lhs, rhs in
            if lhs.scoreOverall != rhs.scoreOverall {
                return lhs.scoreOverall > rhs.scoreOverall
            }
            if lhs.sourceVideoID.uuidString != rhs.sourceVideoID.uuidString {
                return lhs.sourceVideoID.uuidString < rhs.sourceVideoID.uuidString
            }
            return lhs.sourceStart < rhs.sourceStart
        }
        let trimmed = Array(allCandidates.prefix(Swift.max(0, topK)))
        return (
            trimmed,
            HookCandidateStats(
                sourcesScanned: sources.count,
                sourcesWithoutTranscript: sourcesWithoutTranscript,
                totalSegmentsConsidered: totalConsidered,
                skippedByLength: skippedByLength,
                skippedEmpty: skippedEmpty
            )
        )
    }

    /// Glue word-level transcript fragments into sentence-ish chunks for
    /// sources that only carry a `wordTranscript` (no `transcript`). Two
    /// boundary heuristics:
    ///   * gap to the next word > `gapSeconds` → flush
    ///   * cumulative duration of the current chunk reaches
    ///     `targetDuration` → flush
    /// The result is suitable to feed straight into `scoreSources(...)`
    /// as a `HookSource.transcript`. Empty input → empty output.
    public static func synthesize(
        fromWords words: [TranscriptSegment],
        gapSeconds: Double = 0.5,
        targetDuration: Double = 5.0
    ) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }
        let sorted = words.sorted { $0.startSeconds < $1.startSeconds }
        var out: [TranscriptSegment] = []
        var chunkStart = sorted[0].startSeconds
        var chunkEnd = sorted[0].endSeconds
        var chunkText = sorted[0].text
        for next in sorted.dropFirst() {
            let gap = next.startSeconds - chunkEnd
            let projectedDuration = next.endSeconds - chunkStart
            if gap > gapSeconds || projectedDuration > targetDuration {
                out.append(TranscriptSegment(
                    startSeconds: chunkStart,
                    endSeconds: chunkEnd,
                    text: chunkText.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceVideoID: sorted[0].sourceVideoID
                ))
                chunkStart = next.startSeconds
                chunkEnd = next.endSeconds
                chunkText = next.text
            } else {
                chunkEnd = next.endSeconds
                let needsSpace = !chunkText.isEmpty && chunkText.last != " "
                chunkText += (needsSpace ? " " : "") + next.text
            }
        }
        out.append(TranscriptSegment(
            startSeconds: chunkStart,
            endSeconds: chunkEnd,
            text: chunkText.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceVideoID: sorted[0].sourceVideoID
        ))
        return out
    }

    // MARK: - Sub-score helpers (internal, exposed for tests)

    /// Triangular fit centered on `idealDuration`, zero at either bound.
    /// Linear on each side. Out-of-range → 0 (caller already filters
    /// these but the helper is total).
    public static func lengthFit(duration d: Double, bounds: Bounds) -> Double {
        guard bounds.isValid else { return 0 }
        if d < bounds.minDuration || d > bounds.maxDuration { return 0 }
        if d == bounds.idealDuration { return 1 }
        if d < bounds.idealDuration {
            let denom = bounds.idealDuration - bounds.minDuration
            return denom > 0 ? clampUnit((d - bounds.minDuration) / denom) : 1
        }
        let denom = bounds.maxDuration - bounds.idealDuration
        return denom > 0 ? clampUnit((bounds.maxDuration - d) / denom) : 1
    }

    /// Piecewise-linear position prior in `[0, 1]`. Knots:
    ///   `(0.00, 0.20)` greeting/intro → low
    ///   `(0.05, 0.60)` rising action
    ///   `(0.30, 1.00)` content sweet spot
    ///   `(0.80, 1.00)` content sweet spot still
    ///   `(1.00, 0.40)` outro
    /// `sourceDuration ≤ 0` → 0 (degenerate, skip ranking).
    public static func positionPrior(midpoint: Double, sourceDuration: Double) -> Double {
        guard sourceDuration > 0 else { return 0 }
        let p = clampUnit(midpoint / sourceDuration)
        let knots: [(Double, Double)] = [
            (0.00, 0.20),
            (0.05, 0.60),
            (0.30, 1.00),
            (0.80, 1.00),
            (1.00, 0.40)
        ]
        // Linear interp between nearest two knots.
        for i in 0..<(knots.count - 1) {
            let (x0, y0) = knots[i]
            let (x1, y1) = knots[i + 1]
            if p >= x0 && p <= x1 {
                if x1 == x0 { return y0 }
                let t = (p - x0) / (x1 - x0)
                return y0 + (y1 - y0) * t
            }
        }
        return knots.last?.1 ?? 0
    }

    /// Count distinct filler-term hits in `text` (case-insensitive).
    /// Multi-word terms ("you know", "i mean") are matched as substrings.
    /// Single-word English terms ("uh", "like") are matched as whole
    /// tokens (so "alike" doesn't trigger "like"). Chinese terms ("嗯",
    /// "那个") are matched as substrings — Chinese has no word boundaries
    /// to anchor on, and the canonical filler list there is short and
    /// contains no false-positive prefixes ("呃" doesn't appear inside
    /// real content words).
    public static func countFillerHits(in text: String, terms: [String]) -> Int {
        guard !text.isEmpty, !terms.isEmpty else { return 0 }
        let lowered = text.lowercased()
        let words = lowered.unicodeScalars
            .split { !CharacterSet.letters.union(.decimalDigits).contains($0) }
            .map { String($0) }
        let wordSet = Set(words)
        var hits = 0
        for term in terms {
            if term.isEmpty { continue }
            if term.contains(" ") {
                hits += occurrences(of: term, in: lowered)
            } else if isAsciiAlphanumeric(term) {
                if wordSet.contains(term) {
                    hits += words.filter { $0 == term }.count
                }
            } else {
                hits += occurrences(of: term, in: lowered)
            }
        }
        return hits
    }

    /// Tiered penalty rather than a ratio — robust across languages
    /// and handles multi-word fillers consistently.
    public static func antiFillerScore(hits: Int) -> Double {
        switch hits {
        case ..<1:  return 1.0
        case 1:     return 0.7
        case 2:     return 0.4
        default:    return 0.1
        }
    }

    public static func energyTerm(
        start: Double,
        end: Double,
        curve: AudioEnergyCurve?,
        denominator: Double
    ) -> Double {
        guard let curve = curve, !curve.values.isEmpty, denominator > 0 else {
            return 0.5
        }
        let peak = curve.peakIn(startSeconds: start, endSeconds: end)
        return clampUnit(peak / denominator)
    }

    // MARK: - Private helpers

    private static func clampUnit(_ x: Double) -> Double {
        Swift.max(0, Swift.min(1, x))
    }

    private static func normalizeFillerTerms(_ terms: [String]) -> [String] {
        terms
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isAsciiAlphanumeric(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if !((scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)) {
                return false
            }
        }
        return !s.isEmpty
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex
        while let r = haystack.range(of: needle, options: [], range: search..<haystack.endIndex) {
            count += 1
            search = r.upperBound
        }
        return count
    }

    private static func makeReason(
        duration: Double,
        positionScore: Double,
        energyScore: Double,
        fillerHits: Int
    ) -> String {
        let durStr = String(format: "%.1fs", duration)
        let positionStr: String
        if positionScore >= 0.9 { positionStr = "中段" }
        else if positionScore >= 0.6 { positionStr = "前段" }
        else if positionScore >= 0.4 { positionStr = "尾段" }
        else { positionStr = "开场" }
        let energyStr: String
        if energyScore >= 0.75 { energyStr = "高能量" }
        else if energyScore >= 0.45 { energyStr = "中能量" }
        else { energyStr = "低能量" }
        let fillerStr = fillerHits == 0 ? "0 填充词" : "\(fillerHits) 填充词"
        return "\(durStr) · \(positionStr) · \(energyStr) · \(fillerStr)"
    }
}
