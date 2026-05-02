import XCTest
@testable import CuttiMac

final class LLMEditorServiceTests: XCTestCase {
    func test_mergeReviewDecision_synthesizesCutsForRemovedIndices() {
        let base = LLMEditorService.EditDecision(
            keepIndices: [0, 1, 2],
            cuts: [
                .init(index: 4, reason: "existing")
            ]
        )

        let merged = LLMEditorService.mergeReviewDecision(
            baseDecision: base,
            reviewKeep: [1, 2],
            reviewCuts: [],
            synthesizedReason: "duplicate"
        )

        XCTAssertEqual(merged.keepIndices, [1, 2])
        XCTAssertEqual(Set(merged.cuts.map(\.index)), Set([0, 4]))
        XCTAssertEqual(merged.cuts.first(where: { $0.index == 0 })?.reason, "duplicate")
    }

    func test_mergeReviewDecision_keepsExplicitReviewReason() {
        let base = LLMEditorService.EditDecision(
            keepIndices: [0, 1],
            cuts: []
        )

        let merged = LLMEditorService.mergeReviewDecision(
            baseDecision: base,
            reviewKeep: [1],
            reviewCuts: [
                .init(index: 0, reason: "restart duplicate")
            ],
            synthesizedReason: "fallback"
        )

        XCTAssertEqual(merged.keepIndices, [1])
        XCTAssertEqual(merged.cuts.count, 1)
        XCTAssertEqual(merged.cuts.first?.index, 0)
        XCTAssertEqual(merged.cuts.first?.reason, "restart duplicate")
    }

    func test_mergeReviewDecision_addsDuplicateGroupsAndKeepsAllMembers() {
        let base = LLMEditorService.EditDecision(
            keepIndices: [0, 1, 2, 3],
            cuts: []
        )

        let merged = LLMEditorService.mergeReviewDecision(
            baseDecision: base,
            reviewKeep: [0, 1, 2, 3],
            reviewCuts: [],
            reviewGroups: [
                .init(chosenIndex: 2, alternativeIndices: [0, 1], reason: "重启重复")
            ],
            synthesizedReason: "x"
        )

        XCTAssertEqual(merged.keepIndices, [0, 1, 2, 3])
        XCTAssertEqual(merged.cuts.count, 0)
        XCTAssertEqual(merged.duplicateGroups.count, 1)
        XCTAssertEqual(merged.duplicateGroups.first?.chosenIndex, 2)
        XCTAssertEqual(merged.duplicateGroups.first?.alternativeIndices, [0, 1])
    }

    func test_mergeReviewDecision_dropsGroupsWithOverlappingMembers() {
        let existing = LLMEditorService.EditDecision.DuplicateGroup(
            chosenIndex: 1,
            alternativeIndices: [0],
            reason: "pre-existing"
        )
        let base = LLMEditorService.EditDecision(
            keepIndices: [0, 1, 2, 3],
            cuts: [],
            duplicateGroups: [existing]
        )

        let merged = LLMEditorService.mergeReviewDecision(
            baseDecision: base,
            reviewKeep: [0, 1, 2, 3],
            reviewCuts: [],
            // Attempt to re-group index 0 into a different group — must be rejected.
            reviewGroups: [
                .init(chosenIndex: 3, alternativeIndices: [0], reason: "conflict")
            ],
            synthesizedReason: "x"
        )

        XCTAssertEqual(merged.duplicateGroups.count, 1)
        XCTAssertEqual(merged.duplicateGroups.first?.reason, "pre-existing")
    }

    func test_parseDuplicateGroups_skipsInvalidAndDuplicateIndices() {
        let groups = LLMEditorService.parseDuplicateGroups(
            [
                ["chosen_index": 1, "alternative_indices": [0], "reason": "a"],
                // duplicate member (1 already claimed) — must be dropped
                ["chosen_index": 2, "alternative_indices": [1], "reason": "b"],
                // out-of-range chosen — must be dropped
                ["chosen_index": 99, "alternative_indices": [3], "reason": "c"],
                // empty alternatives — must be dropped
                ["chosen_index": 4, "alternative_indices": [Int](), "reason": "d"],
            ],
            validRange: Set(0..<5)
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.chosenIndex, 1)
        XCTAssertEqual(groups.first?.alternativeIndices, [0])
    }
}
