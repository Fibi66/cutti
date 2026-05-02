import XCTest
import CuttiKit
@testable import CuttiMac

/// Unit tests for the subtitle emphasis VM methods that back the
/// "Emphasize words…" sheet and the `emphasize_words` AI tool (Phase 3).
/// The sheet itself is SwiftUI-only and covered by manual smoke; these
/// tests pin the data-model + revision semantics.
@MainActor
final class SubtitleEmphasisTests: XCTestCase {

    private func makeVM(text: String) -> (MediaCoreViewModel, UUID) {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(
            playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        let cueID = UUID()
        let entry = SubtitleEntry(
            id: cueID,
            relativeStart: 0,
            relativeDuration: 2,
            text: text
        )
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 2),
                text: text,
                subtitles: [entry]
            )
        ]
        vm.rebuildComposedSubtitles()
        return (vm, cueID)
    }

    func test_applyEmphasis_seedsRunsAndMergesPatch() {
        let (vm, cueID) = makeVM(text: "Hello world")
        // Color "world" red: UTF-16 offsets 6..11.
        let ok = vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 6, length: 5)],
            patch: SubtitleRunStyle(
                textColor: .init(red: 1, green: 0, blue: 0, alpha: 1)
            )
        )
        XCTAssertTrue(ok)
        let runs = vm.timelineSegments[0].subtitles[0].runs
        XCTAssertNotNil(runs)
        // Expect 2 runs: "Hello " (plain) + "world" (red).
        XCTAssertEqual(runs?.count, 2)
        XCTAssertEqual(runs?[0].text, "Hello ")
        XCTAssertEqual(runs?[0].style, .empty)
        XCTAssertEqual(runs?[1].text, "world")
        XCTAssertEqual(runs?[1].style.textColor?.red, 1)
        // Plain-text invariant MUST hold after apply.
        XCTAssertEqual(
            SubtitleRunEditor.plainText(runs ?? []),
            "Hello world"
        )
        // ComposedSubtitles re-built with new runs.
        XCTAssertEqual(vm.composedSubtitles.first?.runs?.count, 2)
    }

    func test_applyEmphasis_mergesMultipleRangesInOneCall() {
        let (vm, cueID) = makeVM(text: "one two three")
        // "one"=0..3, "three"=8..13. Non-adjacent → stays two ranges.
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [
                NSRange(location: 0, length: 3),
                NSRange(location: 8, length: 5),
            ],
            patch: SubtitleRunStyle(weight: .bold)
        )
        let runs = vm.timelineSegments[0].subtitles[0].runs ?? []
        // Expect 3 runs: "one" bold, " two " plain, "three" bold.
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].text, "one")
        XCTAssertEqual(runs[0].style.weight, .bold)
        XCTAssertEqual(runs[1].text, " two ")
        XCTAssertEqual(runs[1].style, .empty)
        XCTAssertEqual(runs[2].text, "three")
        XCTAssertEqual(runs[2].style.weight, .bold)
    }

    func test_applyEmphasis_adjacentRangesMergeIntoSingleRun() {
        // Chinese text: each char is one token. Selecting two adjacent
        // chars must produce ONE run, not two.
        let (vm, cueID) = makeVM(text: "你好世界")
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [
                NSRange(location: 1, length: 1),  // 好
                NSRange(location: 2, length: 1),  // 世
            ],
            patch: SubtitleRunStyle(sizeMultiplier: 1.5)
        )
        let runs = vm.timelineSegments[0].subtitles[0].runs ?? []
        // Expect 3 runs: "你" plain, "好世" 1.5x, "界" plain.
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[1].text, "好世")
        XCTAssertEqual(runs[1].style.sizeMultiplier, 1.5)
    }

    func test_applyEmphasis_mergeModeKeepsExistingOverrides() {
        let (vm, cueID) = makeVM(text: "abc")
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 0, length: 3)],
            patch: SubtitleRunStyle(weight: .bold)
        )
        // Second apply: add color without clobbering weight.
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 0, length: 3)],
            patch: SubtitleRunStyle(
                textColor: .init(red: 0, green: 1, blue: 0, alpha: 1)
            )
        )
        let runs = vm.timelineSegments[0].subtitles[0].runs ?? []
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].style.weight, .bold)
        XCTAssertEqual(runs[0].style.textColor?.green, 1)
    }

    func test_applyEmphasis_replaceMode_overwritesStyles() {
        let (vm, cueID) = makeVM(text: "abc")
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 0, length: 3)],
            patch: SubtitleRunStyle(
                weight: .bold,
                textColor: .init(red: 1, green: 0, blue: 0, alpha: 1)
            )
        )
        // Replace with empty → back to plain.
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 0, length: 3)],
            patch: .empty,
            replace: true
        )
        let runs = vm.timelineSegments[0].subtitles[0].runs ?? []
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].style, .empty)
    }

    func test_applyEmphasis_outOfBoundsRange_returnsFalseAndNoWrite() {
        let (vm, cueID) = makeVM(text: "abc")
        let before = vm.timelineSegments[0].subtitles[0].runs
        let ok = vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 10, length: 5)],
            patch: SubtitleRunStyle(weight: .bold)
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.timelineSegments[0].subtitles[0].runs, before)
    }

    func test_applyEmphasis_clampsPartiallyOutOfBoundsRange() {
        let (vm, cueID) = makeVM(text: "abc")
        // Range 1..10 clips to 1..3.
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 1, length: 9)],
            patch: SubtitleRunStyle(weight: .bold)
        )
        let runs = vm.timelineSegments[0].subtitles[0].runs ?? []
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].text, "a")
        XCTAssertEqual(runs[1].text, "bc")
        XCTAssertEqual(runs[1].style.weight, .bold)
    }

    func test_applyEmphasis_unknownCueID_returnsFalse() {
        let (vm, _) = makeVM(text: "hi")
        XCTAssertFalse(vm.applyEmphasisToSubtitle(
            cueID: UUID(),
            utf16Ranges: [NSRange(location: 0, length: 2)],
            patch: SubtitleRunStyle(weight: .bold)
        ))
    }

    // MARK: - clearEmphasisOnSubtitle

    func test_clearEmphasis_resetsRunsToNil() {
        let (vm, cueID) = makeVM(text: "abc")
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 0, length: 3)],
            patch: SubtitleRunStyle(weight: .bold)
        )
        XCTAssertNotNil(vm.timelineSegments[0].subtitles[0].runs)

        let cleared = vm.clearEmphasisOnSubtitle(cueID: cueID)
        XCTAssertTrue(cleared)
        XCTAssertNil(vm.timelineSegments[0].subtitles[0].runs)
    }

    func test_clearEmphasis_onPlainCue_isNoOp() {
        let (vm, cueID) = makeVM(text: "abc")
        XCTAssertFalse(vm.clearEmphasisOnSubtitle(cueID: cueID))
    }

    // MARK: - Undo/redo integration

    func test_applyEmphasis_isUndoable() {
        let (vm, cueID) = makeVM(text: "abc")
        vm.applyEmphasisToSubtitle(
            cueID: cueID,
            utf16Ranges: [NSRange(location: 0, length: 3)],
            patch: SubtitleRunStyle(weight: .bold)
        )
        XCTAssertNotNil(vm.timelineSegments[0].subtitles[0].runs)
        vm.undo()
        XCTAssertNil(vm.timelineSegments[0].subtitles[0].runs)
    }
}
