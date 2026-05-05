import XCTest
import AVFoundation
import CuttiKit
@testable import CuttiMac

/// Regression coverage for the "Split also works on the selected
/// overlay track" feature. The Cmd+B shortcut and the timeline split
/// button both route through `splitAtPlayheadRespectingSelection`,
/// which dispatches to either `splitOverlaySegmentAtPlayhead` (when
/// the user has an overlay segment selected and the playhead is
/// inside it) or the legacy V1 `splitAtPlayhead` otherwise.
@MainActor
final class SplitOverlayTrackTests: XCTestCase {

    // MARK: - Helpers

    private func makeRecord(
        id: UUID = UUID(),
        durationSeconds: Double = 300
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: id,
            sourcePath: "/tmp/\(id.uuidString).mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(
                durationSeconds: durationSeconds,
                width: 1920,
                height: 1080,
                nominalFPS: 30,
                hasAudio: true
            ),
            derived: DerivedAssetState(
                proxyRelativePath: "media/proxies/sample.mov",
                thumbnailsReady: false,
                waveformsReady: false
            ),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
    }

    /// VM with a 30s V1 primary segment + a 10s overlay segment
    /// anchored at composed time 5s. Returns the overlay segment id
    /// so tests can target it directly.
    private func makeVMWithOverlay() -> (vm: MediaCoreViewModel, overlayID: UUID, v1ID: UUID) {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(
            playbackCore: spy,
            projectRoot: URL(fileURLWithPath: "/project")
        )
        let primaryRecord = makeRecord(durationSeconds: 60)
        let overlayRecord = makeRecord(durationSeconds: 30)
        vm.records = [primaryRecord, overlayRecord]
        vm.select(recordID: primaryRecord.id)

        let v1ID = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: v1ID,
                sourceVideoID: primaryRecord.id,
                range: TimeRange(startSeconds: 0, endSeconds: 30),
                text: "V1",
                subtitles: []
            )
        ]

        let overlayID = UUID()
        let overlayTrack = Track(
            kind: .overlay,
            name: "V2",
            segments: [
                TimelineSegment(
                    id: overlayID,
                    sourceVideoID: overlayRecord.id,
                    range: TimeRange(startSeconds: 0, endSeconds: 10),
                    text: "AI animation",
                    subtitles: [],
                    placementOffset: 5.0
                )
            ]
        )
        vm.project.tracks.append(overlayTrack)

        return (vm, overlayID, v1ID)
    }

    // MARK: - Dispatch routing

    func test_dispatcher_splitsOverlay_whenOverlaySelectedAndPlayheadInside() {
        let (vm, overlayID, _) = makeVMWithOverlay()
        vm.selectedOverlaySegmentID = overlayID

        // Overlay covers composed [5, 15]. Playhead at 8 is inside.
        vm.splitAtPlayheadRespectingSelection(composedTime: 8.0)

        let overlaySegments = vm.project.overlayTracks.first?.segments ?? []
        XCTAssertEqual(overlaySegments.count, 2, "overlay should split into two halves")
        XCTAssertEqual(vm.timelineSegments.count, 1, "V1 must NOT be split")
    }

    func test_dispatcher_fallsBackToV1_whenNoOverlaySelected() {
        let (vm, _, _) = makeVMWithOverlay()
        vm.selectedOverlaySegmentID = nil

        vm.splitAtPlayheadRespectingSelection(composedTime: 8.0)

        XCTAssertEqual(vm.project.overlayTracks.first?.segments.count, 1)
        XCTAssertEqual(vm.timelineSegments.count, 2, "V1 should split since no overlay selected")
    }

    func test_dispatcher_fallsBackToV1_whenPlayheadOutsideSelectedOverlay() {
        let (vm, overlayID, _) = makeVMWithOverlay()
        vm.selectedOverlaySegmentID = overlayID

        // Overlay covers composed [5, 15]. Playhead at 20 is past it.
        vm.splitAtPlayheadRespectingSelection(composedTime: 20.0)

        XCTAssertEqual(vm.project.overlayTracks.first?.segments.count, 1)
        XCTAssertEqual(vm.timelineSegments.count, 2)
    }

    func test_dispatcher_noopsOnSplitTooNearOverlayEdge() {
        let (vm, overlayID, _) = makeVMWithOverlay()
        vm.selectedOverlaySegmentID = overlayID

        let beforeOverlayCount = vm.project.overlayTracks.first?.segments.count ?? 0
        let beforeV1Count = vm.timelineSegments.count

        // 5.05s composed = 0.05s into the overlay → too close to start.
        vm.splitAtPlayheadRespectingSelection(composedTime: 5.05)
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.count, beforeOverlayCount)
        XCTAssertEqual(vm.timelineSegments.count, beforeV1Count)

        // 14.95s composed = 0.05s before the overlay end → too close to end.
        vm.splitAtPlayheadRespectingSelection(composedTime: 14.95)
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.count, beforeOverlayCount)
        XCTAssertEqual(vm.timelineSegments.count, beforeV1Count)
    }

    // MARK: - Selection mutual exclusion

    func test_selectingOverlay_clearsV1Selection() {
        let (vm, overlayID, v1ID) = makeVMWithOverlay()
        vm.selectSegment(id: v1ID)
        XCTAssertEqual(vm.selectedSegmentIDs, [v1ID])

        vm.selectedOverlaySegmentID = overlayID

        XCTAssertTrue(vm.selectedSegmentIDs.isEmpty,
                      "selecting an overlay must clear V1 selection so Cmd+B routes to the overlay")
        XCTAssertEqual(vm.selectedOverlaySegmentID, overlayID)
    }

    func test_handleSegmentClick_clearsOverlaySelection() {
        let (vm, overlayID, _) = makeVMWithOverlay()
        vm.selectedOverlaySegmentID = overlayID
        XCTAssertEqual(vm.selectedOverlaySegmentID, overlayID)

        vm.handleSegmentClick(index: 0)

        XCTAssertNil(vm.selectedOverlaySegmentID,
                     "clicking V1 must clear overlay selection so Cmd+B routes to V1")
    }

    // MARK: - Overlay split semantics

    func test_splitOverlay_producesTwoHalvesCoveringOriginalSpan() {
        let (vm, overlayID, _) = makeVMWithOverlay()

        vm.splitOverlaySegmentAtPlayhead(segmentID: overlayID, composedTime: 8.0)

        let segs = vm.project.overlayTracks.first?.segments ?? []
        XCTAssertEqual(segs.count, 2)
        let left = segs[0]
        let right = segs[1]

        // Left covers composed [5, 8] = source [0, 3].
        XCTAssertEqual(left.placementOffset ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(left.range.startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(left.range.endSeconds, 3.0, accuracy: 0.001)

        // Right covers composed [8, 15] = source [3, 10].
        XCTAssertEqual(right.placementOffset ?? -1, 8.0, accuracy: 0.001)
        XCTAssertEqual(right.range.startSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(right.range.endSeconds, 10.0, accuracy: 0.001)
    }

    func test_splitOverlay_preservesVisualFieldsOnBothHalves() {
        let (vm, overlayID, _) = makeVMWithOverlay()
        // Mutate the overlay with non-default visual + audio fields so
        // we can assert preservation post-split.
        if let (tIdx, sIdx) = findOverlayLocation(vm: vm, segmentID: overlayID) {
            vm.project.tracks[tIdx].segments[sIdx].volumeLevel = 0.5
            vm.project.tracks[tIdx].segments[sIdx].speedRate = 1.5
            vm.project.tracks[tIdx].segments[sIdx].pipLayout = PiPLayout.default
            vm.project.tracks[tIdx].segments[sIdx].isVideoHidden = true
        }

        // Overlay is now 10s/1.5 ≈ 6.67s composed at 5..11.67.
        // Split at composed 8.
        vm.splitOverlaySegmentAtPlayhead(segmentID: overlayID, composedTime: 8.0)

        let segs = vm.project.overlayTracks.first?.segments ?? []
        guard segs.count == 2 else { return XCTFail("expected 2 halves") }
        for seg in segs {
            XCTAssertEqual(seg.volumeLevel, 0.5, accuracy: 0.001)
            XCTAssertEqual(seg.speedRate, 1.5, accuracy: 0.001)
            XCTAssertNotNil(seg.pipLayout, "PiP layout must survive split")
            XCTAssertTrue(seg.isVideoHidden)
        }
    }

    func test_splitOverlay_dropsOverlaySpecOnRightHalfOnly() {
        let (vm, overlayID, _) = makeVMWithOverlay()
        let spec = OverlayRenderSpec(
            templateID: "headline_v1",
            propsJSON: "{\"text\":\"hi\"}",
            durationSeconds: 10.0
        )
        if let (tIdx, sIdx) = findOverlayLocation(vm: vm, segmentID: overlayID) {
            vm.project.tracks[tIdx].segments[sIdx].overlaySpec = spec
        }

        vm.splitOverlaySegmentAtPlayhead(segmentID: overlayID, composedTime: 8.0)

        let segs = vm.project.overlayTracks.first?.segments ?? []
        XCTAssertEqual(segs.count, 2)
        XCTAssertNotNil(segs[0].overlaySpec, "left half retains the editable spec")
        XCTAssertNil(segs[1].overlaySpec,
                     "right half drops the spec because re-rendering produces a fresh full-duration asset that wouldn't slice correctly into a non-zero range.start")
    }

    func test_splitOverlay_selectsLeftHalfAfterSplit() {
        let (vm, overlayID, _) = makeVMWithOverlay()
        vm.selectedOverlaySegmentID = overlayID

        vm.splitOverlaySegmentAtPlayhead(segmentID: overlayID, composedTime: 8.0)

        let leftID = vm.project.overlayTracks.first?.segments.first?.id
        XCTAssertNotNil(leftID)
        XCTAssertEqual(vm.selectedOverlaySegmentID, leftID,
                       "selection should follow the left half so a follow-up Cmd+B keeps splitting forward")
    }

    func test_splitOverlay_isUndoable() {
        let (vm, overlayID, _) = makeVMWithOverlay()

        vm.splitOverlaySegmentAtPlayhead(segmentID: overlayID, composedTime: 8.0)
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.count, 2)
        XCTAssertTrue(vm.canUndo)

        vm.undo()

        let restored = vm.project.overlayTracks.first?.segments ?? []
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, overlayID, "undo should restore the original overlay segment id")
    }

    // MARK: - Subtitle preservation on overlay split

    func test_splitOverlay_preservesBilingualSubtitleData() {
        let (vm, overlayID, _) = makeVMWithOverlay()

        // Cue 0–4s in source: belongs entirely to the LEFT half.
        // Carry translations + speakerID; both must survive.
        let leftCue = SubtitleEntry(
            id: UUID(),
            relativeStart: 0,
            relativeDuration: 4.0,
            text: "Hello",
            speakerID: 1,
            translations: ["zh-Hans": "你好"]
        )
        // Cue 5–8s in source: belongs entirely to the RIGHT half
        // (after subtraction of the cut offset).
        let rightCue = SubtitleEntry(
            id: UUID(),
            relativeStart: 5,
            relativeDuration: 3.0,
            text: "Goodbye",
            speakerID: 2,
            translations: ["zh-Hans": "再见"]
        )
        if let (tIdx, sIdx) = findOverlayLocation(vm: vm, segmentID: overlayID) {
            vm.project.tracks[tIdx].segments[sIdx].subtitles = [leftCue, rightCue]
        }

        // Overlay covers composed [5, 15] (1x speed). Split at 9 →
        // source split = 4. So leftCue (source 0..4) stays in left,
        // rightCue (source 5..8) goes to right with its relativeStart
        // shifted by 4 → 1..4.
        vm.splitOverlaySegmentAtPlayhead(segmentID: overlayID, composedTime: 9.0)

        let segs = vm.project.overlayTracks.first?.segments ?? []
        XCTAssertEqual(segs.count, 2)

        XCTAssertEqual(segs[0].subtitles.count, 1)
        XCTAssertEqual(segs[0].subtitles[0].text, "Hello")
        XCTAssertEqual(segs[0].subtitles[0].speakerID, 1)
        XCTAssertEqual(segs[0].subtitles[0].translations["zh-Hans"], "你好")

        XCTAssertEqual(segs[1].subtitles.count, 1)
        XCTAssertEqual(segs[1].subtitles[0].text, "Goodbye")
        XCTAssertEqual(segs[1].subtitles[0].speakerID, 2)
        XCTAssertEqual(segs[1].subtitles[0].translations["zh-Hans"], "再见")
        XCTAssertEqual(segs[1].subtitles[0].relativeStart, 1.0, accuracy: 0.001)
    }

    func test_splitOverlay_clipsStraddlingCueAndPreservesTranslationsOnBothHalves() {
        let (vm, overlayID, _) = makeVMWithOverlay()
        // Cue 2–7s in source straddles a cut at source-time 4.
        let cue = SubtitleEntry(
            id: UUID(),
            relativeStart: 2.0,
            relativeDuration: 5.0,
            text: "Bridges the cut",
            speakerID: 3,
            translations: ["zh-Hans": "跨越剪辑点"]
        )
        if let (tIdx, sIdx) = findOverlayLocation(vm: vm, segmentID: overlayID) {
            vm.project.tracks[tIdx].segments[sIdx].subtitles = [cue]
        }

        // Composed split at 9.0 → source split at 4.0.
        vm.splitOverlaySegmentAtPlayhead(segmentID: overlayID, composedTime: 9.0)

        let segs = vm.project.overlayTracks.first?.segments ?? []
        XCTAssertEqual(segs.count, 2)

        // Left half got the [2, 4] piece.
        XCTAssertEqual(segs[0].subtitles.count, 1)
        XCTAssertEqual(segs[0].subtitles[0].relativeStart, 2.0, accuracy: 0.001)
        XCTAssertEqual(segs[0].subtitles[0].relativeDuration, 2.0, accuracy: 0.001)
        XCTAssertEqual(segs[0].subtitles[0].speakerID, 3)
        XCTAssertEqual(segs[0].subtitles[0].translations["zh-Hans"], "跨越剪辑点",
                       "translations must survive the straddle clip")

        // Right half got the [0, 3] piece (5-cut at source 4 → 4..7 → shifted by 4 → 0..3).
        XCTAssertEqual(segs[1].subtitles.count, 1)
        XCTAssertEqual(segs[1].subtitles[0].relativeStart, 0, accuracy: 0.001)
        XCTAssertEqual(segs[1].subtitles[0].relativeDuration, 3.0, accuracy: 0.001)
        XCTAssertEqual(segs[1].subtitles[0].speakerID, 3)
        XCTAssertEqual(segs[1].subtitles[0].translations["zh-Hans"], "跨越剪辑点",
                       "translations must survive on the right half too")
        XCTAssertNotEqual(segs[1].subtitles[0].id, cue.id,
                          "right-half straddle clone must use a fresh id so both halves stay independently editable")
    }

    // MARK: - Helpers

    private func findOverlayLocation(vm: MediaCoreViewModel, segmentID: UUID) -> (Int, Int)? {
        for (tIdx, track) in vm.project.tracks.enumerated() where track.kind == .overlay {
            if let sIdx = track.segments.firstIndex(where: { $0.id == segmentID }) {
                return (tIdx, sIdx)
            }
        }
        return nil
    }
}
