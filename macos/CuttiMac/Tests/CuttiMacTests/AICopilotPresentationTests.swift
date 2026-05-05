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

    // MARK: - highlightGroups(records:)

    private func makeHighlightSnapshot(
        markers: [AICopilotMarker]
    ) -> AICopilotSnapshot {
        AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: markers
        )
    }

    func test_highlightGroups_emptyInputProducesEmptyResult() {
        XCTAssertEqual(AICopilotPresentation.highlightGroups(records: []).count, 0)
    }

    func test_highlightGroups_skipsRecordsWithoutSnapshot() {
        let r1 = makeRecord()
        let r2 = makeRecord(snapshot: makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 1, endSeconds: 4, label: "Hook 1")
        ]))
        let groups = AICopilotPresentation.highlightGroups(records: [r1, r2])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.recordID, r2.id)
    }

    func test_highlightGroups_filtersToHighlightKindOnly() {
        let snapshot = makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .scene, seconds: 0, label: "Scene"),
            AICopilotMarker(kind: .suggestion, seconds: 1, label: "Suggestion"),
            AICopilotMarker(kind: .highlight, seconds: 2, endSeconds: 5, label: "Hook"),
            AICopilotMarker(kind: .warning, seconds: 3, label: "Warning")
        ])
        let record = makeRecord(snapshot: snapshot)
        let groups = AICopilotPresentation.highlightGroups(records: [record])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].highlights.count, 1)
        XCTAssertEqual(groups[0].highlights[0].label, "Hook")
    }

    func test_highlightGroups_sortsRowsByStartTime() {
        let snapshot = makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 12, endSeconds: 14, label: "Third"),
            AICopilotMarker(kind: .highlight, seconds: 3, endSeconds: 5, label: "First"),
            AICopilotMarker(kind: .highlight, seconds: 7, endSeconds: 9, label: "Second")
        ])
        let record = makeRecord(snapshot: snapshot)
        let groups = AICopilotPresentation.highlightGroups(records: [record])
        XCTAssertEqual(groups[0].highlights.map(\.label), ["First", "Second", "Third"])
    }

    func test_highlightGroups_preservesRecordOrderingFromInput() {
        let r1 = makeRecord(
            snapshot: makeHighlightSnapshot(markers: [
                AICopilotMarker(kind: .highlight, seconds: 0, endSeconds: 2, label: "A1")
            ]),
            sourcePath: "/tmp/a.mp4"
        )
        let r2 = makeRecord(
            snapshot: makeHighlightSnapshot(markers: [
                AICopilotMarker(kind: .highlight, seconds: 0, endSeconds: 2, label: "B1")
            ]),
            sourcePath: "/tmp/b.mp4"
        )
        let groups = AICopilotPresentation.highlightGroups(records: [r1, r2])
        XCTAssertEqual(groups.map(\.recordID), [r1.id, r2.id])
        let reversed = AICopilotPresentation.highlightGroups(records: [r2, r1])
        XCTAssertEqual(reversed.map(\.recordID), [r2.id, r1.id])
    }

    func test_highlightGroups_omitsRecordsWithEmptyHighlightArray() {
        let snapshot = makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .scene, seconds: 0, label: "Scene only")
        ])
        let record = makeRecord(snapshot: snapshot)
        XCTAssertEqual(AICopilotPresentation.highlightGroups(records: [record]).count, 0)
    }

    func test_highlightGroups_carriesOriginThroughToRow() {
        let snapshot = makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 1, endSeconds: 3, label: "AI", origin: .ai),
            AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "User", origin: .manual)
        ])
        let record = makeRecord(snapshot: snapshot)
        let rows = AICopilotPresentation.highlightGroups(records: [record])[0].highlights
        XCTAssertEqual(rows[0].origin, .ai)
        XCTAssertEqual(rows[1].origin, .manual)
    }

    func test_highlightRow_isDraggableOnlyWhenEndSecondsPresent() {
        let modern = AICopilotPresentation.HighlightRow(
            sourceVideoID: UUID(), seconds: 1, endSeconds: 3,
            label: "x", origin: .ai, markerIndex: 0
        )
        let legacy = AICopilotPresentation.HighlightRow(
            sourceVideoID: UUID(), seconds: 1, endSeconds: nil,
            label: "x", origin: .ai, markerIndex: 0
        )
        XCTAssertTrue(modern.isDraggable)
        XCTAssertFalse(legacy.isDraggable)
    }

    // MARK: - highlightCount(records:)

    func test_highlightCount_zeroWhenNoSnapshots() {
        XCTAssertEqual(AICopilotPresentation.highlightCount(records: [makeRecord()]), 0)
    }

    func test_highlightCount_aggregatesAcrossAllRecords() {
        let r1 = makeRecord(snapshot: makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 0, endSeconds: 1, label: "x"),
            AICopilotMarker(kind: .highlight, seconds: 2, endSeconds: 3, label: "y")
        ]))
        let r2 = makeRecord(snapshot: makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 0, endSeconds: 1, label: "z"),
            AICopilotMarker(kind: .scene, seconds: 5, label: "scene"),
        ]))
        XCTAssertEqual(AICopilotPresentation.highlightCount(records: [r1, r2]), 3)
    }

    // MARK: - drag payload round-trip

    func test_highlightDragPayload_roundTripsThroughParser() {
        let id = UUID()
        let payload = AICopilotPresentation.highlightDragPayload(recordID: id, start: 1.5, end: 4.75)
        let parsed = AICopilotPresentation.parseHighlightPayload(payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.recordID, id)
        XCTAssertEqual(parsed?.start ?? 0, 1.5, accuracy: 1e-4)
        XCTAssertEqual(parsed?.end ?? 0, 4.75, accuracy: 1e-4)
    }

    func test_highlightDragPayload_carriesPrefix() {
        let payload = AICopilotPresentation.highlightDragPayload(
            recordID: UUID(), start: 0, end: 1
        )
        XCTAssertTrue(payload.hasPrefix("highlight:"))
    }

    func test_parseHighlightPayload_returnsNilForUnrelatedPayload() {
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("media:\(UUID().uuidString)"))
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("not a payload"))
    }

    func test_parseHighlightPayload_returnsNilForMalformedFields() {
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("highlight:not-a-uuid:0:1"))
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("highlight:\(UUID().uuidString):oops:1"))
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("highlight:\(UUID().uuidString):1"))
    }

    func test_parseHighlightPayload_returnsNilForNonPositiveSpan() {
        let id = UUID().uuidString
        // Equal endpoints (zero-length span) should be rejected so the
        // drop handler doesn't try to insert a degenerate clip.
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("highlight:\(id):2.0:2.0"))
        // Inverted endpoints likewise.
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("highlight:\(id):3.0:1.0"))
    }

    func test_parseHighlightPayload_returnsNilForNegativeStart() {
        let id = UUID().uuidString
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("highlight:\(id):-1.0:2.0"))
    }

    func test_parseHighlightPayload_returnsNilForNonFiniteCoords() {
        let id = UUID().uuidString
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("highlight:\(id):nan:1.0"))
        XCTAssertNil(AICopilotPresentation.parseHighlightPayload("highlight:\(id):0.0:inf"))
    }

    func test_highlightGroups_assignsUniqueMarkerIndexTiebreaker() {
        // Pathological case: two markers with identical (start, end,
        // label) on the same record. Without the markerIndex
        // tiebreaker these would collide as ForEach IDs.
        let snapshot = makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "Same"),
            AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "Same")
        ])
        let record = makeRecord(snapshot: snapshot)
        let rows = AICopilotPresentation.highlightGroups(records: [record])[0].highlights
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertNotEqual(rows[0].markerIndex, rows[1].markerIndex)
    }

    // MARK: - markerIndex semantics (PR 10)

    func test_highlightGroups_markerIndexMatchesRawArrayPosition() {
        // The Highlights panel removes by markers.remove(at:
        // markerIndex), so markerIndex MUST equal the marker's
        // position in the record's *raw* copilot.markers array
        // (mixed kinds), not its position in the sorted
        // highlight-only projection.
        let snapshot = makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .scene,     seconds: 0,  label: "Scene"),       // raw 0
            AICopilotMarker(kind: .highlight, seconds: 12, endSeconds: 14, label: "Late"), // raw 1
            AICopilotMarker(kind: .suggestion, seconds: 1, label: "Sug"),         // raw 2
            AICopilotMarker(kind: .highlight, seconds: 3,  endSeconds: 5,  label: "Early") // raw 3
        ])
        let record = makeRecord(snapshot: snapshot)
        let rows = AICopilotPresentation.highlightGroups(records: [record])[0].highlights
        // Sorted by `seconds`: Early(3) before Late(12)
        XCTAssertEqual(rows.map(\.label), ["Early", "Late"])
        // But markerIndex preserves raw-array position
        XCTAssertEqual(rows[0].markerIndex, 3)
        XCTAssertEqual(rows[1].markerIndex, 1)
    }

    func test_highlightGroups_totalOrderResolvesTiesDeterministically() {
        // Two highlights with identical seconds + endSeconds but
        // different (origin, label, markerIndex) must produce a
        // stable order under any input permutation. We verify by
        // constructing two snapshots with the markers in opposite
        // order and asserting the row sequence is identical.
        let mAI = AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "AI", origin: .ai)
        let mManual = AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "Manual", origin: .manual)

        let r1 = makeRecord(snapshot: makeHighlightSnapshot(markers: [mAI, mManual]))
        let r2 = makeRecord(snapshot: makeHighlightSnapshot(markers: [mManual, mAI]))
        let rows1 = AICopilotPresentation.highlightGroups(records: [r1])[0].highlights
        let rows2 = AICopilotPresentation.highlightGroups(records: [r2])[0].highlights

        // Order is deterministic by (origin, label) regardless of
        // input array order.
        XCTAssertEqual(rows1.map(\.origin), rows2.map(\.origin))
        XCTAssertEqual(rows1.map(\.label), rows2.map(\.label))
    }

    func test_highlightRow_fingerprintCarriesAllNonKindFields() {
        let row = AICopilotPresentation.HighlightRow(
            sourceVideoID: UUID(), seconds: 12.5, endSeconds: 18.25,
            label: "Quote", origin: .manual, markerIndex: 4
        )
        let fp = row.fingerprint
        XCTAssertEqual(fp.seconds, 12.5)
        XCTAssertEqual(fp.endSeconds, 18.25)
        XCTAssertEqual(fp.origin, .manual)
        XCTAssertEqual(fp.label, "Quote")
    }

    func test_highlightGroups_mixedAIAndManualRendersInTimeOrder() {
        // Manual highlights and AI highlights both surface in the
        // same panel, sorted together by start time. Verifies PR 10
        // doesn't bucket manual into a separate visual section.
        let snapshot = makeHighlightSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 10, endSeconds: 12, label: "AI late",  origin: .ai),
            AICopilotMarker(kind: .highlight, seconds: 1,  endSeconds: 3,  label: "Manual early", origin: .manual),
            AICopilotMarker(kind: .highlight, seconds: 5,  endSeconds: 7,  label: "AI mid",   origin: .ai)
        ])
        let record = makeRecord(snapshot: snapshot)
        let rows = AICopilotPresentation.highlightGroups(records: [record])[0].highlights
        XCTAssertEqual(rows.map(\.label), ["Manual early", "AI mid", "AI late"])
        XCTAssertEqual(rows.map(\.origin), [.manual, .ai, .ai])
    }
}
