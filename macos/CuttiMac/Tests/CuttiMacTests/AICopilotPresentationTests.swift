import XCTest
import CuttiKit
@testable import CuttiMac

final class AICopilotPresentationTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeSnapshot() -> AICopilotSnapshot {
        AICopilotSnapshot(
            semanticTags: ["Hook", "Dialogue"],
            summary: "Opening beat lands quickly and the speaker is centered.",
            transcriptPreview: "Welcome back to Cutti.",
            suggestedInSeconds: 0.5,
            suggestedOutSeconds: 8.0,
            issues: [
                AICopilotIssue(severity: .warning, title: "Quiet first second", detail: nil)
            ],
            suggestions: [
                AICopilotSuggestion(title: "Trim cold open", detail: nil)
            ],
            markers: [
                AICopilotMarker(kind: .scene, seconds: 0.0, label: "Hook starts")
            ]
        )
    }

    private func makeRecord(
        status: MediaStatus = .ready,
        snapshot: AICopilotSnapshot? = nil,
        sourcePath: String = "/tmp/clip.mp4"
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: UUID(),
            sourcePath: sourcePath,
            fingerprint: SourceFingerprint(fileSize: 100, modifiedAt: .distantPast, sha256Prefix: "abc"),
            status: status,
            analysis: AnalysisSummary(durationSeconds: 10, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: nil, thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            copilot: snapshot
        )
    }

    // MARK: - projectTitle(for:)

    func test_projectTitle_returnsLastPathComponent() {
        let url = URL(fileURLWithPath: "/tmp/Projects/MyFilm")
        XCTAssertEqual(AICopilotPresentation.projectTitle(for: url), "MyFilm")
    }

    func test_projectTitle_returnsUntitledProjectForNil() {
        XCTAssertEqual(AICopilotPresentation.projectTitle(for: nil), L("Untitled Project"))
    }

    // MARK: - agentStatus(records:selectedRecord:)

    func test_agentStatus_idleWhenAllReady() {
        let records = [makeRecord(status: .ready), makeRecord(status: .ready)]
        let status = AICopilotPresentation.agentStatus(records: records, selectedRecord: nil)
        XCTAssertEqual(status.title, L("AI copilot is idle"))
        XCTAssertEqual(status.detail, L("Import media or run analysis to unlock tags and suggestions."))
        XCTAssertEqual(status.tone, .idle)
    }

    func test_agentStatus_preparingClipsWhenAnyActive() {
        let records = [makeRecord(status: .ready), makeRecord(status: .analyzing)]
        let status = AICopilotPresentation.agentStatus(records: records, selectedRecord: nil)
        XCTAssertEqual(status.title, L("AI is preparing clips"))
        XCTAssertTrue(status.detail.contains(L("clip is")) || status.detail.contains(L("clips are")), "detail should mention clip count: \(status.detail)")
        XCTAssertEqual(status.tone, .working)
    }

    func test_agentStatus_preparingClipsForQueued() {
        let records = [makeRecord(status: .queued)]
        let status = AICopilotPresentation.agentStatus(records: records, selectedRecord: nil)
        XCTAssertEqual(status.title, L("AI is preparing clips"))
        XCTAssertEqual(status.detail, L("%d %@ still processing.", 1, L("clip is")))
        XCTAssertEqual(status.tone, .working)
    }

    func test_agentStatus_preparingClipsForTranscoding() {
        let records = [makeRecord(status: .transcoding), makeRecord(status: .transcoding)]
        let status = AICopilotPresentation.agentStatus(records: records, selectedRecord: nil)
        XCTAssertEqual(status.title, L("AI is preparing clips"))
        XCTAssertEqual(status.detail, L("%d %@ still processing.", 2, L("clips are")))
        XCTAssertEqual(status.tone, .working)
    }

    func test_agentStatus_readyWhenSelectedRecordHasSuggestions() {
        let snapshot = makeSnapshot() // has 1 suggestion and 1 marker
        let selected = makeRecord(status: .ready, snapshot: snapshot)
        let status = AICopilotPresentation.agentStatus(records: [selected], selectedRecord: selected)
        XCTAssertEqual(status.title, L("AI suggestions are ready"))
        XCTAssertTrue(status.detail.contains(L("suggestion")) || status.detail.contains(L("suggestions")), "detail should mention suggestions: \(status.detail)")
        XCTAssertTrue(status.detail.contains(L("marker")) || status.detail.contains(L("markers")), "detail should mention markers: \(status.detail)")
        XCTAssertEqual(status.tone, .ready)
    }

    func test_agentStatus_readyWhenSelectedRecordHasMarkersOnly() {
        let snapshot = AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: [AICopilotMarker(kind: .scene, seconds: 1.0, label: "Scene A")]
        )
        let selected = makeRecord(status: .ready, snapshot: snapshot)
        let status = AICopilotPresentation.agentStatus(records: [selected], selectedRecord: selected)
        XCTAssertEqual(status.tone, .ready)
        XCTAssertEqual(status.title, L("AI suggestions are ready"))
        // Task 1 contract: detail always mentions both counts, even when one side is zero.
        XCTAssertTrue(status.detail.contains(L("suggestion")) || status.detail.contains(L("suggestions")), "detail should mention suggestion count: \(status.detail)")
        XCTAssertTrue(status.detail.contains(L("marker")) || status.detail.contains(L("markers")), "detail should mention marker count: \(status.detail)")
    }

    func test_agentStatus_readyWhenSelectedRecordHasSuggestionsOnly() {
        let snapshot = AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [AICopilotSuggestion(title: "Tighten pacing", detail: nil)],
            markers: []
        )
        let selected = makeRecord(status: .ready, snapshot: snapshot)
        let status = AICopilotPresentation.agentStatus(records: [selected], selectedRecord: selected)
        XCTAssertEqual(status.tone, .ready)
        XCTAssertEqual(status.title, L("AI suggestions are ready"))
        // Task 1 contract: detail always mentions both counts, even when one side is zero.
        XCTAssertTrue(status.detail.contains(L("suggestion")) || status.detail.contains(L("suggestions")), "detail should mention suggestion count: \(status.detail)")
        XCTAssertTrue(status.detail.contains(L("marker")) || status.detail.contains(L("markers")), "detail should mention marker count: \(status.detail)")
    }

    func test_agentStatus_idleWhenSelectedRecordHasNoSuggestionsOrMarkers() {
        let emptySnapshot = AICopilotSnapshot(
            semanticTags: ["Hook"],
            summary: "Brief summary",
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: []
        )
        let selected = makeRecord(status: .ready, snapshot: emptySnapshot)
        let status = AICopilotPresentation.agentStatus(records: [selected], selectedRecord: selected)
        XCTAssertEqual(status.title, L("AI copilot is idle"))
        XCTAssertEqual(status.tone, .idle)
    }

    func test_agentStatus_notReadyWhenSelectedRecordIsFailedWithSnapshot() {
        let snapshot = makeSnapshot()
        let selected = makeRecord(status: .failed, snapshot: snapshot)
        let status = AICopilotPresentation.agentStatus(records: [selected], selectedRecord: selected)
        XCTAssertNotEqual(status.tone, .ready, "Failed record must not produce .ready tone even when snapshot exists")
    }

    func test_agentStatus_notReadyWhenSelectedRecordIsMissingWithSnapshot() {
        let snapshot = makeSnapshot()
        let selected = makeRecord(status: .missing, snapshot: snapshot)
        let status = AICopilotPresentation.agentStatus(records: [selected], selectedRecord: selected)
        XCTAssertNotEqual(status.tone, .ready, "Missing record must not produce .ready tone even when snapshot exists")
    }

    func test_agentStatus_workingTakesPriorityOverReady() {
        // Selected record is .ready with a full snapshot — would normally yield .ready.
        // A second record is .analyzing — must bump the overall tone to .working instead.
        let snapshot = makeSnapshot()
        let selected = makeRecord(status: .ready, snapshot: snapshot)
        let analyzing = makeRecord(status: .analyzing)
        let status = AICopilotPresentation.agentStatus(records: [selected, analyzing], selectedRecord: selected)
        XCTAssertEqual(status.tone, .working,
                       ".working should take priority over .ready when any record is still processing")
    }

    // MARK: - browserTags(for:)

    func test_browserTags_returnsSemanticTagsUpToThree() {
        let record = makeRecord(snapshot: makeSnapshot())
        let tags = AICopilotPresentation.browserTags(for: record)
        XCTAssertEqual(tags, ["Hook", "Dialogue"])
        XCTAssertLessThanOrEqual(tags.count, 3)
    }

    func test_browserTags_emptyWhenNoSnapshot() {
        let record = makeRecord(snapshot: nil)
        XCTAssertTrue(AICopilotPresentation.browserTags(for: record).isEmpty)
    }

    func test_browserTags_capsAtThreeTags() {
        let snapshot = AICopilotSnapshot(
            semanticTags: ["A", "B", "C", "D"],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: []
        )
        let record = makeRecord(snapshot: snapshot)
        XCTAssertEqual(AICopilotPresentation.browserTags(for: record).count, 3)
    }

    // MARK: - inspectorAnalysis(for:)

    func test_inspectorAnalysis_noClipSelectedForNilRecord() {
        let analysis = AICopilotPresentation.inspectorAnalysis(for: nil)
        XCTAssertEqual(analysis.title, L("No clip selected"))
        XCTAssertEqual(analysis.supportingText, L("Select a clip to review AI summary, transcript, and edit suggestions."))
        XCTAssertFalse(analysis.showsProgress)
    }

    func test_inspectorAnalysis_unavailableForFailedRecord() {
        let record = makeRecord(status: .failed)
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.title, L("AI analysis unavailable"))
        XCTAssertFalse(analysis.showsProgress)
    }

    func test_inspectorAnalysis_unavailableForMissingMedia() {
        let record = makeRecord(status: .missing)
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.title, L("AI analysis unavailable"))
        XCTAssertEqual(analysis.supportingText, L("Relink the original media to resume AI suggestions and markers."))
        XCTAssertFalse(analysis.showsProgress)
    }

    func test_inspectorAnalysis_inProgressForQueuedClip() {
        let record = makeRecord(status: .queued)
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.title, L("AI analysis in progress"))
        XCTAssertTrue(analysis.showsProgress)
    }

    func test_inspectorAnalysis_inProgressForAnalyzingClip() {
        let record = makeRecord(status: .analyzing)
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.title, L("AI analysis in progress"))
        XCTAssertTrue(analysis.showsProgress)
    }

    func test_inspectorAnalysis_inProgressForTranscodingClip() {
        let record = makeRecord(status: .transcoding)
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.title, L("AI analysis in progress"))
        XCTAssertTrue(analysis.showsProgress)
    }

    func test_inspectorAnalysis_noAnalysisYetForReadyWithNoSnapshot() {
        let record = makeRecord(status: .ready, snapshot: nil)
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.title, L("No AI analysis yet"))
        XCTAssertEqual(analysis.supportingText, L("Run clip analysis to unlock tags, suggestions, and scene markers."))
        XCTAssertFalse(analysis.showsProgress)
    }

    func test_inspectorAnalysis_readyForReadyWithSnapshot() {
        let record = makeRecord(status: .ready, snapshot: makeSnapshot())
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.title, L("AI analysis ready"))
        XCTAssertEqual(analysis.supportingText, "Opening beat lands quickly and the speaker is centered.")
        XCTAssertEqual(analysis.transcriptPreview, "Welcome back to Cutti.")
        XCTAssertEqual(analysis.suggestions.count, 1)
        XCTAssertEqual(analysis.issues.count, 1)
        XCTAssertEqual(analysis.suggestedTrimText, "00:00:00:15 - 00:00:08:00")
        XCTAssertFalse(analysis.showsProgress)
    }

    func test_inspectorAnalysis_supportingTextFallbackWhenNoSummary() {
        let snapshot = AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: []
        )
        let record = makeRecord(status: .ready, snapshot: snapshot)
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.supportingText, L("AI found clip-level insights for this selection."))
    }

    // MARK: - viewerSuggestions and timelineMarkers

    func test_viewerSuggestions_returnsSnapshotSuggestions() {
        let record = makeRecord(snapshot: makeSnapshot())
        let suggestions = AICopilotPresentation.viewerSuggestions(for: record)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].title, "Trim cold open")
    }

    func test_viewerSuggestions_emptyForNilRecord() {
        XCTAssertTrue(AICopilotPresentation.viewerSuggestions(for: nil).isEmpty)
    }

    func test_viewerSuggestions_emptyForRecordWithNoSnapshot() {
        let record = makeRecord(status: .ready, snapshot: nil)
        XCTAssertTrue(AICopilotPresentation.viewerSuggestions(for: record).isEmpty,
                      "A non-nil record with no snapshot should return no suggestions")
    }

    func test_timelineMarkers_emptyWhenNoSnapshot() {
        let record = makeRecord(status: .ready, snapshot: nil)
        XCTAssertTrue(AICopilotPresentation.timelineMarkers(for: record).isEmpty)
    }

    func test_timelineMarkers_sortedBySeconds() {
        let snapshot = AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: [
                AICopilotMarker(kind: .scene, seconds: 5.0, label: "Second"),
                AICopilotMarker(kind: .scene, seconds: 1.0, label: "First"),
                AICopilotMarker(kind: .scene, seconds: 9.0, label: "Third")
            ]
        )
        let record = makeRecord(snapshot: snapshot)
        let markers = AICopilotPresentation.timelineMarkers(for: record)
        XCTAssertEqual(markers.map(\.label), ["First", "Second", "Third"])
    }

    func test_inspectorAnalysis_suggestedTrimUsesRecordFPS() {
        // 0.5 seconds at 24 fps → 12 frames → "00:00:00:12"
        // 8.0 seconds at 24 fps →  0 frames → "00:00:08:00"
        let snapshot = AICopilotSnapshot(
            semanticTags: [],
            summary: "24fps clip",
            transcriptPreview: nil,
            suggestedInSeconds: 0.5,
            suggestedOutSeconds: 8.0,
            issues: [],
            suggestions: [],
            markers: []
        )
        let record = MediaAssetRecord(
            id: UUID(),
            sourcePath: "/tmp/clip24.mp4",
            fingerprint: SourceFingerprint(fileSize: 100, modifiedAt: .distantPast, sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 10, width: 1920, height: 1080, nominalFPS: 24, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: nil, thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            copilot: snapshot
        )
        let analysis = AICopilotPresentation.inspectorAnalysis(for: record)
        XCTAssertEqual(analysis.suggestedTrimText, "00:00:00:12 - 00:00:08:00",
                       "suggestedTrimText must use the record's nominalFPS (24), not a hard-coded 30")
    }

    // MARK: - suggestedTrimText(for:)

    func test_suggestedTrimText_formatsRange() {
        let snapshot = makeSnapshot()
        let text = AICopilotPresentation.suggestedTrimText(for: snapshot)
        // 0.5s at 30fps => 00:00:00:15, 8.0s at 30fps => 00:00:08:00
        // Uses ASCII hyphen separator, not en dash
        XCTAssertEqual(text, "00:00:00:15 - 00:00:08:00")
    }

    func test_suggestedTrimText_nilWhenOnlyInSecondsIsSet() {
        let snapshot = AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: 1.0,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: []
        )
        XCTAssertNil(AICopilotPresentation.suggestedTrimText(for: snapshot))
    }

    func test_suggestedTrimText_nilWhenOnlyOutSecondsIsSet() {
        let snapshot = AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: 8.0,
            issues: [],
            suggestions: [],
            markers: []
        )
        XCTAssertNil(AICopilotPresentation.suggestedTrimText(for: snapshot))
    }

    func test_suggestedTrimText_nilWhenNoTrimDefined() {
        let snapshot = AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: []
        )
        XCTAssertNil(AICopilotPresentation.suggestedTrimText(for: snapshot))
    }
}
