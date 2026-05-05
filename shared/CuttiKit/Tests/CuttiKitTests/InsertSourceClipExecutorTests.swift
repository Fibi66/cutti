import XCTest
@testable import CuttiKit

/// Pins behaviour of `AIAction.insertSourceClip` — the splice action
/// powering cold-open hook teasers, callback inserts, and any other
/// "drop a slice of source media into the timeline" agent move. The
/// matrix below covers every interesting host configuration so that a
/// regression in the executor or the supporting helpers is caught at
/// CuttiKit-test time, before macOS / iOS layer wiring sees it.
final class InsertSourceClipExecutorTests: XCTestCase {

    // MARK: - Fixtures

    private let foreignSourceID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    private func makeSegment(
        id: UUID = UUID(),
        sourceVideoID: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        start: Double,
        end: Double,
        speedRate: Double = 1.0,
        text: String = ""
    ) -> TimelineSegment {
        var segment = TimelineSegment(
            id: id,
            sourceVideoID: sourceVideoID,
            range: TimeRange(startSeconds: start, endSeconds: end),
            text: text,
            subtitles: []
        )
        segment.speedRate = speedRate
        return segment
    }

    private func apply(
        _ action: AIAction,
        to segments: [TimelineSegment],
        explanation: String = "test",
        transcriptLookup: AIActionExecutor.TranscriptLookup = { _, _ in [] }
    ) -> AIActionExecutor.Result {
        AIActionExecutor.apply(
            batch: AIActionBatch(actions: [action], explanation: explanation),
            to: segments,
            transcriptLookup: transcriptLookup
        )
    }

    // MARK: - Prepend / append / split insertion

    func test_insertSourceClip_atZero_prependsBeforeAllSegments() {
        let hostID = UUID()
        let segments = [
            makeSegment(id: hostID, start: 0, end: 10, text: "host")
        ]

        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 100,
                sourceEnd: 105,
                composedInsertAt: 0,
                fadeInSeconds: 0.15,
                fadeOutSeconds: 0.30
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].sourceVideoID, foreignSourceID)
        XCTAssertEqual(result.segments[0].range.startSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(result.segments[0].range.endSeconds, 105, accuracy: 0.001)
        // Host segment passes through unchanged.
        XCTAssertEqual(result.segments[1].id, hostID)
        XCTAssertEqual(result.segments[1].range.startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].range.endSeconds, 10, accuracy: 0.001)
    }

    func test_insertSourceClip_atTimelineEnd_appendsLast() {
        let hostA = UUID()
        let hostB = UUID()
        let segments = [
            makeSegment(id: hostA, start: 0, end: 4),
            makeSegment(id: hostB, start: 0, end: 4)
        ]

        // Total composed = 8s; insert at 8 → append.
        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 5,
                composedInsertAt: 8,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].id, hostA)
        XCTAssertEqual(result.segments[1].id, hostB)
        XCTAssertEqual(result.segments[2].sourceVideoID, foreignSourceID)
    }

    func test_insertSourceClip_clampsNegativeInsertToZero() {
        let segments = [makeSegment(start: 0, end: 10, text: "host")]

        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 3,
                composedInsertAt: -42,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.first?.sourceVideoID, foreignSourceID)
    }

    func test_insertSourceClip_clampsHugeInsertToTimelineEnd() {
        let segments = [makeSegment(start: 0, end: 4, text: "host")]

        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 3,
                composedInsertAt: 9_999,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.last?.sourceVideoID, foreignSourceID)
    }

    func test_insertSourceClip_atSegmentBoundary_splicesBetween() {
        let a = UUID()
        let b = UUID()
        let segments = [
            makeSegment(id: a, start: 0, end: 5, text: "A"),
            makeSegment(id: b, start: 0, end: 5, text: "B")
        ]

        // Boundary at composed 5s → between A and B without splitting.
        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 2,
                composedInsertAt: 5,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].id, a)
        XCTAssertEqual(result.segments[1].sourceVideoID, foreignSourceID)
        XCTAssertEqual(result.segments[2].id, b)
    }

    func test_insertSourceClip_midSegment_splitsHostAndInserts() {
        let host = UUID()
        let segments = [makeSegment(id: host, start: 0, end: 10, text: "host")]

        // Composed insert at 4s splits host [0..4] + new + [4..10].
        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 3,
                composedInsertAt: 4,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].range.startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(result.segments[0].range.endSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].sourceVideoID, foreignSourceID)
        XCTAssertEqual(result.segments[1].range.startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].range.endSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(result.segments[2].range.startSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(result.segments[2].range.endSeconds, 10, accuracy: 0.001)

        // Total composed duration = 4 + 3 + 6 = 13.
        let total = result.segments.reduce(0.0) { $0 + $1.durationSeconds }
        XCTAssertEqual(total, 13.0, accuracy: 0.001)
    }

    func test_insertSourceClip_midSegment_withSpeedRate_splitsCorrectSourceTime() {
        // Host plays at 2x: source [0..10] becomes composed [0..5].
        // Composed insert at 2s → cut at composed 2s = source 4s.
        let host = UUID()
        let segments = [
            makeSegment(id: host, start: 0, end: 10, speedRate: 2.0, text: "fast")
        ]

        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 50,
                sourceEnd: 53,
                composedInsertAt: 2,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.count, 3)
        // Left half: source [0..4] still at 2x.
        XCTAssertEqual(result.segments[0].range.startSeconds, 0, accuracy: 0.01)
        XCTAssertEqual(result.segments[0].range.endSeconds, 4, accuracy: 0.01)
        XCTAssertEqual(result.segments[0].normalizedSpeedRate, 2.0, accuracy: 0.001)
        // Inserted clip plays at native speed.
        XCTAssertEqual(result.segments[1].sourceVideoID, foreignSourceID)
        XCTAssertEqual(result.segments[1].normalizedSpeedRate, 1.0, accuracy: 0.001)
        // Right half: source [4..10] still at 2x.
        XCTAssertEqual(result.segments[2].range.startSeconds, 4, accuracy: 0.01)
        XCTAssertEqual(result.segments[2].range.endSeconds, 10, accuracy: 0.01)
        XCTAssertEqual(result.segments[2].normalizedSpeedRate, 2.0, accuracy: 0.001)
    }

    // MARK: - Fade handling

    func test_insertSourceClip_fadesAreClampedAndApplied() {
        let segments = [makeSegment(start: 0, end: 5, text: "host")]

        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 1,
                composedInsertAt: 0,
                fadeInSeconds: 5,    // clamped to clipDuration / 2 = 0.5
                fadeOutSeconds: -3   // clamped to 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        let inserted = try? XCTUnwrap(result.segments.first)
        XCTAssertEqual(inserted?.effects.audioFadeInDuration ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(inserted?.effects.audioFadeOutDuration ?? -1, 0.0, accuracy: 0.001)
    }

    func test_insertSourceClip_midSegment_clearsInteriorFadesOnHostHalves() {
        var hostEffects = SegmentEffects.default
        hostEffects.audioFadeInDuration = 0.4
        hostEffects.audioFadeOutDuration = 0.6
        var host = makeSegment(start: 0, end: 10, text: "host")
        host.effects = hostEffects

        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 2,
                composedInsertAt: 4,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: [host]
        )

        XCTAssertEqual(result.segments.count, 3)

        // Left half: outer fade-in preserved, interior fade-out cleared.
        XCTAssertEqual(result.segments[0].effects.audioFadeInDuration, 0.4, accuracy: 0.001)
        XCTAssertEqual(result.segments[0].effects.audioFadeOutDuration, 0.0, accuracy: 0.001)
        // Right half: interior fade-in cleared, outer fade-out preserved.
        XCTAssertEqual(result.segments[2].effects.audioFadeInDuration, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.segments[2].effects.audioFadeOutDuration, 0.6, accuracy: 0.001)
    }

    // MARK: - Subtitle population

    func test_insertSourceClip_pullsSubtitlesFromForeignSource() {
        let segments = [makeSegment(start: 0, end: 4, text: "host")]

        // Lookup synthesises a single subtitle entry for the inserted
        // range. Verifies `(ranges, sourceVideoID)` callback semantics.
        let lookup: AIActionExecutor.TranscriptLookup = { ranges, sourceID in
            guard sourceID == self.foreignSourceID,
                  let range = ranges.first else { return [] }
            return [SubtitleEntry(
                id: UUID(),
                relativeStart: 0,
                relativeDuration: range.endSeconds - range.startSeconds,
                text: "金句"
            )]
        }

        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [
                    .insertSourceClip(
                        sourceVideoID: foreignSourceID,
                        sourceStart: 100,
                        sourceEnd: 103,
                        composedInsertAt: 0,
                        fadeInSeconds: 0,
                        fadeOutSeconds: 0
                    )
                ],
                explanation: "hook teaser"
            ),
            to: segments,
            transcriptLookup: lookup
        )

        XCTAssertEqual(result.appliedCount, 1)
        let inserted = result.segments.first
        XCTAssertEqual(inserted?.subtitles.count, 1)
        XCTAssertEqual(inserted?.subtitles.first?.text, "金句")
        XCTAssertEqual(inserted?.text, "金句")
    }

    func test_insertSourceClip_unknownSourceWithEmptyLookup_stillInserts() {
        let segments = [makeSegment(start: 0, end: 4, text: "host")]

        // Lookup returns empty for the foreign source — the segment
        // is still inserted, just with no subtitle entries. Validator
        // is the layer that gates unknown-source UUIDs.
        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 2,
                composedInsertAt: 0,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.first?.sourceVideoID, foreignSourceID)
        XCTAssertTrue(result.segments.first?.subtitles.isEmpty ?? false)
    }

    // MARK: - Degenerate / skipped

    func test_insertSourceClip_invertedSourceRange_isSkipped() {
        let segments = [makeSegment(start: 0, end: 4, text: "host")]

        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 5,
                sourceEnd: 1, // inverted
                composedInsertAt: 0,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.text, "host")
    }

    func test_insertSourceClip_subSecondSourceRange_stillInserts() {
        // Executor accepts down to ~10ms (validator handles the
        // 0.2s policy bound). 0.1s clip gets inserted as-is.
        let segments = [makeSegment(start: 0, end: 4, text: "host")]
        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 0.1,
                composedInsertAt: 0,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: segments
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.first?.range.endSeconds ?? 0, 0.1, accuracy: 0.001)
    }

    // MARK: - Empty timeline

    func test_insertSourceClip_intoEmptyTimeline_appendsAsOnlySegment() {
        let result = apply(
            .insertSourceClip(
                sourceVideoID: foreignSourceID,
                sourceStart: 0,
                sourceEnd: 5,
                composedInsertAt: 0,
                fadeInSeconds: 0,
                fadeOutSeconds: 0
            ),
            to: []
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.sourceVideoID, foreignSourceID)
    }

    // MARK: - Mixed batch

    func test_mixedBatch_insertThenDeleteRange_appliesAgainstMutatedTimeline() {
        // Action ordering contract: each subsequent action sees the
        // post-mutation state. After inserting a 5s teaser at 0, the
        // delete_range below operates on the new composed offsets.
        let host = UUID()
        let segments = [makeSegment(id: host, start: 0, end: 10, text: "host")]

        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [
                    .insertSourceClip(
                        sourceVideoID: foreignSourceID,
                        sourceStart: 0,
                        sourceEnd: 5,
                        composedInsertAt: 0,
                        fadeInSeconds: 0,
                        fadeOutSeconds: 0
                    ),
                    // After insert: timeline = [0..5 teaser, 0..10 host].
                    // delete_range 5..7 should cut [0..2] off the host.
                    .deleteRange(start: 5, end: 7)
                ],
                explanation: "teaser then trim host head"
            ),
            to: segments,
            transcriptLookup: { _, _ in [] }
        )

        XCTAssertEqual(result.appliedCount, 2)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].sourceVideoID, foreignSourceID)
        // Host's UUID changes after deleteRange splits via
        // makeDerivedSegment — assert by source identity + range.
        XCTAssertEqual(result.segments[1].sourceVideoID, segments.first?.sourceVideoID)
        XCTAssertEqual(result.segments[1].range.startSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].range.endSeconds, 10, accuracy: 0.001)
    }

    // MARK: - Codable round-trip

    func test_insertSourceClip_codableRoundTrip_preservesAllFields() throws {
        let action = AIAction.insertSourceClip(
            sourceVideoID: foreignSourceID,
            sourceStart: 12.5,
            sourceEnd: 17.75,
            composedInsertAt: 3.14159,
            fadeInSeconds: 0.15,
            fadeOutSeconds: 0.30
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(AIAction.self, from: data)
        guard case let .insertSourceClip(sid, ss, se, ci, fi, fo) = decoded else {
            XCTFail("Expected insertSourceClip")
            return
        }
        XCTAssertEqual(sid, foreignSourceID)
        XCTAssertEqual(ss, 12.5, accuracy: 1e-9)
        XCTAssertEqual(se, 17.75, accuracy: 1e-9)
        XCTAssertEqual(ci, 3.14159, accuracy: 1e-9)
        XCTAssertEqual(fi, 0.15, accuracy: 1e-9)
        XCTAssertEqual(fo, 0.30, accuracy: 1e-9)
    }

    // MARK: - Validator

    func test_validator_rejectsInvertedSourceRange() {
        let report = AIActionValidator.validate(
            batch: AIActionBatch(
                actions: [.insertSourceClip(
                    sourceVideoID: foreignSourceID,
                    sourceStart: 10,
                    sourceEnd: 5,
                    composedInsertAt: 0,
                    fadeInSeconds: 0,
                    fadeOutSeconds: 0
                )],
                explanation: ""
            ),
            segments: []
        )
        XCTAssertTrue(report.errors.contains { $0.code == "inverted_source_range" })
    }

    func test_validator_rejectsTooShortSourceRange() {
        let report = AIActionValidator.validate(
            batch: AIActionBatch(
                actions: [.insertSourceClip(
                    sourceVideoID: foreignSourceID,
                    sourceStart: 0,
                    sourceEnd: 0.05,
                    composedInsertAt: 0,
                    fadeInSeconds: 0,
                    fadeOutSeconds: 0
                )],
                explanation: ""
            ),
            segments: []
        )
        XCTAssertTrue(report.errors.contains { $0.code == "source_range_too_short" })
    }

    func test_validator_rejectsNegativeComposedInsert() {
        let report = AIActionValidator.validate(
            batch: AIActionBatch(
                actions: [.insertSourceClip(
                    sourceVideoID: foreignSourceID,
                    sourceStart: 0,
                    sourceEnd: 3,
                    composedInsertAt: -5,
                    fadeInSeconds: 0,
                    fadeOutSeconds: 0
                )],
                explanation: ""
            ),
            segments: []
        )
        XCTAssertTrue(report.errors.contains { $0.code == "negative_composed_insert" })
    }

    func test_validator_rejectsInsertPastTimeline() {
        let report = AIActionValidator.validate(
            batch: AIActionBatch(
                actions: [.insertSourceClip(
                    sourceVideoID: foreignSourceID,
                    sourceStart: 0,
                    sourceEnd: 3,
                    composedInsertAt: 999,
                    fadeInSeconds: 0,
                    fadeOutSeconds: 0
                )],
                explanation: ""
            ),
            segments: [makeSegment(start: 0, end: 4)]
        )
        XCTAssertTrue(report.errors.contains { $0.code == "insert_past_timeline" })
    }

    func test_validator_rejectsNegativeFade() {
        let report = AIActionValidator.validate(
            batch: AIActionBatch(
                actions: [.insertSourceClip(
                    sourceVideoID: foreignSourceID,
                    sourceStart: 0,
                    sourceEnd: 3,
                    composedInsertAt: 0,
                    fadeInSeconds: -1,
                    fadeOutSeconds: 0
                )],
                explanation: ""
            ),
            segments: []
        )
        XCTAssertTrue(report.errors.contains { $0.code == "negative_fade" })
    }

    func test_validator_rejectsUnknownSourceWhenSetProvided() {
        let known = UUID()
        let report = AIActionValidator.validate(
            batch: AIActionBatch(
                actions: [.insertSourceClip(
                    sourceVideoID: foreignSourceID, // not in `known`
                    sourceStart: 0,
                    sourceEnd: 3,
                    composedInsertAt: 0,
                    fadeInSeconds: 0,
                    fadeOutSeconds: 0
                )],
                explanation: ""
            ),
            segments: [],
            knownSourceVideoIDs: [known]
        )
        XCTAssertTrue(report.errors.contains { $0.code == "unknown_source_video" })
    }

    func test_validator_acceptsKnownSource() {
        let report = AIActionValidator.validate(
            batch: AIActionBatch(
                actions: [.insertSourceClip(
                    sourceVideoID: foreignSourceID,
                    sourceStart: 0,
                    sourceEnd: 3,
                    composedInsertAt: 0,
                    fadeInSeconds: 0,
                    fadeOutSeconds: 0
                )],
                explanation: ""
            ),
            segments: [],
            knownSourceVideoIDs: [foreignSourceID]
        )
        XCTAssertFalse(report.hasErrors)
    }

    func test_validator_emptyKnownSet_skipsSourceCheck() {
        // Default `knownSourceVideoIDs: []` means "don't enforce" so
        // back-compat callers (older tests, kit-only call sites) keep
        // working without forcing every test to rebuild a record set.
        let report = AIActionValidator.validate(
            batch: AIActionBatch(
                actions: [.insertSourceClip(
                    sourceVideoID: foreignSourceID,
                    sourceStart: 0,
                    sourceEnd: 3,
                    composedInsertAt: 0,
                    fadeInSeconds: 0,
                    fadeOutSeconds: 0
                )],
                explanation: ""
            ),
            segments: []
        )
        XCTAssertFalse(report.errors.contains { $0.code == "unknown_source_video" })
    }
}
