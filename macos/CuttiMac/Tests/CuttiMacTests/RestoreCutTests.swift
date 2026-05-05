import XCTest
import AVFoundation
import CuttiKit
@testable import CuttiMac

/// Tests for `MediaCoreViewModel.restoreCutBetween(leftIndex:rightIndex:)` —
/// the right-click action that recovers the cut-out gap between two
/// adjacent V1 segments that came from the same source video, along
/// with the matching subtitle cues. See plan.md for the full design.
@MainActor
final class RestoreCutTests: XCTestCase {

    // MARK: - Fixtures

    /// One source record at /tmp/<id>.mp4 with a 100s ready proxy and
    /// (optionally) a sentence-level transcript covering the whole
    /// duration.
    private func makeRecord(
        id: UUID = UUID(),
        durationSeconds: Double = 100,
        transcript: [TranscriptSegment]? = nil
    ) -> MediaAssetRecord {
        var record = MediaAssetRecord(
            id: id,
            sourcePath: "/tmp/\(id.uuidString).mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: durationSeconds, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "p.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        if let transcript = transcript {
            record.copilot = AICopilotSnapshot(
                semanticTags: [],
                issues: [],
                suggestions: [],
                markers: [],
                transcript: transcript
            )
        }
        return record
    }

    private func makeVM(
        record: MediaAssetRecord,
        segments: [TimelineSegment]
    ) -> MediaCoreViewModel {
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        vm.records = [record]
        vm.timelineSegments = segments
        return vm
    }

    private func segment(
        sourceID: UUID,
        start: Double,
        end: Double,
        text: String = "",
        speedRate: Double = 1.0,
        volumeLevel: Double = 1.0,
        isVideoHidden: Bool = false,
        effects: SegmentEffects = SegmentEffects(),
        linkedSegmentID: UUID? = nil,
        id: UUID = UUID()
    ) -> TimelineSegment {
        var seg = TimelineSegment(
            id: id,
            sourceVideoID: sourceID,
            range: TimeRange(startSeconds: start, endSeconds: end),
            text: text,
            subtitles: []
        )
        seg.speedRate = speedRate
        seg.volumeLevel = volumeLevel
        seg.isVideoHidden = isVideoHidden
        seg.effects = effects
        seg.linkedSegmentID = linkedSegmentID
        return seg
    }

    // MARK: - Gap helpers

    func test_gapBeforeAndAfter_returnsExpectedValues() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 10, end: 15),
                segment(sourceID: record.id, start: 20, end: 25)
            ]
        )

        XCTAssertNil(vm.gapBeforeSegment(at: 0), "first segment has no predecessor")
        XCTAssertEqual(vm.gapBeforeSegment(at: 1) ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(vm.gapAfterSegment(at: 1) ?? -1, 5, accuracy: 0.001)
        XCTAssertNil(vm.gapAfterSegment(at: 2), "last segment has no successor")
    }

    func test_gapBeforeSegment_returnsNilWhenSourcesDiffer() {
        let recordA = makeRecord()
        let recordB = makeRecord()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        vm.records = [recordA, recordB]
        vm.timelineSegments = [
            segment(sourceID: recordA.id, start: 0, end: 5),
            segment(sourceID: recordB.id, start: 10, end: 15)
        ]
        XCTAssertNil(
            vm.gapBeforeSegment(at: 1),
            "different source videos cannot share a 'cut'"
        )
    }

    func test_gapBefore_returnsNilForSubEpsilonGap() {
        // 0.04s gap → just below the 0.05 floor used by mergeSelectedSegments.
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 5.04, end: 10)
            ]
        )
        XCTAssertNil(vm.gapBeforeSegment(at: 1))
    }

    func test_gapBefore_returnsValueForAboveEpsilonGap() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 5.06, end: 10)
            ]
        )
        XCTAssertEqual(vm.gapBeforeSegment(at: 1) ?? 0, 0.06, accuracy: 0.0001)
    }

    func test_gapBefore_returnsNilWhenEitherSideHasLinkedAux() {
        let record = makeRecord()
        let auxID = UUID()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5, linkedSegmentID: auxID),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )
        XCTAssertNil(
            vm.gapBeforeSegment(at: 1),
            "menu must hide the action when a side is linked to detached aux audio"
        )
    }

    // MARK: - Merge path (effects compatible)

    func test_restoreCut_compatibleEffects_mergesIntoSingleSegment() {
        let record = makeRecord()
        let leftID = UUID()
        let rightID = UUID()
        let left = segment(sourceID: record.id, start: 0, end: 5, text: "A", id: leftID)
        let right = segment(sourceID: record.id, start: 10, end: 15, text: "B", id: rightID)
        let vm = makeVM(record: record, segments: [left, right])

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 1, "merge should drop the pair to one segment")
        let merged = vm.timelineSegments[0]
        XCTAssertEqual(merged.range.startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(merged.range.endSeconds, 15, accuracy: 0.001,
                       "merged range should cover the union including the recovered span")
        XCTAssertNotEqual(merged.id, leftID, "merge convention assigns a fresh UUID")
        XCTAssertNotEqual(merged.id, rightID)
    }

    func test_restoreCut_resetsSelectionToMergedSegment() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )
        let leftID = vm.timelineSegments[0].id
        let rightID = vm.timelineSegments[1].id
        // Pre-merge: both old IDs selected — simulate a stale multi-select.
        vm.selectAllSegments()
        XCTAssertEqual(vm.selectedSegmentIDs, Set([leftID, rightID]), "sanity: both selected pre-merge")

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        let mergedID = vm.timelineSegments[0].id
        XCTAssertEqual(vm.selectedSegmentIDs, Set([mergedID]),
                       "post-merge selection must be exactly the merged UUID — no stale IDs")
        XCTAssertFalse(vm.selectedSegmentIDs.contains(leftID))
        XCTAssertFalse(vm.selectedSegmentIDs.contains(rightID))
    }

    func test_restoreCut_preservesOuterCrossfades_dropsInnerPair() {
        let record = makeRecord()
        var leftEffects = SegmentEffects()
        leftEffects.audioFadeInDuration = 0.4   // outer crossfade from before-left
        leftEffects.audioFadeOutDuration = 0.5  // inner pair (with right.fadeIn)
        var rightEffects = SegmentEffects()
        rightEffects.audioFadeInDuration = 0.5  // inner pair (with left.fadeOut)
        rightEffects.audioFadeOutDuration = 0.3 // outer crossfade to after-right
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5, effects: leftEffects),
                segment(sourceID: record.id, start: 10, end: 15, effects: rightEffects)
            ]
        )

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 1, "compatible inner-vs-outer crossfade pair must still merge")
        let merged = vm.timelineSegments[0]
        XCTAssertEqual(merged.effects.audioFadeInDuration, 0.4, accuracy: 0.001,
                       "outer fade-in (before-left → left) must survive")
        XCTAssertEqual(merged.effects.audioFadeOutDuration, 0.3, accuracy: 0.001,
                       "outer fade-out (right → after-right) must survive")
    }

    func test_restoreCut_inheritsLeftSpeedAndVolume() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5, speedRate: 1.5, volumeLevel: 0.8),
                segment(sourceID: record.id, start: 10, end: 15, speedRate: 1.5, volumeLevel: 0.8)
            ]
        )

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        let merged = vm.timelineSegments[0]
        XCTAssertEqual(merged.speedRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(merged.volumeLevel, 0.8, accuracy: 0.001)
    }

    // MARK: - Insert fallback path

    func test_restoreCut_differentSpeedRates_insertsNewClip() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5, speedRate: 1.0),
                segment(sourceID: record.id, start: 10, end: 15, speedRate: 2.0)
            ]
        )
        let leftID = vm.timelineSegments[0].id
        let rightID = vm.timelineSegments[1].id

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 3,
                       "differing speed → fall back to inserting a recovered clip between left and right")
        XCTAssertEqual(vm.timelineSegments[0].id, leftID)
        XCTAssertEqual(vm.timelineSegments[2].id, rightID)
        let inserted = vm.timelineSegments[1]
        XCTAssertEqual(inserted.range.startSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(inserted.range.endSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(inserted.speedRate, 1.0, accuracy: 0.001,
                       "when sides disagree on speedRate, inserted clip uses default 1.0")
        XCTAssertNotNil(vm.bannerMessage,
                       "fallback path must surface a banner explaining why no merge happened")
    }

    func test_restoreCut_insertedClipInheritsSharedSpeedWhenSidesAgree() {
        // Effects differ on volume only, so we fall back to insert,
        // but both sides happen to share speedRate=1.5 → the inserted
        // clip should inherit it so the user doesn't hear a tempo
        // change inside what was originally one continuous take.
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5, speedRate: 1.5, volumeLevel: 0.5),
                segment(sourceID: record.id, start: 10, end: 15, speedRate: 1.5, volumeLevel: 1.0)
            ]
        )

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 3, "differing volume → insert fallback")
        XCTAssertEqual(vm.timelineSegments[1].speedRate, 1.5, accuracy: 0.001,
                       "inserted clip should inherit the shared speedRate")
    }

    // MARK: - Guards / no-ops

    func test_restoreCut_zeroGap_noOp() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 5, end: 10)
            ]
        )

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 2,
                       "abutting segments have no gap to restore — must be a no-op")
    }

    func test_restoreCut_subEpsilonGap_noOp() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 5.04, end: 10)
            ]
        )

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 2,
                       "gap of 0.04s is below the 0.05 epsilon and must not trigger a merge")
    }

    func test_restoreCut_differentSourceVideos_noOp() {
        let recordA = makeRecord()
        let recordB = makeRecord()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        vm.records = [recordA, recordB]
        vm.timelineSegments = [
            segment(sourceID: recordA.id, start: 0, end: 5),
            segment(sourceID: recordB.id, start: 10, end: 15)
        ]

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 2,
                       "different sources cannot share a 'cut' — no-op")
    }

    func test_restoreCut_detachedAudioSide_noOp() {
        let record = makeRecord()
        let auxID = UUID()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5, linkedSegmentID: auxID),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 2,
                       "linked aux audio is out of scope for v1 restore — must no-op rather than half-fix")
    }

    func test_restoreCut_missingSourceRecord_setsBannerAndNoOps() {
        // VM has segments referencing a sourceID with no matching record.
        // restorableGap doesn't check records, so this exercises the
        // "rebuildSubtitles returns nil" guard inside restoreCutBetween.
        let phantomID = UUID()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        vm.records = []
        vm.timelineSegments = [
            segment(sourceID: phantomID, start: 0, end: 5),
            segment(sourceID: phantomID, start: 10, end: 15)
        ]

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 2,
                       "missing source record → refuse the merge; segment count unchanged")
        XCTAssertNotNil(vm.bannerMessage)
    }

    // MARK: - Subtitles

    func test_restoreCut_rebuildsSubtitlesForRecoveredSpan() {
        // Transcript covers the cut span (5..10s in source coordinates).
        // After merge, the merged segment's subtitles should include
        // entries spanning the recovered region (with relativeStart
        // measured from the merged range's start).
        let transcript = [
            TranscriptSegment(startSeconds: 0, endSeconds: 4, text: "left side", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 6, endSeconds: 9, text: "recovered words", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 11, endSeconds: 14, text: "right side", sourceVideoID: nil)
        ]
        let record = makeRecord(transcript: transcript)
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 1)
        let merged = vm.timelineSegments[0]
        XCTAssertFalse(merged.subtitles.isEmpty,
                       "merged segment should have subtitles rebuilt from the transcript")
        // Find the cue covering the recovered span [5..10] in source
        // coords, which is [5..10] in relative-to-merged coords too
        // (mergedStart = 0). The "recovered words" cue lives at
        // source 6..9 → relative 6..9.
        let recovered = merged.subtitles.first { sub in
            let relStart = sub.relativeStart
            let relEnd = sub.relativeStart + sub.relativeDuration
            return relStart >= 6 - 0.01 && relEnd <= 9 + 0.01
        }
        XCTAssertNotNil(recovered, "subtitle cue from the previously-cut span must come back")
        XCTAssertEqual(recovered?.text, "recovered words")
    }

    func test_restoreCut_emptyTranscript_succeedsWithEmptySubs() {
        // Source record exists but has no transcript → rebuildSubtitles
        // returns []. Merge should still succeed with an empty subs array.
        let record = makeRecord(transcript: nil)
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.timelineSegments.count, 1, "merge succeeds even without a transcript")
        XCTAssertTrue(vm.timelineSegments[0].subtitles.isEmpty)
    }

    // MARK: - Tombstones

    func test_restoreCut_dropsTombstonesInsideRecoveredSpan() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )
        // Two tombstones in the recovered [5..10] source span, plus
        // one outside (at 20..21) that must survive.
        let inside1 = SubtitleTombstone(
            id: UUID(), text: "inside-A", speakerID: nil,
            sourceVideoID: record.id,
            sourceStart: 6, sourceEnd: 7, speedRate: 1,
            originalComposedStart: 0, originalComposedEnd: 1
        )
        let inside2 = SubtitleTombstone(
            id: UUID(), text: "inside-B", speakerID: nil,
            sourceVideoID: record.id,
            sourceStart: 8, sourceEnd: 9, speedRate: 1,
            originalComposedStart: 0, originalComposedEnd: 1
        )
        let outside = SubtitleTombstone(
            id: UUID(), text: "outside", speakerID: nil,
            sourceVideoID: record.id,
            sourceStart: 20, sourceEnd: 21, speedRate: 1,
            originalComposedStart: 0, originalComposedEnd: 1
        )
        vm.subtitleTombstones = [inside1, inside2, outside]

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.subtitleTombstones.count, 1,
                       "tombstones inside the recovered span must be dropped")
        XCTAssertEqual(vm.subtitleTombstones.first?.id, outside.id,
                       "tombstones outside the span must be preserved")
    }

    func test_restoreCut_keepsTombstonesForOtherSources() {
        // Tombstone for a different source video falls inside the same
        // numeric range — must NOT be dropped (keyed on sourceVideoID).
        let record = makeRecord()
        let otherSource = UUID()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )
        let foreign = SubtitleTombstone(
            id: UUID(), text: "foreign", speakerID: nil,
            sourceVideoID: otherSource,
            sourceStart: 6, sourceEnd: 7, speedRate: 1,
            originalComposedStart: 0, originalComposedEnd: 1
        )
        vm.subtitleTombstones = [foreign]

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.subtitleTombstones.count, 1,
                       "tombstones from other source videos must be preserved")
    }

    // MARK: - Revisions / undo

    func test_restoreCut_pushesRevisionForUndo() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )
        let revisionsBefore = vm.revisions.count

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        XCTAssertEqual(vm.revisions.count, revisionsBefore + 1,
                       "restoreCut must push a revision so Cmd+Z can undo it")
        XCTAssertEqual(vm.revisions.last?.label, "Restore cut")
    }

    // MARK: - Chat attachments

    func test_restoreCut_invalidatesChatAttachmentForRightSegment() {
        let record = makeRecord()
        let vm = makeVM(
            record: record,
            segments: [
                segment(sourceID: record.id, start: 0, end: 5),
                segment(sourceID: record.id, start: 10, end: 15)
            ]
        )
        // Need to select a record so attachSegment's ComposedTimelineIndex
        // build runs against a known record — and so attachments are valid.
        vm.select(recordID: record.id)
        let rightID = vm.timelineSegments[1].id
        vm.attachSegment(id: rightID)
        XCTAssertEqual(vm.validChatAttachments.count, 1, "sanity: attachment is valid pre-merge")

        vm.restoreCutBetween(leftIndex: 0, rightIndex: 1)

        // The merged segment has a new UUID, so the attachment to the
        // old rightID dangles and is filtered out by the live-ID gate.
        XCTAssertEqual(vm.validChatAttachments.count, 0,
                       "merged segment uses a fresh UUID; attachment to old rightID must filter out")
    }
}
