import XCTest
import CuttiKit
@testable import CuttiMac

/// PR 7 of the opening-hook feature: tests for the pure helper that
/// computes per-record `.highlight` marker updates from a `score_hook_
/// candidates` result. The dispatcher consumes these and merges them
/// into a freshly-loaded manifest at save time.
final class AgentHookHighlightMarkerTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeSnapshot(markers: [AICopilotMarker] = []) -> AICopilotSnapshot {
        AICopilotSnapshot(
            semanticTags: [],
            issues: [],
            suggestions: [],
            markers: markers
        )
    }

    private func makeRecord(
        id: UUID = UUID(),
        snapshot: AICopilotSnapshot? = nil,
        kind: MediaKind = .video
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: id,
            sourcePath: "/tmp/\(id.uuidString).mov",
            fingerprint: SourceFingerprint(fileSize: 1, modifiedAt: Date(), sha256Prefix: "x"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 60, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(thumbnailsReady: true, waveformsReady: true),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            copilot: snapshot,
            kind: kind
        )
    }

    private func makeCandidate(
        sourceVideoID: UUID,
        start: Double,
        end: Double,
        text: String = "punchy line",
        overall: Double = 0.8
    ) -> HookCandidate {
        HookCandidate(
            sourceVideoID: sourceVideoID,
            sourceName: "test.mov",
            sourceStart: start,
            sourceEnd: end,
            text: text,
            scoreOverall: overall,
            scoreLength: 1.0,
            scorePosition: 0.5,
            scoreAntiFiller: 1.0,
            scoreEnergy: 0.7,
            reason: "test"
        )
    }

    // MARK: - Empty / no-op cases

    func test_emptyCandidates_emptyRecords_emitsNoUpdates() {
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: [],
            records: []
        )
        XCTAssertTrue(updates.isEmpty)
    }

    func test_recordsWithoutCopilotSnapshot_areSkipped() {
        let recID = UUID()
        let rec = makeRecord(id: recID, snapshot: nil)
        let cand = makeCandidate(sourceVideoID: recID, start: 5, end: 10)
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: [cand],
            records: [rec]
        )
        XCTAssertTrue(updates.isEmpty,
                      "records without a copilot snapshot must be skipped — we don't fabricate one for markers")
    }

    func test_candidatesForUnknownRecord_areIgnored() {
        let recID = UUID()
        let rec = makeRecord(id: recID, snapshot: makeSnapshot())
        let foreignID = UUID()
        let cand = makeCandidate(sourceVideoID: foreignID, start: 5, end: 10)
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: [cand],
            records: [rec]
        )
        XCTAssertTrue(updates.isEmpty,
                      "candidate referencing a record not in the project must not produce phantom updates")
    }

    // MARK: - Happy paths

    func test_singleCandidate_writesSingleHighlightAtSourceStart() {
        let recID = UUID()
        let rec = makeRecord(id: recID, snapshot: makeSnapshot())
        let cand = makeCandidate(sourceVideoID: recID, start: 5.5, end: 10.0, text: "this is the punchy hook")
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: [cand],
            records: [rec]
        )
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.recordID, recID)
        XCTAssertEqual(updates.first?.newHighlights.count, 1)
        XCTAssertEqual(updates.first?.newHighlights.first?.kind, .highlight)
        XCTAssertEqual(updates.first?.newHighlights.first?.seconds, 5.5)
        XCTAssertEqual(updates.first?.newHighlights.first?.label, "this is the punchy hook")
    }

    func test_multipleCandidatesFromSameRecord_writeMultipleHighlights() {
        let recID = UUID()
        let rec = makeRecord(id: recID, snapshot: makeSnapshot())
        let cands = [
            makeCandidate(sourceVideoID: recID, start: 30, end: 35, text: "second"),
            makeCandidate(sourceVideoID: recID, start: 5, end: 10, text: "first"),
            makeCandidate(sourceVideoID: recID, start: 50, end: 55, text: "third")
        ]
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: cands,
            records: [rec]
        )
        XCTAssertEqual(updates.count, 1)
        // Sorted by seconds ascending so the persisted order is stable
        // regardless of candidate input order.
        XCTAssertEqual(updates.first?.newHighlights.map(\.seconds), [5, 30, 50])
        XCTAssertEqual(updates.first?.newHighlights.map(\.label), ["first", "second", "third"])
    }

    func test_candidatesAcrossMultipleRecords_emitOneUpdatePerRecord() {
        let aID = UUID()
        let bID = UUID()
        let recA = makeRecord(id: aID, snapshot: makeSnapshot())
        let recB = makeRecord(id: bID, snapshot: makeSnapshot())
        let cands = [
            makeCandidate(sourceVideoID: aID, start: 5, end: 10),
            makeCandidate(sourceVideoID: bID, start: 12, end: 18),
            makeCandidate(sourceVideoID: aID, start: 30, end: 35)
        ]
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: cands,
            records: [recA, recB]
        )
        XCTAssertEqual(updates.count, 2)
        let byRecord = Dictionary(uniqueKeysWithValues: updates.map { ($0.recordID, $0.newHighlights) })
        XCTAssertEqual(byRecord[aID]?.count, 2)
        XCTAssertEqual(byRecord[bID]?.count, 1)
    }

    // MARK: - Replacement / preservation

    func test_priorHighlightsReplaced_notDuplicated() {
        let recID = UUID()
        let stale = AICopilotMarker(kind: .highlight, seconds: 99, label: "stale")
        let rec = makeRecord(id: recID, snapshot: makeSnapshot(markers: [stale]))
        let cand = makeCandidate(sourceVideoID: recID, start: 5, end: 10, text: "fresh")
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: [cand],
            records: [rec]
        )
        XCTAssertEqual(updates.count, 1)
        let highlights = updates.first?.newHighlights ?? []
        XCTAssertEqual(highlights.count, 1, "old highlight must not survive the replacement")
        XCTAssertEqual(highlights.first?.seconds, 5)
        XCTAssertEqual(highlights.first?.label, "fresh")
    }

    func test_priorHighlightsCleared_whenNoCandidatesTargetThatRecord() {
        // Record A previously had highlights; the new run has zero
        // candidates from A (only from B). A's highlights must be
        // cleared, not unioned, so the latest run is the source of truth
        // across all records.
        let aID = UUID()
        let bID = UUID()
        let staleA = AICopilotMarker(kind: .highlight, seconds: 7, label: "old A")
        let recA = makeRecord(id: aID, snapshot: makeSnapshot(markers: [staleA]))
        let recB = makeRecord(id: bID, snapshot: makeSnapshot())
        let cand = makeCandidate(sourceVideoID: bID, start: 4, end: 8)
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: [cand],
            records: [recA, recB]
        )
        let aUpdate = updates.first { $0.recordID == aID }
        XCTAssertNotNil(aUpdate, "record A must produce an update — its stale highlight needs clearing")
        XCTAssertTrue(aUpdate?.newHighlights.isEmpty == true,
                      "record A's new highlights must be empty (clear, not union)")
    }

    func test_otherMarkerKinds_preservedInDispatcherFiltering() {
        // The helper only emits the *new* highlight set; the dispatcher
        // is responsible for splicing it back in around non-highlight
        // markers. We document that contract by computing what the
        // dispatcher's filter step will see.
        let recID = UUID()
        let scene = AICopilotMarker(kind: .scene, seconds: 0, label: "Hook starts")
        let suggestion = AICopilotMarker(kind: .suggestion, seconds: 12, label: "B-roll")
        let warning = AICopilotMarker(kind: .warning, seconds: 30, label: "Volume spike")
        let oldHi = AICopilotMarker(kind: .highlight, seconds: 99, label: "stale")
        let rec = makeRecord(
            id: recID,
            snapshot: makeSnapshot(markers: [scene, suggestion, warning, oldHi])
        )
        let cand = makeCandidate(sourceVideoID: recID, start: 5, end: 10, text: "fresh")
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: [cand],
            records: [rec]
        )
        let merged = (rec.copilot!.markers.filter { $0.kind != .highlight }) +
            (updates.first?.newHighlights ?? [])
        XCTAssertTrue(merged.contains(scene))
        XCTAssertTrue(merged.contains(suggestion))
        XCTAssertTrue(merged.contains(warning))
        XCTAssertFalse(merged.contains(oldHi))
        XCTAssertEqual(merged.filter { $0.kind == .highlight }.count, 1)
    }

    // MARK: - Stable comparison / no spurious updates

    func test_noUpdate_whenPriorAndProposedHighlightsMatch() {
        let recID = UUID()
        let existing = AICopilotMarker(kind: .highlight, seconds: 5, label: "same line")
        let rec = makeRecord(id: recID, snapshot: makeSnapshot(markers: [existing]))
        let cand = makeCandidate(sourceVideoID: recID, start: 5, end: 10, text: "same line")
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: [cand],
            records: [rec]
        )
        XCTAssertTrue(updates.isEmpty,
                      "no-op runs must not trigger redundant manifest writes")
    }

    func test_candidateOrderDoesNotCauseSpuriousUpdate() {
        let recID = UUID()
        let existing = [
            AICopilotMarker(kind: .highlight, seconds: 5, label: "alpha"),
            AICopilotMarker(kind: .highlight, seconds: 30, label: "beta")
        ]
        let rec = makeRecord(id: recID, snapshot: makeSnapshot(markers: existing))
        // Same two candidates but in reversed order.
        let cands = [
            makeCandidate(sourceVideoID: recID, start: 30, end: 35, text: "beta"),
            makeCandidate(sourceVideoID: recID, start: 5, end: 10, text: "alpha")
        ]
        let updates = AgentHook.computeHighlightMarkerUpdates(
            candidates: cands,
            records: [rec]
        )
        XCTAssertTrue(updates.isEmpty,
                      "reordered-but-equivalent candidate sets must not trigger updates after sort")
    }

    // MARK: - Label normalization

    func test_label_collapsesNewlinesAndTabs() {
        XCTAssertEqual(
            AgentHook.makeHighlightLabel(from: "first\nsecond\tthird"),
            "first second third"
        )
    }

    func test_label_trimsLeadingTrailingWhitespace() {
        XCTAssertEqual(AgentHook.makeHighlightLabel(from: "  hello  "), "hello")
    }

    func test_label_truncatedAt60Characters() {
        let long = String(repeating: "a", count: 100)
        let label = AgentHook.makeHighlightLabel(from: long)
        XCTAssertEqual(label.count, 60)
    }

    func test_label_shortTextPreservedExactly() {
        XCTAssertEqual(AgentHook.makeHighlightLabel(from: "quick"), "quick")
    }
}
