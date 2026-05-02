import XCTest
import CuttiKit
@testable import CuttiMac

final class AudioPostProcessorTests: XCTestCase {

    // MARK: - Loudness

    func test_normalization_attenuatesLoudSourceTowardTarget() {
        let id = UUID()
        let gains = AudioPostProcessor.computeNormalizationGains(
            sourceAverageDB: [id: -10],
            targetDB: -16
        )
        // -16 - (-10) = -6 dB → linear gain ~0.501
        XCTAssertEqual(gains[id]!, pow(10.0, -6.0 / 20.0), accuracy: 0.0001)
        XCTAssertLessThan(gains[id]!, 1.0)
    }

    func test_normalization_skipsQuietSourcesNoBoost() {
        // A quiet source at -24 dB shouldn't be boosted toward -16 because
        // AVMutableAudioMix can't go above unity gain.
        let id = UUID()
        let gains = AudioPostProcessor.computeNormalizationGains(
            sourceAverageDB: [id: -24],
            targetDB: -16
        )
        XCTAssertNil(gains[id])
    }

    func test_normalization_skipsSilentOrInvalid() {
        let a = UUID(), b = UUID()
        let gains = AudioPostProcessor.computeNormalizationGains(
            sourceAverageDB: [a: -.infinity, b: -130],
            targetDB: -16
        )
        XCTAssertTrue(gains.isEmpty)
    }

    // MARK: - Silence compression

    private func segment(source: UUID, sourceStart: Double, sourceEnd: Double, speed: Double = 1.0) -> TimelineSegment {
        TimelineSegment(
            id: UUID(),
            sourceVideoID: source,
            range: TimeRange(startSeconds: sourceStart, endSeconds: sourceEnd),
            text: "",
            subtitles: [],
            volumeLevel: 1.0,
            speedRate: speed
        )
    }

    func test_silenceCompression_emitsRegionsForLongSilencesOnly() {
        let src = UUID()
        let seg = segment(source: src, sourceStart: 0, sourceEnd: 60)
        let regions = AudioPostProcessor.computeSilenceSpeedUps(
            segments: [seg],
            silentRangesBySource: [src: [10...10.5, 20...22]],
            minDuration: 1.0,
            rate: 4.0
        )
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].startSeconds, 20, accuracy: 0.0001)
        XCTAssertEqual(regions[0].endSeconds, 22, accuracy: 0.0001)
        XCTAssertEqual(regions[0].rate, 4.0)
    }

    func test_silenceCompression_clipsSilenceToSegmentBounds() {
        let src = UUID()
        // Segment covers source-time 5…15. A silence from 12…20 should be
        // clipped to 12…15 (3s remaining, > 1s minimum).
        let seg = segment(source: src, sourceStart: 5, sourceEnd: 15)
        let regions = AudioPostProcessor.computeSilenceSpeedUps(
            segments: [seg],
            silentRangesBySource: [src: [12...20]],
            minDuration: 1.0,
            rate: 4.0
        )
        XCTAssertEqual(regions.count, 1)
        // Composed offset for this segment is 0; (12-5)/1 = 7, (15-5)/1 = 10.
        XCTAssertEqual(regions[0].startSeconds, 7, accuracy: 0.0001)
        XCTAssertEqual(regions[0].endSeconds, 10, accuracy: 0.0001)
    }

    func test_silenceCompression_projectsThroughSpeedAndComposedOffset() {
        let src = UUID()
        // Two segments stacked. First plays at 2x (10s source → 5s
        // composed). Second is a fresh 30s slice at 1x. A silence in the
        // second source from 5…8 should project to composed-time
        // 5 + (5-0)/1 … 5 + (8-0)/1 = 10…13.
        let s1 = segment(source: src, sourceStart: 0, sourceEnd: 10, speed: 2.0)
        let s2 = segment(source: src, sourceStart: 0, sourceEnd: 30, speed: 1.0)
        let regions = AudioPostProcessor.computeSilenceSpeedUps(
            segments: [s1, s2],
            silentRangesBySource: [src: [5...8]],
            minDuration: 1.0,
            rate: 4.0
        )
        // The same source-time range hits both segments — once inside s1
        // (clipped 5…8 → composed 2.5…4.0 after 2x speed) and once inside
        // s2 (composed 10…13).
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].startSeconds, 2.5, accuracy: 0.0001)
        XCTAssertEqual(regions[0].endSeconds, 4.0, accuracy: 0.0001)
        XCTAssertEqual(regions[1].startSeconds, 10.0, accuracy: 0.0001)
        XCTAssertEqual(regions[1].endSeconds, 13.0, accuracy: 0.0001)
    }

    func test_silenceCompression_rejectsBadInputs() {
        let src = UUID()
        let seg = segment(source: src, sourceStart: 0, sourceEnd: 60)
        XCTAssertEqual(
            AudioPostProcessor.computeSilenceSpeedUps(
                segments: [seg],
                silentRangesBySource: [src: [0...10]],
                minDuration: 0,
                rate: 4.0
            ),
            []
        )
        XCTAssertEqual(
            AudioPostProcessor.computeSilenceSpeedUps(
                segments: [seg],
                silentRangesBySource: [src: [0...10]],
                minDuration: 1.0,
                rate: 1.0
            ),
            []
        )
    }
}
