import XCTest
import CuttiKit
@testable import CuttiMac

final class HookCandidateRerankEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeCandidate(
        idx: Int,
        text: String = "candidate text",
        overall: Double = 0.5
    ) -> HookCandidate {
        HookCandidate(
            sourceVideoID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(idx)") ?? UUID(),
            sourceName: "src\(idx).mov",
            sourceStart: Double(idx),
            sourceEnd: Double(idx) + 5,
            text: text,
            scoreOverall: overall,
            scoreLength: 0.6,
            scorePosition: 0.7,
            scoreAntiFiller: 1.0,
            scoreEnergy: 0.5,
            reason: "5.0s · stub"
        )
    }

    private func makePool(_ n: Int) -> [HookCandidate] {
        (0..<n).map { i in
            // Decreasing overall, so stage-1 order is 0,1,2,...
            makeCandidate(idx: i, text: "candidate \(i)", overall: 1.0 - Double(i) * 0.05)
        }
    }

    // MARK: - Parser: well-formed

    func test_parser_wellFormedRespectsLLMOrder() {
        let pool = makePool(5)
        let args = """
        {"ranked": [
          {"candidate_index": 2, "punch_score": 9.5, "reasoning": "very punchy"},
          {"candidate_index": 0, "punch_score": 8.0, "reasoning": "ok"},
          {"candidate_index": 4, "punch_score": 7.0, "reasoning": "decent"}
        ]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 3
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?[0].text, "candidate 2")
        XCTAssertEqual(result?[0].llmPunchScore, 9.5)
        XCTAssertEqual(result?[0].llmReasoning, "very punchy")
        XCTAssertEqual(result?[1].text, "candidate 0")
        XCTAssertEqual(result?[2].text, "candidate 4")
    }

    // MARK: - Parser: out-of-range index dropped

    func test_parser_outOfRangeIndexDropped() {
        let pool = makePool(3)
        let args = """
        {"ranked": [
          {"candidate_index": 99, "punch_score": 9.0, "reasoning": "x"},
          {"candidate_index": -1, "punch_score": 5.0, "reasoning": "y"},
          {"candidate_index": 1, "punch_score": 8.0, "reasoning": "valid"}
        ]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 1
        )
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.text, "candidate 1")
    }

    // MARK: - Parser: punch_score clamping

    func test_parser_punchScoreClampedLow() {
        let pool = makePool(2)
        let args = """
        {"ranked": [{"candidate_index": 0, "punch_score": 0.0, "reasoning": ""}]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 1
        )
        XCTAssertEqual(result?.first?.llmPunchScore, 1.0)
    }

    func test_parser_punchScoreClampedHigh() {
        let pool = makePool(2)
        let args = """
        {"ranked": [{"candidate_index": 0, "punch_score": 50.0, "reasoning": ""}]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 1
        )
        XCTAssertEqual(result?.first?.llmPunchScore, 10.0)
    }

    // MARK: - Parser: int vs double punch_score

    func test_parser_intPunchScore() {
        let pool = makePool(2)
        let args = """
        {"ranked": [{"candidate_index": 0, "punch_score": 8, "reasoning": ""}]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 1
        )
        XCTAssertEqual(result?.first?.llmPunchScore, 8.0)
    }

    func test_parser_intCandidateIndex() {
        let pool = makePool(2)
        // JSON parsers may type-detect numbers — verify we accept both
        // candidate_index: 1 (Int) and candidate_index: 1.0 (Double).
        let args = """
        {"ranked": [{"candidate_index": 1.0, "punch_score": 7.5}]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 1
        )
        XCTAssertEqual(result?.first?.text, "candidate 1")
    }

    // MARK: - Parser: missing reasoning defaults to ""

    func test_parser_missingReasoningEmptyString() {
        let pool = makePool(2)
        let args = """
        {"ranked": [{"candidate_index": 0, "punch_score": 5}]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 1
        )
        XCTAssertEqual(result?.first?.llmReasoning, "")
    }

    // MARK: - Parser: dedup on duplicate indices, first wins

    func test_parser_duplicateIndexDedupedFirstWins() {
        let pool = makePool(3)
        let args = """
        {"ranked": [
          {"candidate_index": 1, "punch_score": 9, "reasoning": "first"},
          {"candidate_index": 1, "punch_score": 5, "reasoning": "second"},
          {"candidate_index": 2, "punch_score": 7, "reasoning": "third"}
        ]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 2
        )
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].text, "candidate 1")
        XCTAssertEqual(result?[0].llmReasoning, "first")
        XCTAssertEqual(result?[1].text, "candidate 2")
    }

    // MARK: - Parser: partial fill from stage-one leftovers

    func test_parser_partialFillFromStageOneLeftover() {
        let pool = makePool(5)
        // LLM only ranks 1 candidate; we asked for 3. Remaining 2
        // slots fill from stage-1 order: 0, 2, 3, 4 (1 already picked) →
        // first leftover after picked={1} in stageOneFull is 0.
        let args = """
        {"ranked": [
          {"candidate_index": 1, "punch_score": 9, "reasoning": "only valid"}
        ]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 3
        )
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?[0].text, "candidate 1")
        // First fill = stageOneFull[0] (skipping idx 1 since picked)
        XCTAssertEqual(result?[1].text, "candidate 0")
        XCTAssertEqual(result?[1].llmPunchScore, nil) // fill candidates have no LLM fields
        XCTAssertEqual(result?[2].text, "candidate 2")
    }

    // MARK: - Parser: hard fallbacks (return nil → engine emits status=fallback)

    func test_parser_malformedArgsReturnsNil() {
        let pool = makePool(3)
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: "not json at all",
            stageOnePool: pool,
            stageOneFull: pool,
            topK: 1
        )
        XCTAssertNil(result)
    }

    func test_parser_missingRankedKeyReturnsNil() {
        let pool = makePool(3)
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: "{\"other\": []}",
            stageOnePool: pool,
            stageOneFull: pool,
            topK: 1
        )
        XCTAssertNil(result)
    }

    func test_parser_emptyRankedReturnsNil() {
        let pool = makePool(3)
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: "{\"ranked\": []}",
            stageOnePool: pool,
            stageOneFull: pool,
            topK: 1
        )
        XCTAssertNil(result)
    }

    func test_parser_allEntriesInvalidReturnsNil() {
        let pool = makePool(3)
        let args = """
        {"ranked": [
          {"candidate_index": 99},
          {"candidate_index": -1}
        ]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 1
        )
        XCTAssertNil(result)
    }

    // MARK: - Wall-clock timeout

    func test_timeout_completesBeforeDeadline() async throws {
        let result = try await HookCandidateRerankEngine.withWallClockTimeout(seconds: 1.0) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return 42
        }
        XCTAssertEqual(result, 42)
    }

    func test_timeout_exceedsDeadlineThrows() async {
        do {
            _ = try await HookCandidateRerankEngine.withWallClockTimeout(seconds: 0.1) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 0
            }
            XCTFail("expected timeout")
        } catch {
            // any thrown error is fine — the engine catches and falls back
        }
    }

    // MARK: - Top-K edge cases

    func test_parser_extraEntriesBeyondTopKDropped() {
        let pool = makePool(5)
        let args = """
        {"ranked": [
          {"candidate_index": 0, "punch_score": 9},
          {"candidate_index": 1, "punch_score": 8},
          {"candidate_index": 2, "punch_score": 7},
          {"candidate_index": 3, "punch_score": 6},
          {"candidate_index": 4, "punch_score": 5}
        ]}
        """
        let result = HookCandidateRerankEngine.parseRerankResponse(
            arguments: args, stageOnePool: pool, stageOneFull: pool, topK: 2
        )
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].text, "candidate 0")
        XCTAssertEqual(result?[1].text, "candidate 1")
    }
}
