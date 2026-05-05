import XCTest
import CuttiKit
@testable import CuttiMac

final class CopilotSnapshotBuilderTests: XCTestCase {
    func test_fromAnalysisAndEdit_tightensKeptRangeToWordBoundaries() throws {
        let local = LocalAnalysisResult(
            transcript: [
                TranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 5,
                    text: "我觉得这个答案很重要",
                    sourceVideoID: nil
                )
            ],
            rawWordTranscript: [
                TranscriptSegment(startSeconds: 1.00, endSeconds: 1.18, text: "我觉得", sourceVideoID: nil),
                TranscriptSegment(startSeconds: 1.34, endSeconds: 1.54, text: "这个", sourceVideoID: nil),
                TranscriptSegment(startSeconds: 1.56, endSeconds: 1.84, text: "答案", sourceVideoID: nil),
                TranscriptSegment(startSeconds: 1.92, endSeconds: 2.25, text: "很重要", sourceVideoID: nil),
            ],
            semanticTags: [],
            sceneBoundaries: [],
            hasTalkingHead: true,
            audioIssues: [],
            silentRanges: [0.0...0.95, 2.30...5.0],
            audioEnergyCurve: nil
        )

        let decision = LLMEditorService.EditDecision(
            keepIndices: [0],
            cuts: []
        )

        let snapshot = CopilotSnapshotBuilder.fromAnalysisAndEdit(
            local: local,
            editDecision: decision
        )

        let keptRange = try XCTUnwrap(snapshot.keptRanges?.first)
        XCTAssertEqual(keptRange.startSeconds, 0.96, accuracy: 0.001)
        XCTAssertEqual(keptRange.endSeconds, 2.33, accuracy: 0.001)
        XCTAssertLessThan(keptRange.endSeconds, 2.5)
    }

    func test_fromAnalysisAndEdit_splitsLongInternalSilenceIntoMultipleRanges() throws {
        let local = LocalAnalysisResult(
            transcript: [
                TranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 5,
                    text: "第一部分 第二部分",
                    sourceVideoID: nil
                )
            ],
            rawWordTranscript: [
                TranscriptSegment(startSeconds: 0.20, endSeconds: 0.36, text: "第一", sourceVideoID: nil),
                TranscriptSegment(startSeconds: 0.40, endSeconds: 0.60, text: "部分", sourceVideoID: nil),
                TranscriptSegment(startSeconds: 2.10, endSeconds: 2.30, text: "第二", sourceVideoID: nil),
                TranscriptSegment(startSeconds: 2.34, endSeconds: 2.56, text: "部分", sourceVideoID: nil),
            ],
            semanticTags: [],
            sceneBoundaries: [],
            hasTalkingHead: true,
            audioIssues: [],
            silentRanges: [0.0...0.10, 0.60...2.10, 2.60...5.0],
            audioEnergyCurve: nil
        )

        let decision = LLMEditorService.EditDecision(
            keepIndices: [0],
            cuts: []
        )

        let snapshot = CopilotSnapshotBuilder.fromAnalysisAndEdit(
            local: local,
            editDecision: decision
        )

        let keptRanges = try XCTUnwrap(snapshot.keptRanges)
        XCTAssertEqual(keptRanges.count, 2)
        XCTAssertLessThan(keptRanges[0].endSeconds, 1.0)
        XCTAssertGreaterThan(keptRanges[1].startSeconds, 2.0)
        XCTAssertEqual(snapshot.keptTexts, ["第一部分", "第二部分"])
    }
}
