import XCTest
@testable import CuttiKit

final class HookCandidateScorerTests: XCTestCase {

    // MARK: - Length fit

    func test_lengthFit_idealReturnsOne() {
        let bounds = HookCandidateScorer.Bounds()
        XCTAssertEqual(HookCandidateScorer.lengthFit(duration: 5.0, bounds: bounds), 1.0, accuracy: 0.001)
    }

    func test_lengthFit_atBoundsReturnsZero() {
        let bounds = HookCandidateScorer.Bounds()
        XCTAssertEqual(HookCandidateScorer.lengthFit(duration: 2.5, bounds: bounds), 0, accuracy: 0.001)
        XCTAssertEqual(HookCandidateScorer.lengthFit(duration: 10.0, bounds: bounds), 0, accuracy: 0.001)
    }

    func test_lengthFit_outOfBoundsReturnsZero() {
        let bounds = HookCandidateScorer.Bounds()
        XCTAssertEqual(HookCandidateScorer.lengthFit(duration: 1.0, bounds: bounds), 0)
        XCTAssertEqual(HookCandidateScorer.lengthFit(duration: 100, bounds: bounds), 0)
    }

    func test_lengthFit_linearInterpolation() {
        let bounds = HookCandidateScorer.Bounds()
        // halfway from min to ideal: 2.5 -> 5.0, halfway is 3.75 → 0.5
        XCTAssertEqual(HookCandidateScorer.lengthFit(duration: 3.75, bounds: bounds), 0.5, accuracy: 0.01)
        // halfway from ideal to max: 5.0 -> 10.0, halfway is 7.5 → 0.5
        XCTAssertEqual(HookCandidateScorer.lengthFit(duration: 7.5, bounds: bounds), 0.5, accuracy: 0.01)
    }

    // MARK: - Position prior

    func test_positionPrior_intro() {
        XCTAssertEqual(HookCandidateScorer.positionPrior(midpoint: 0, sourceDuration: 100), 0.20, accuracy: 0.001)
    }

    func test_positionPrior_sweetSpot() {
        // 50% through → in [0.30, 0.80] flat plateau → 1.0
        XCTAssertEqual(HookCandidateScorer.positionPrior(midpoint: 50, sourceDuration: 100), 1.0, accuracy: 0.001)
        XCTAssertEqual(HookCandidateScorer.positionPrior(midpoint: 30, sourceDuration: 100), 1.0, accuracy: 0.001)
        XCTAssertEqual(HookCandidateScorer.positionPrior(midpoint: 80, sourceDuration: 100), 1.0, accuracy: 0.001)
    }

    func test_positionPrior_outro() {
        XCTAssertEqual(HookCandidateScorer.positionPrior(midpoint: 100, sourceDuration: 100), 0.40, accuracy: 0.001)
    }

    func test_positionPrior_smoothNoCliffs() {
        // Two values close to a former cliff boundary should be close.
        let p1 = HookCandidateScorer.positionPrior(midpoint: 4.9, sourceDuration: 100)
        let p2 = HookCandidateScorer.positionPrior(midpoint: 5.1, sourceDuration: 100)
        XCTAssertLessThan(abs(p1 - p2), 0.05, "Expected smooth piecewise-linear, not bucketed cliff")
    }

    func test_positionPrior_zeroDurationReturnsZero() {
        XCTAssertEqual(HookCandidateScorer.positionPrior(midpoint: 5, sourceDuration: 0), 0)
    }

    // MARK: - Filler counting (count-tier, language-agnostic)

    func test_countFillerHits_englishSingleWord() {
        let n = HookCandidateScorer.countFillerHits(in: "uh well, like I said", terms: ["uh", "like"])
        XCTAssertEqual(n, 2)
    }

    func test_countFillerHits_englishMultiWord() {
        let n = HookCandidateScorer.countFillerHits(in: "you know it's, you know, fine", terms: ["you know"])
        XCTAssertEqual(n, 2, "Expected substring-based count for multi-word filler")
    }

    func test_countFillerHits_chinese() {
        let n = HookCandidateScorer.countFillerHits(in: "嗯 那个 我觉得", terms: ["嗯", "那个"])
        XCTAssertEqual(n, 2)
    }

    func test_countFillerHits_singleWordEnglishDoesNotMatchSubstring() {
        // "alike" contains "like" but as a substring; we only want
        // whole-token matches for ASCII-alphanumeric single-word terms.
        let n = HookCandidateScorer.countFillerHits(in: "we alike sometimes", terms: ["like"])
        XCTAssertEqual(n, 0)
    }

    func test_countFillerHits_noMatch() {
        XCTAssertEqual(HookCandidateScorer.countFillerHits(in: "clean copy", terms: ["uh", "嗯"]), 0)
    }

    func test_antiFillerScore_tiers() {
        XCTAssertEqual(HookCandidateScorer.antiFillerScore(hits: 0), 1.0)
        XCTAssertEqual(HookCandidateScorer.antiFillerScore(hits: 1), 0.7, accuracy: 0.001)
        XCTAssertEqual(HookCandidateScorer.antiFillerScore(hits: 2), 0.4, accuracy: 0.001)
        XCTAssertEqual(HookCandidateScorer.antiFillerScore(hits: 5), 0.1, accuracy: 0.001)
    }

    // MARK: - Energy

    func test_energyTerm_neutralWhenNoCurve() {
        let v = HookCandidateScorer.energyTerm(start: 0, end: 5, curve: nil, denominator: 0)
        XCTAssertEqual(v, 0.5)
    }

    func test_energyTerm_neutralWhenZeroDenominator() {
        let curve = AudioEnergyCurve(values: [0.5, 0.5, 0.5], windowSeconds: 1.0)
        let v = HookCandidateScorer.energyTerm(start: 0, end: 2, curve: curve, denominator: 0)
        XCTAssertEqual(v, 0.5)
    }

    func test_energyTerm_normalizes() {
        let curve = AudioEnergyCurve(values: [0.2, 0.4, 0.8, 0.3, 0.1], windowSeconds: 1.0)
        let v = HookCandidateScorer.energyTerm(start: 0, end: 4, curve: curve, denominator: 1.0)
        XCTAssertEqual(v, 0.8, accuracy: 0.01)
    }

    func test_audioEnergyCurve_percentile() {
        let curve = AudioEnergyCurve(values: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0], windowSeconds: 1)
        XCTAssertEqual(curve.percentile(0.95), 1.0, accuracy: 0.01)
        // p=0.5 → idx = round(0.5 * 9) = round(4.5) = 4 (banker's
        // rounding to even) → values[4] = 0.5
        XCTAssertEqual(curve.percentile(0.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(curve.percentile(0), 0.1, accuracy: 0.01)
    }

    func test_audioEnergyCurve_percentile_emptyReturnsZero() {
        let curve = AudioEnergyCurve(values: [], windowSeconds: 1)
        XCTAssertEqual(curve.percentile(0.95), 0)
    }

    // MARK: - End-to-end ranking

    func test_scoreSources_ranksByOverallScore() {
        let id = UUID()
        let transcript = [
            // Plenty long, in sweet spot, no filler — should rank highest
            TranscriptSegment(startSeconds: 100, endSeconds: 105,
                              text: "This is the most important point of the entire conversation."),
            // Same length, has filler
            TranscriptSegment(startSeconds: 200, endSeconds: 205,
                              text: "Uh well, like, you know, kinda thing."),
            // Too short — must be filtered out by length
            TranscriptSegment(startSeconds: 300, endSeconds: 301,
                              text: "Yeah."),
        ]
        let source = HookSource(
            sourceVideoID: id,
            sourceName: "ep01.mov",
            durationSeconds: 600,
            transcript: transcript,
            energyCurve: nil
        )
        let (candidates, stats) = HookCandidateScorer.scoreSources(
            [source],
            fillerTerms: ["uh", "like", "you know", "kinda"]
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(stats.skippedByLength, 1)
        // Highest-scoring candidate is the no-filler one
        XCTAssertEqual(candidates[0].sourceStart, 100)
        XCTAssertGreaterThan(candidates[0].scoreOverall, candidates[1].scoreOverall)
    }

    func test_scoreSources_topKLimits() {
        let id = UUID()
        var transcript: [TranscriptSegment] = []
        for i in 0..<30 {
            let start = Double(i * 10)
            transcript.append(TranscriptSegment(
                startSeconds: start,
                endSeconds: start + 5,
                text: "Candidate number \(i) is here."
            ))
        }
        let source = HookSource(
            sourceVideoID: id,
            sourceName: nil,
            durationSeconds: 400,
            transcript: transcript,
            energyCurve: nil
        )
        let (candidates, _) = HookCandidateScorer.scoreSources(
            [source],
            fillerTerms: [],
            topK: 5
        )
        XCTAssertEqual(candidates.count, 5)
    }

    func test_scoreSources_invalidBoundsReturnsEmpty() {
        let source = HookSource(
            sourceVideoID: UUID(), sourceName: nil, durationSeconds: 60,
            transcript: [TranscriptSegment(startSeconds: 0, endSeconds: 5, text: "Hello world.")],
            energyCurve: nil
        )
        let bounds = HookCandidateScorer.Bounds(minDuration: 5, maxDuration: 3, idealDuration: 4)
        XCTAssertFalse(bounds.isValid)
        let (candidates, _) = HookCandidateScorer.scoreSources([source], fillerTerms: [], bounds: bounds)
        XCTAssertEqual(candidates.count, 0)
    }

    func test_scoreSources_emptyTextSkipped() {
        let source = HookSource(
            sourceVideoID: UUID(), sourceName: nil, durationSeconds: 60,
            transcript: [
                TranscriptSegment(startSeconds: 0, endSeconds: 5, text: "   "),
                TranscriptSegment(startSeconds: 10, endSeconds: 15, text: "Real content here.")
            ],
            energyCurve: nil
        )
        let (candidates, stats) = HookCandidateScorer.scoreSources([source], fillerTerms: [])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(stats.skippedEmpty, 1)
    }

    func test_scoreSources_deterministicAcrossRuns() {
        let id1 = UUID()
        let id2 = UUID()
        let segs1 = [TranscriptSegment(startSeconds: 100, endSeconds: 105, text: "Source 1 line.")]
        let segs2 = [TranscriptSegment(startSeconds: 100, endSeconds: 105, text: "Source 2 line.")]
        let s1 = HookSource(sourceVideoID: id1, sourceName: nil, durationSeconds: 200, transcript: segs1, energyCurve: nil)
        let s2 = HookSource(sourceVideoID: id2, sourceName: nil, durationSeconds: 200, transcript: segs2, energyCurve: nil)
        let runA = HookCandidateScorer.scoreSources([s1, s2], fillerTerms: []).candidates
        let runB = HookCandidateScorer.scoreSources([s2, s1], fillerTerms: []).candidates
        XCTAssertEqual(runA, runB, "Same inputs in different order must produce identical ranking")
    }

    func test_scoreSources_statsOnNoTranscriptSource() {
        let source = HookSource(
            sourceVideoID: UUID(), sourceName: nil, durationSeconds: 60,
            transcript: [], energyCurve: nil
        )
        let (cands, stats) = HookCandidateScorer.scoreSources([source], fillerTerms: [])
        XCTAssertEqual(cands.count, 0)
        XCTAssertEqual(stats.sourcesWithoutTranscript, 1)
    }

    // MARK: - synthesize(fromWords:)

    func test_synthesize_emptyInput() {
        XCTAssertEqual(HookCandidateScorer.synthesize(fromWords: []), [])
    }

    func test_synthesize_gapBreaksChunk() {
        let words = [
            TranscriptSegment(startSeconds: 0.0, endSeconds: 0.4, text: "hello"),
            TranscriptSegment(startSeconds: 0.4, endSeconds: 0.8, text: "world"),
            // Big gap (1s) → new chunk
            TranscriptSegment(startSeconds: 1.8, endSeconds: 2.2, text: "again"),
        ]
        let out = HookCandidateScorer.synthesize(fromWords: words, gapSeconds: 0.5, targetDuration: 10)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "hello world")
        XCTAssertEqual(out[1].text, "again")
    }

    func test_synthesize_targetDurationCaps() {
        // Words 1s apart, no gap, but cumulative > 5s should split.
        var words: [TranscriptSegment] = []
        for i in 0..<10 {
            let s = Double(i) * 1.0
            words.append(TranscriptSegment(startSeconds: s, endSeconds: s + 0.9, text: "w\(i)"))
        }
        let out = HookCandidateScorer.synthesize(fromWords: words, gapSeconds: 1.0, targetDuration: 5.0)
        XCTAssertGreaterThanOrEqual(out.count, 2)
        for chunk in out {
            XCTAssertLessThanOrEqual(chunk.durationSeconds, 6.0)
        }
    }

    // MARK: - Reason string formatting

    func test_reasonString_includesDuration() {
        let id = UUID()
        let source = HookSource(
            sourceVideoID: id, sourceName: nil, durationSeconds: 100,
            transcript: [TranscriptSegment(startSeconds: 50, endSeconds: 55, text: "Hello there.")],
            energyCurve: nil
        )
        let (cands, _) = HookCandidateScorer.scoreSources([source], fillerTerms: [])
        XCTAssertEqual(cands.count, 1)
        XCTAssertTrue(cands[0].reason.contains("5.0s"), "Reason should include duration")
    }
}
