import XCTest
import CuttiKit
@testable import CuttiMac

final class TimelineScaleTests: XCTestCase {

    // MARK: - Helpers

    private func makeRecord(durationSeconds: Double?) -> MediaAssetRecord {
        MediaAssetRecord(
            id: UUID(),
            sourcePath: "/tmp/scale_test.mp4",
            fingerprint: SourceFingerprint(fileSize: 1, modifiedAt: .distantPast, sha256Prefix: "aa"),
            status: .ready,
            analysis: durationSeconds.map {
                AnalysisSummary(
                    durationSeconds: $0,
                    width: 1920, height: 1080,
                    nominalFPS: 30, hasAudio: true
                )
            },
            derived: DerivedAssetState(
                proxyRelativePath: nil,
                thumbnailsReady: false,
                waveformsReady: false
            ),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
    }

    // MARK: - clipWidth

    func test_clipWidth_matchesMediaRecordPresentation() {
        // Both must produce the same value so the timeline and the dock clip cards stay aligned.
        let durations: [Double] = [1, 8, 12, 25, 100]
        for duration in durations {
            let record = makeRecord(durationSeconds: duration)
            XCTAssertEqual(
                TimelineScale.clipWidth(for: record),
                MediaRecordPresentation.timelineWidth(for: record),
                accuracy: 0.001,
                "clipWidth mismatch for duration \(duration)"
            )
        }
    }

    func test_clipWidth_clampsShortClipToMinimum() {
        let record = makeRecord(durationSeconds: 1)
        XCTAssertEqual(TimelineScale.clipWidth(for: record), TimelineScale.minimumClipWidth)
    }

    func test_clipWidth_clampsLongClipToMaximum() {
        let record = makeRecord(durationSeconds: 999)
        XCTAssertEqual(TimelineScale.clipWidth(for: record), TimelineScale.maximumClipWidth)
    }

    func test_clipWidth_usesFallbackWhenAnalysisAbsent() {
        let record = makeRecord(durationSeconds: nil)
        let expected = max(
            TimelineScale.minimumClipWidth,
            min(
                TimelineScale.fallbackDurationSeconds * TimelineScale.pointsPerSecond,
                TimelineScale.maximumClipWidth
            )
        )
        XCTAssertEqual(TimelineScale.clipWidth(for: record), expected, accuracy: 0.001)
    }

    // MARK: - markerOffset

    func test_markerOffset_clampsWithinClipBounds() {
        // durationSeconds = 10 → natural width = 10 × 28 = 280 pts (not clamped)
        let clipWidth = 280.0
        let durationSeconds = 10.0

        // Within range: 5 s at progress 0.5 → 0.5 × 280 = 140 pts
        XCTAssertEqual(
            TimelineScale.markerOffset(seconds: 5, clipWidth: clipWidth, durationSeconds: durationSeconds),
            140,
            accuracy: 0.001
        )

        // Below zero — clamp to 0
        XCTAssertEqual(
            TimelineScale.markerOffset(seconds: -1, clipWidth: clipWidth, durationSeconds: durationSeconds),
            0
        )

        // Beyond clip width — clamp to clipWidth
        XCTAssertEqual(
            TimelineScale.markerOffset(seconds: 999, clipWidth: clipWidth, durationSeconds: durationSeconds),
            clipWidth
        )
    }

    func test_markerOffset_zeroSeconds_producesZeroOffset() {
        XCTAssertEqual(
            TimelineScale.markerOffset(seconds: 0, clipWidth: 300, durationSeconds: 10),
            0
        )
    }

    /// Short clip: duration clamped to minimumClipWidth — marker must still land at the right
    /// normalized position, not at `seconds × pointsPerSecond`.
    func test_markerOffset_shortClip_normalizedHalfway() {
        // duration = 1 s → natural width = 28 pts, but clipWidth is clamped to 140 pts
        // seconds = 0.5 → progress = 0.5 → offset = 0.5 × 140 = 70 pts
        let durationSeconds = 1.0
        let contentWidth = 140.0
        XCTAssertEqual(
            TimelineScale.markerOffset(seconds: 0.5, clipWidth: contentWidth, durationSeconds: durationSeconds),
            70,
            accuracy: 0.001,
            "Short clip marker must be at normalized 50%, not seconds × pointsPerSecond"
        )
    }

    /// Long clip: duration clamped to maximumClipWidth — marker must still land at the right
    /// normalized position, not at `seconds × pointsPerSecond`.
    func test_markerOffset_longClip_normalizedHalfway() {
        // duration = 60 s → natural width = 1680 pts, but clipWidth is clamped to 700 pts
        // seconds = 30 → progress = 0.5 → offset = 0.5 × 700 = 350 pts
        let durationSeconds = 60.0
        let contentWidth = 700.0
        XCTAssertEqual(
            TimelineScale.markerOffset(seconds: 30, clipWidth: contentWidth, durationSeconds: durationSeconds),
            350,
            accuracy: 0.001,
            "Long clip marker must be at normalized 50%, not seconds × pointsPerSecond"
        )
    }

    // MARK: - playheadOffset

    func test_playheadOffset_usesSameScaleAsMarkers() {
        // durationSeconds = 12 → natural width = 12 × 28 = 336 pts (not clamped)
        let clipWidth = 336.0
        let durationSeconds = 12.0
        let seconds = 7.0

        let markerOff = TimelineScale.markerOffset(seconds: seconds, clipWidth: clipWidth, durationSeconds: durationSeconds)
        let playheadOff = TimelineScale.playheadOffset(seconds: seconds, clipWidth: clipWidth, durationSeconds: durationSeconds)

        XCTAssertEqual(markerOff, playheadOff, accuracy: 0.001,
            "playheadOffset must use the same scale as markerOffset")
    }

    func test_playheadOffset_clampsAtClipBoundaries() {
        let clipWidth = 200.0
        let durationSeconds = 10.0

        XCTAssertEqual(
            TimelineScale.playheadOffset(seconds: -5, clipWidth: clipWidth, durationSeconds: durationSeconds),
            0
        )
        XCTAssertEqual(
            TimelineScale.playheadOffset(seconds: 999, clipWidth: clipWidth, durationSeconds: durationSeconds),
            clipWidth
        )
    }
}
