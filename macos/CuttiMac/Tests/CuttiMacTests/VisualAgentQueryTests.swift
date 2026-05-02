import XCTest
import CuttiKit
@testable import CuttiMac

final class VisualAgentQueryTests: XCTestCase {

    private func makeSegment(sourceID: UUID, from: Double, to: Double, speed: Double = 1.0) -> TimelineSegment {
        TimelineSegment(
            id: UUID(),
            sourceVideoID: sourceID,
            range: TimeRange(startSeconds: from, endSeconds: to),
            text: "",
            subtitles: [],
            volumeLevel: 1.0,
            speedRate: speed
        )
    }

    private func makeIndex(black: [(Double, Double)] = [], empty: [(Double, Double)] = [], scenes: [Double] = []) -> VisualIndex {
        VisualIndex(
            samplePeriodSeconds: 0.5,
            blackFrameRanges: black.map { .init(start: $0.0, end: $0.1) },
            emptyFrameRanges: empty.map { .init(start: $0.0, end: $0.1) },
            sceneChangeTimestamps: scenes
        )
    }

    func test_findBlackFrames_mapsSingleSegmentAtZero() {
        let sourceID = UUID()
        let segments = [makeSegment(sourceID: sourceID, from: 0, to: 10)]
        let indices = [sourceID: makeIndex(black: [(2, 4)])]

        let matches = VisualAgentQuery.findBlackFrames(segments: segments, indices: indices)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].kind, "black")
        XCTAssertEqual(matches[0].segmentIndex, 0)
        XCTAssertEqual(matches[0].composedStart, 2, accuracy: 0.001)
        XCTAssertEqual(matches[0].composedEnd, 4, accuracy: 0.001)
    }

    func test_findBlackFrames_offsetsByPriorSegmentDurations() {
        let sourceID = UUID()
        let segments = [
            makeSegment(sourceID: sourceID, from: 0, to: 5),   // composed 0..5
            makeSegment(sourceID: sourceID, from: 10, to: 15), // composed 5..10
        ]
        let indices = [sourceID: makeIndex(black: [(11, 12)])]

        let matches = VisualAgentQuery.findBlackFrames(segments: segments, indices: indices)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].segmentIndex, 1)
        XCTAssertEqual(matches[0].composedStart, 6, accuracy: 0.001) // 5 + (11-10)
        XCTAssertEqual(matches[0].composedEnd, 7, accuracy: 0.001)
    }

    func test_findBlackFrames_clipsRangesOutsideSegmentWindow() {
        let sourceID = UUID()
        // Segment only covers source 5..10 — black range 3..6 overlaps only 5..6.
        let segments = [makeSegment(sourceID: sourceID, from: 5, to: 10)]
        let indices = [sourceID: makeIndex(black: [(3, 6)])]

        let matches = VisualAgentQuery.findBlackFrames(segments: segments, indices: indices)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].composedStart, 0, accuracy: 0.001)
        XCTAssertEqual(matches[0].composedEnd, 1, accuracy: 0.001)
    }

    func test_findBlackFrames_honoursSpeedRate() {
        let sourceID = UUID()
        // 2x speed: 4s of source → 2s of composed.
        let segments = [makeSegment(sourceID: sourceID, from: 0, to: 4, speed: 2.0)]
        let indices = [sourceID: makeIndex(black: [(1, 3)])] // 2s of source

        let matches = VisualAgentQuery.findBlackFrames(segments: segments, indices: indices)
        XCTAssertEqual(matches.count, 1)
        // Source 1..3 → composed 0.5..1.5 at 2x speed.
        XCTAssertEqual(matches[0].composedStart, 0.5, accuracy: 0.001)
        XCTAssertEqual(matches[0].composedEnd, 1.5, accuracy: 0.001)
    }

    func test_findBlackFrames_skipsSegmentsWithNoIndex() {
        let knownID = UUID()
        let unknownID = UUID()
        let segments = [
            makeSegment(sourceID: unknownID, from: 0, to: 5),
            makeSegment(sourceID: knownID, from: 0, to: 5),
        ]
        let indices = [knownID: makeIndex(black: [(1, 2)])]

        let matches = VisualAgentQuery.findBlackFrames(segments: segments, indices: indices)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].segmentIndex, 1)
        XCTAssertEqual(matches[0].composedStart, 6, accuracy: 0.001) // 5 + 1
    }

    func test_findEmptyFrames_usesEmptyFrameRanges() {
        let sourceID = UUID()
        let segments = [makeSegment(sourceID: sourceID, from: 0, to: 10)]
        let indices = [sourceID: makeIndex(empty: [(3, 4)])]

        let matches = VisualAgentQuery.findEmptyFrames(segments: segments, indices: indices)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].kind, "no_face")
    }

    func test_findSceneChanges_emitsWindowsAroundTimestamps() {
        let sourceID = UUID()
        let segments = [makeSegment(sourceID: sourceID, from: 0, to: 10)]
        let indices = [sourceID: makeIndex(scenes: [5.0])]

        let matches = VisualAgentQuery.findSceneChanges(segments: segments, indices: indices)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].kind, "scene_change")
        // 0.25s window centered at 5.0 → 4.875..5.125
        XCTAssertEqual(matches[0].composedStart, 4.875, accuracy: 0.001)
        XCTAssertEqual(matches[0].composedEnd, 5.125, accuracy: 0.001)
    }

    func test_findBlackFrames_returnsEmptyWhenNoRanges() {
        let sourceID = UUID()
        let segments = [makeSegment(sourceID: sourceID, from: 0, to: 10)]
        let indices = [sourceID: makeIndex()]

        XCTAssertTrue(VisualAgentQuery.findBlackFrames(segments: segments, indices: indices).isEmpty)
        XCTAssertTrue(VisualAgentQuery.findEmptyFrames(segments: segments, indices: indices).isEmpty)
        XCTAssertTrue(VisualAgentQuery.findSceneChanges(segments: segments, indices: indices).isEmpty)
    }
}

final class VisualIndexStoreTests: XCTestCase {

    func test_saveLoad_roundtripsIndex() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("VisualIndexStoreTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoID = UUID()
        let index = VisualIndex(
            samplePeriodSeconds: 0.5,
            blackFrameRanges: [.init(start: 1, end: 2)],
            emptyFrameRanges: [.init(start: 3, end: 4)],
            sceneChangeTimestamps: [5.0]
        )

        try VisualIndexStore.save(index, projectRoot: tmp, videoID: videoID)
        let loaded = VisualIndexStore.load(projectRoot: tmp, videoID: videoID)
        XCTAssertEqual(loaded, index)
    }

    func test_load_returnsNilForMissingFile() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Missing-\(UUID().uuidString)")
        XCTAssertNil(VisualIndexStore.load(projectRoot: tmp, videoID: UUID()))
    }
}
