import XCTest
import CuttiKit
@testable import CuttiMac

final class ChatAttachmentScopeTests: XCTestCase {
    private func makeSegment(
        id: UUID = UUID(),
        sourceVideoID: UUID = UUID(),
        start: Double,
        end: Double,
        speedRate: Double = 1.0
    ) -> TimelineSegment {
        var seg = TimelineSegment(
            id: id,
            sourceVideoID: sourceVideoID,
            range: TimeRange(startSeconds: start, endSeconds: end),
            text: "",
            subtitles: []
        )
        seg.speedRate = speedRate
        return seg
    }

    private func makeAttachment(
        segmentID: UUID,
        composedStart: Double,
        composedEnd: Double
    ) -> ChatAttachment {
        ChatAttachment(
            segmentID: segmentID,
            composedStart: composedStart,
            composedEnd: composedEnd,
            sourceVideoID: UUID(),
            sourceStartSeconds: 0
        )
    }

    // MARK: - Virtual <-> Composed translation

    func test_singleSegment_virtualMatchesComposedOffset() {
        let segID = UUID()
        let attachment = makeAttachment(segmentID: segID, composedStart: 10, composedEnd: 15)
        let scope = ChatAttachmentScope(attachments: [attachment])

        XCTAssertEqual(scope.virtualDuration, 5, accuracy: 1e-6)
        XCTAssertEqual(scope.entries.count, 1)

        // User says "delete 2s..5s" (virtual) -> composed 12..15
        let composed = scope.composedRanges(forVirtualStart: 2, end: 5)
        XCTAssertEqual(composed?.count, 1)
        XCTAssertEqual(composed?.first?.lowerBound ?? 0, 12, accuracy: 1e-6)
        XCTAssertEqual(composed?.first?.upperBound ?? 0, 15, accuracy: 1e-6)
    }

    func test_twoSegments_virtualRangeSpanningBoundaryDecomposes() {
        let a = makeAttachment(segmentID: UUID(), composedStart: 10, composedEnd: 15) // 5s
        let b = makeAttachment(segmentID: UUID(), composedStart: 30, composedEnd: 34) // 4s
        let scope = ChatAttachmentScope(attachments: [a, b])

        XCTAssertEqual(scope.virtualDuration, 9, accuracy: 1e-6)

        // Virtual [3, 7] crosses boundary at v=5 -> composed [13,15] + [30,32]
        let ranges = scope.composedRanges(forVirtualStart: 3, end: 7)
        XCTAssertEqual(ranges?.count, 2)
        XCTAssertEqual(ranges?[0].lowerBound ?? 0, 13, accuracy: 1e-6)
        XCTAssertEqual(ranges?[0].upperBound ?? 0, 15, accuracy: 1e-6)
        XCTAssertEqual(ranges?[1].lowerBound ?? 0, 30, accuracy: 1e-6)
        XCTAssertEqual(ranges?[1].upperBound ?? 0, 32, accuracy: 1e-6)
    }

    func test_containsComposedRange_trueForInside_falseForOutside() {
        let a = makeAttachment(segmentID: UUID(), composedStart: 10, composedEnd: 15)
        let b = makeAttachment(segmentID: UUID(), composedStart: 30, composedEnd: 34)
        let scope = ChatAttachmentScope(attachments: [a, b])

        XCTAssertTrue(scope.containsComposedRange(start: 11, end: 14))
        XCTAssertTrue(scope.containsComposedRange(start: 30, end: 34))
        XCTAssertFalse(scope.containsComposedRange(start: 20, end: 25))       // gap
        XCTAssertFalse(scope.containsComposedRange(start: 5, end: 12))        // partially outside (before)
        XCTAssertFalse(scope.containsComposedRange(start: 13, end: 31))       // spans gap
    }

    // MARK: - ScopeGuard

    func test_scopeGuard_passesThroughWhenScopeEmpty() {
        let batch = AIActionBatch(
            actions: [.deleteRange(start: 5, end: 10)],
            explanation: ""
        )
        let result = ScopeGuard.filter(
            batch: batch,
            scope: ChatAttachmentScope(attachments: []),
            segments: []
        )
        XCTAssertEqual(result.kept.actions.count, 1)
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func test_scopeGuard_keepsInScopeRangeRejectsOutOfScope() {
        let segA = makeSegment(id: UUID(), start: 0, end: 5)   // 5s composed
        let segB = makeSegment(id: UUID(), start: 0, end: 10)  // 10s composed (total timeline 15s)
        let segments = [segA, segB]
        // Attach only segB; its composed range is 5..15.
        let attachment = makeAttachment(segmentID: segB.id, composedStart: 5, composedEnd: 15)
        let scope = ChatAttachmentScope(attachments: [attachment])

        let batch = AIActionBatch(
            actions: [
                .deleteRange(start: 6, end: 10),   // inside segB composed 5..15 ✔
                .deleteRange(start: 0, end: 3),    // inside segA, outside scope ✘
                .deleteSegment(id: segA.id)        // outside scope ✘
            ],
            explanation: ""
        )

        let result = ScopeGuard.filter(batch: batch, scope: scope, segments: segments)
        XCTAssertEqual(result.kept.actions.count, 1)
        XCTAssertEqual(result.rejected.count, 2)
    }

    func test_scopeGuard_rejectsTimelineWideSubtitleActions() {
        let seg = makeSegment(id: UUID(), start: 0, end: 5)
        let attachment = makeAttachment(segmentID: seg.id, composedStart: 0, composedEnd: 5)
        let scope = ChatAttachmentScope(attachments: [attachment])

        let batch = AIActionBatch(
            actions: [
                .replaceSubtitleText(find: "um", replaceWith: "", isRegex: false),
                .setSubtitlesVisible(visible: false)
            ],
            explanation: ""
        )
        let result = ScopeGuard.filter(batch: batch, scope: scope, segments: [seg])
        XCTAssertTrue(result.kept.actions.isEmpty)
        XCTAssertEqual(result.rejected.count, 2)
    }

    func test_scopeGuard_invalidSegmentIsOutOfScope() {
        // segB is attached but got removed from the timeline; any
        // action referencing it must be rejected.
        let segA = makeSegment(id: UUID(), start: 0, end: 5)
        let removedID = UUID()
        let attachment = makeAttachment(segmentID: removedID, composedStart: 0, composedEnd: 5)
        let scope = ChatAttachmentScope(attachments: [attachment])

        let batch = AIActionBatch(
            actions: [.deleteSegment(id: removedID)],
            explanation: ""
        )
        // `segments` no longer contains `removedID`.
        let result = ScopeGuard.filter(batch: batch, scope: scope, segments: [segA])
        XCTAssertTrue(result.kept.actions.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
    }
}
