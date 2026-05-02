import XCTest
import CuttiKit
@testable import CuttiMac

/// Covers the ProposedBatch factory — the dry-run → diff classification
/// logic used by the Plan→Preview→Apply gate. The VM integration test
/// that drives `applyProposal` / `rejectProposal` lives in
/// MediaCoreViewModelTests (covered indirectly by AIAction executor
/// tests; the branching logic itself is just state flipping).
final class ProposedBatchTests: XCTestCase {
    private func makeSegment(speed: Double = 1.0, volume: Double = 1.0) -> TimelineSegment {
        TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 5),
            text: "hello",
            subtitles: [],
            volumeLevel: volume,
            speedRate: speed
        )
    }

    func test_make_flagsDeletedSegments() {
        let a = makeSegment()
        let b = makeSegment()
        let before = [a, b]
        let dry = AIActionExecutor.Result(
            segments: [b], // a deleted
            appliedCount: 1,
            skippedCount: 0,
            subtitleStyle: nil,
            showSubtitles: nil
        )
        let batch = AIActionBatch(
            actions: [.deleteSegment(id: a.id)],
            explanation: "Drop first"
        )

        let p = ProposedBatch.make(
            toolCallID: "tc1",
            batch: batch,
            before: before,
            dryRun: dry
        )

        XCTAssertEqual(p.decision, .pending)
        XCTAssertEqual(p.deletedSegmentIDs, [a.id])
        XCTAssertEqual(p.speedChangedSegmentIDs, [])
        XCTAssertEqual(p.volumeChangedSegmentIDs, [])
        XCTAssertEqual(p.previewAppliedCount, 1)
        XCTAssertFalse(p.touchesSubtitleStyle)
    }

    func test_make_flagsSpeedAndVolumeChanges() {
        let a = makeSegment(speed: 1.0, volume: 1.0)
        var aChanged = a
        aChanged.speedRate = 2.0
        aChanged.volumeLevel = 0.5

        let dry = AIActionExecutor.Result(
            segments: [aChanged],
            appliedCount: 2,
            skippedCount: 0,
            subtitleStyle: nil,
            showSubtitles: nil
        )
        let batch = AIActionBatch(
            actions: [.setSpeed(id: a.id, rate: 2.0), .setVolume(id: a.id, level: 0.5)],
            explanation: "Speed up & duck"
        )

        let p = ProposedBatch.make(
            toolCallID: "tc2",
            batch: batch,
            before: [a],
            dryRun: dry
        )

        XCTAssertTrue(p.deletedSegmentIDs.isEmpty)
        XCTAssertEqual(p.speedChangedSegmentIDs, [a.id])
        XCTAssertEqual(p.volumeChangedSegmentIDs, [a.id])
    }

    func test_make_flagsSubtitleStyleTouch() {
        let a = makeSegment()
        let dry = AIActionExecutor.Result(
            segments: [a],
            appliedCount: 1,
            skippedCount: 0,
            subtitleStyle: .default,
            showSubtitles: true
        )
        let batch = AIActionBatch(actions: [], explanation: "Style")
        let p = ProposedBatch.make(
            toolCallID: "tc3",
            batch: batch,
            before: [a],
            dryRun: dry
        )
        XCTAssertTrue(p.touchesSubtitleStyle)
    }

    func test_title_usesExplanationWhenAvailable() {
        let a = makeSegment()
        let dry = AIActionExecutor.Result(
            segments: [],
            appliedCount: 1,
            skippedCount: 0,
            subtitleStyle: nil,
            showSubtitles: nil
        )
        let batch = AIActionBatch(
            actions: [.deleteSegment(id: a.id)],
            explanation: "Remove intro"
        )
        let p = ProposedBatch.make(
            toolCallID: "tc4",
            batch: batch,
            before: [a],
            dryRun: dry
        )
        XCTAssertEqual(p.title, "Remove intro")
    }
}
