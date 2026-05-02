import XCTest
import CuttiKit
@testable import CuttiMac

@MainActor
final class InspectorSidebarTests: XCTestCase {
    private func makeRecord(
        status: MediaStatus = .ready,
        errorMessage: String? = nil,
        copilot: AICopilotSnapshot? = nil
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            sourcePath: "/tmp/InspectorClip.mp4",
            fingerprint: SourceFingerprint(fileSize: 10, modifiedAt: .distantPast, sha256Prefix: "abc"),
            status: status,
            analysis: AnalysisSummary(durationSeconds: 8, width: 1280, height: 720, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "media/proxies/InspectorClip.mp4", thumbnailsReady: false, waveformsReady: false),
            errorMessage: errorMessage,
            usedFallbackTranscoder: false,
            copilot: copilot
        )
    }

    func test_presentation_usesPlaceholderRowsWhenNothingIsSelected() {
        let presentation = InspectorSidebar.presentation(for: nil)

        XCTAssertEqual(presentation.clipName.value, "—")
        XCTAssertTrue(presentation.clipName.isDisabled)
        XCTAssertEqual(presentation.clipStatus.value, "No clip selected")
        XCTAssertTrue(presentation.clipStatus.isDisabled)
        XCTAssertEqual(presentation.resolution.value, "—")
        XCTAssertTrue(presentation.resolution.isDisabled)
        XCTAssertEqual(presentation.duration.value, "—")
        XCTAssertTrue(presentation.duration.isDisabled)
        XCTAssertEqual(presentation.audio.value, "—")
        XCTAssertTrue(presentation.audio.isDisabled)
        XCTAssertFalse(presentation.showsRelinkAction)
        XCTAssertNil(presentation.errorMessage)
    }

    func test_presentation_nilSelection_aiAnalysisTitleIsNoClipSelected() {
        let presentation = InspectorSidebar.presentation(for: nil)

        XCTAssertEqual(presentation.aiAnalysis.title, L("No clip selected"))
        XCTAssertFalse(presentation.aiAnalysis.showsProgress)
    }

    func test_presentation_preservesMissingMediaStatusAndRelinkAffordance() {
        let presentation = InspectorSidebar.presentation(
            for: makeRecord(status: .missing, errorMessage: "Original media is offline.")
        )

        XCTAssertEqual(presentation.clipName.value, "InspectorClip.mp4")
        XCTAssertFalse(presentation.clipName.isDisabled)
        XCTAssertEqual(presentation.clipStatus.value, "Missing")
        XCTAssertFalse(presentation.clipStatus.isDisabled)
        XCTAssertEqual(presentation.resolution.value, "1280 × 720")
        XCTAssertFalse(presentation.resolution.isDisabled)
        XCTAssertEqual(presentation.duration.value, "8s")
        XCTAssertFalse(presentation.duration.isDisabled)
        XCTAssertEqual(presentation.audio.value, "Audio detected")
        XCTAssertFalse(presentation.audio.isDisabled)
        XCTAssertTrue(presentation.showsRelinkAction)
        XCTAssertEqual(presentation.errorMessage, "Original media is offline.")
    }

    func test_presentation_missingRecord_aiAnalysisUnavailableAndRelinkPreserved() {
        let presentation = InspectorSidebar.presentation(
            for: makeRecord(status: .missing, errorMessage: "Original media is offline.")
        )

        XCTAssertEqual(presentation.aiAnalysis.title, L("AI analysis unavailable"))
        XCTAssertTrue(presentation.showsRelinkAction)
        XCTAssertEqual(presentation.errorMessage, "Original media is offline.")
    }

    func test_presentation_readyRecordWithSnapshot_exposesSummaryAndTranscriptAndTrimAndIssuesAndSuggestions() {
        let snapshot = AICopilotSnapshot(
            semanticTags: ["action", "outdoor"],
            summary: "High energy opening sequence.",
            transcriptPreview: "Welcome to the show…",
            suggestedInSeconds: 2.0,
            suggestedOutSeconds: 9.5,
            issues: [
                AICopilotIssue(severity: .warning, title: "Shaky footage", detail: "Stabilisation recommended.")
            ],
            suggestions: [
                AICopilotSuggestion(title: "Add music", detail: "Upbeat track works well here.")
            ],
            markers: []
        )
        let presentation = InspectorSidebar.presentation(for: makeRecord(status: .ready, copilot: snapshot))
        let ai = presentation.aiAnalysis

        XCTAssertEqual(ai.title, L("AI analysis ready"))
        XCTAssertEqual(ai.supportingText, "High energy opening sequence.")
        XCTAssertEqual(ai.transcriptPreview, "Welcome to the show…")
        XCTAssertNotNil(ai.suggestedTrimText)
        XCTAssertEqual(ai.issues.map(\.title), ["Shaky footage"])
        XCTAssertEqual(ai.suggestions.map(\.title), ["Add music"])
        XCTAssertFalse(ai.showsProgress)
    }
}

