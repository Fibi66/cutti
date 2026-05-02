import XCTest
import CuttiKit
@testable import CuttiMac

final class MediaRecordPresentationTests: XCTestCase {
    private func makeRecord(
        status: MediaStatus = .ready,
        duration: Double = 12,
        width: Int = 1920,
        height: Int = 1080,
        hasAnalysis: Bool = true,
        sourcePath: String = "/tmp/LaunchClip.mp4",
        copilot: AICopilotSnapshot? = nil
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            sourcePath: sourcePath,
            fingerprint: SourceFingerprint(fileSize: 10, modifiedAt: .distantPast, sha256Prefix: "abc"),
            status: status,
            analysis: hasAnalysis ? AnalysisSummary(
                durationSeconds: duration,
                width: width,
                height: height,
                nominalFPS: 30,
                hasAudio: true
            ) : nil,
            derived: DerivedAssetState(proxyRelativePath: "media/proxies/LaunchClip.mp4", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            copilot: copilot
        )
    }

    func test_metadataLine_includesDurationAndResolution() {
        XCTAssertEqual(MediaRecordPresentation.metadataLine(for: makeRecord()), "12s • 1920×1080")
    }

    func test_metadataLine_prefersTechnicalMetadataWhenAnalysisExistsForNonReadyRecord() {
        XCTAssertEqual(
            MediaRecordPresentation.metadataLine(for: makeRecord(status: .analyzing)),
            "12s • 1920×1080"
        )
    }

    func test_metadataLine_returnsEmptyWithoutAnalysis() {
        XCTAssertEqual(
            MediaRecordPresentation.metadataLine(for: makeRecord(status: .transcoding, hasAnalysis: false)),
            ""
        )
    }

    func test_inspectorDuration_returnsDurationOnlyWhenAnalysisExists() {
        XCTAssertEqual(MediaRecordPresentation.inspectorDuration(for: makeRecord()), "12s")
    }

    func test_inspectorDuration_fallsBackToStatusTextWithoutAnalysis() {
        XCTAssertEqual(
            MediaRecordPresentation.inspectorDuration(for: makeRecord(status: .transcoding, hasAnalysis: false)),
            "Transcoding"
        )
    }

    func test_timelineWidth_clampsShortClipsToMinimum() {
        XCTAssertEqual(MediaRecordPresentation.timelineWidth(for: makeRecord(duration: 1)), 160)
    }

    func test_filter_matchesFilename_caseInsensitively() {
        let match = makeRecord(sourcePath: "/tmp/LaunchClip.mp4")
        let miss = makeRecord(sourcePath: "/tmp/Broll.mp4")
        let filtered = MediaBrowserQuery.filter(records: [match, miss], query: "launch")
        XCTAssertEqual(filtered.map(\.sourcePath), ["/tmp/LaunchClip.mp4"])
    }

    func test_filter_matchesStatusText_caseInsensitively() {
        let match = makeRecord(status: .ready, sourcePath: "/tmp/LaunchClip.mp4")
        let miss = makeRecord(status: .failed, sourcePath: "/tmp/Broll.mp4")

        let filtered = MediaBrowserQuery.filter(records: [match, miss], query: "READY")

        XCTAssertEqual(filtered.map(\.sourcePath), ["/tmp/LaunchClip.mp4"])
    }

    func test_filter_matchesCopilotSemanticTags_caseInsensitively() {
        let copilot = AICopilotSnapshot(
            semanticTags: ["Interview", "Outdoor", "Golden Hour"],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: []
        )
        let match = makeRecord(sourcePath: "/tmp/Interview.mp4", copilot: copilot)
        let miss = makeRecord(sourcePath: "/tmp/Broll.mp4")

        let filtered = MediaBrowserQuery.filter(records: [match, miss], query: "golden")

        XCTAssertEqual(filtered.map(\.sourcePath), ["/tmp/Interview.mp4"])
    }
}
