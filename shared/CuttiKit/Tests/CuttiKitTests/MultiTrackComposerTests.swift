import XCTest
@testable import CuttiKit


final class MultiTrackComposerTests: XCTestCase {

    private func seg(duration: Double, offset: Double? = nil) -> TimelineSegment {
        var s = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: duration),
            text: "",
            subtitles: []
        )
        s.placementOffset = offset
        return s
    }

    func test_plan_primaryOnly_sequential() {
        let plan = MultiTrackComposer.plan(
            primarySegments: [seg(duration: 2), seg(duration: 3)],
            overlayTracks: []
        )
        XCTAssertEqual(plan.totalDuration, 5)
        XCTAssertEqual(plan.placements.count, 2)
        XCTAssertEqual(plan.placements[0].composedStart, 0)
        XCTAssertEqual(plan.placements[0].composedEnd, 2)
        XCTAssertEqual(plan.placements[1].composedStart, 2)
        XCTAssertEqual(plan.placements[1].composedEnd, 5)
        XCTAssertEqual(plan.intervals.count, 1)
        XCTAssertEqual(plan.intervals[0].lanes, [0])
    }

    func test_plan_anchoredBRoll_placesAtOffset() {
        let primary = [seg(duration: 10)]
        let broll = Track(kind: .overlay, name: "B", segments: [seg(duration: 2, offset: 3)])
        let plan = MultiTrackComposer.plan(primarySegments: primary, overlayTracks: [broll])
        XCTAssertEqual(plan.totalDuration, 10)
        XCTAssertEqual(plan.placements.count, 2)
        let bp = plan.placements.first(where: { $0.laneIndex == 1 })!
        XCTAssertEqual(bp.composedStart, 3)
        XCTAssertEqual(bp.composedEnd, 5)
    }

    func test_intervals_stackLayersCorrectly_duringOverlay() {
        let primary = [seg(duration: 10)]
        let broll = Track(kind: .overlay, name: "B", segments: [seg(duration: 2, offset: 3)])
        let plan = MultiTrackComposer.plan(primarySegments: primary, overlayTracks: [broll])
        // Expect 3 intervals: [0,3) primary only, [3,5) primary+overlay, [5,10) primary only
        XCTAssertEqual(plan.intervals.count, 3)
        XCTAssertEqual(plan.intervals[0], .init(start: 0, end: 3, lanes: [0]))
        XCTAssertEqual(plan.intervals[1], .init(start: 3, end: 5, lanes: [0, 1]))
        XCTAssertEqual(plan.intervals[2], .init(start: 5, end: 10, lanes: [0]))
    }

    func test_intervals_twoOverlappingOverlays() {
        let primary = [seg(duration: 10)]
        let t1 = Track(kind: .overlay, name: "1", segments: [seg(duration: 4, offset: 2)])
        let t2 = Track(kind: .overlay, name: "2", segments: [seg(duration: 3, offset: 4)])
        let plan = MultiTrackComposer.plan(primarySegments: primary, overlayTracks: [t1, t2])
        // Boundaries at 0,2,4,6,7,10 → active lanes:
        //   [0,2): [0]
        //   [2,4): [0,1]
        //   [4,6): [0,1,2]
        //   [6,7): [0,2]
        //   [7,10): [0]
        let lanes = plan.intervals.map(\.lanes)
        XCTAssertEqual(lanes, [[0], [0, 1], [0, 1, 2], [0, 2], [0]])
    }

    func test_intervals_sequentialOverlaySegments_flowAfterFirstAnchor() {
        let primary = [seg(duration: 10)]
        let overlay = Track(
            kind: .overlay,
            name: "O",
            segments: [seg(duration: 2, offset: 1), seg(duration: 1)]
        )
        let plan = MultiTrackComposer.plan(primarySegments: primary, overlayTracks: [overlay])
        let overlayPlacements = plan.placements.filter { $0.laneIndex == 1 }
        XCTAssertEqual(overlayPlacements.count, 2)
        XCTAssertEqual(overlayPlacements[0].composedStart, 1)
        XCTAssertEqual(overlayPlacements[0].composedEnd, 3)
        XCTAssertEqual(overlayPlacements[1].composedStart, 3)
        XCTAssertEqual(overlayPlacements[1].composedEnd, 4)
    }
}
