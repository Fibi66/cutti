import XCTest
@testable import CuttiMac

final class VisualAnalysisServiceTests: XCTestCase {

    func test_aggregate_mergesAdjacentBlackSamples() {
        let period = 0.5
        let samples: [VisualFrameSample] = [
            .init(time: 0.0, meanLuminance: 0.01, faceCount: 1, changeScore: 0),
            .init(time: 0.5, meanLuminance: 0.02, faceCount: 1, changeScore: 0.01),
            .init(time: 1.0, meanLuminance: 0.4, faceCount: 1, changeScore: 0.38),
            .init(time: 1.5, meanLuminance: 0.01, faceCount: 1, changeScore: 0.39),
        ]
        let idx = VisualAnalysisService.aggregate(samples: samples, samplePeriod: period)
        XCTAssertEqual(idx.blackFrameRanges.count, 2)
        XCTAssertEqual(idx.blackFrameRanges[0].start, 0.0)
        XCTAssertEqual(idx.blackFrameRanges[0].end, 1.0, accuracy: 0.001)
        XCTAssertEqual(idx.blackFrameRanges[1].start, 1.5, accuracy: 0.001)
    }

    func test_aggregate_detectsSceneChanges() {
        let period = 0.5
        let samples: [VisualFrameSample] = [
            .init(time: 0.0, meanLuminance: 0.4, faceCount: 1, changeScore: 0),
            .init(time: 0.5, meanLuminance: 0.4, faceCount: 1, changeScore: 0.02),
            .init(time: 1.0, meanLuminance: 0.4, faceCount: 1, changeScore: 0.30),
            .init(time: 1.5, meanLuminance: 0.4, faceCount: 1, changeScore: 0.35),
        ]
        let idx = VisualAnalysisService.aggregate(samples: samples, samplePeriod: period)
        XCTAssertEqual(idx.sceneChangeTimestamps, [1.0, 1.5])
    }

    func test_aggregate_emptyFramesAreFacelessOnly() {
        let period = 0.5
        let samples: [VisualFrameSample] = [
            .init(time: 0.0, meanLuminance: 0.4, faceCount: 0, changeScore: 0),
            .init(time: 0.5, meanLuminance: 0.4, faceCount: 2, changeScore: 0),
        ]
        let idx = VisualAnalysisService.aggregate(samples: samples, samplePeriod: period)
        XCTAssertEqual(idx.emptyFrameRanges.count, 1)
        XCTAssertEqual(idx.emptyFrameRanges[0].start, 0.0, accuracy: 0.001)
        XCTAssertEqual(idx.emptyFrameRanges[0].end, 0.5, accuracy: 0.001)
    }

    func test_visualIndex_codableRoundTrip() throws {
        let idx = VisualIndex(
            samplePeriodSeconds: 0.5,
            blackFrameRanges: [.init(start: 0, end: 1)],
            emptyFrameRanges: [],
            sceneChangeTimestamps: [3.5]
        )
        let data = try JSONEncoder().encode(idx)
        let decoded = try JSONDecoder().decode(VisualIndex.self, from: data)
        XCTAssertEqual(idx, decoded)
    }
}
