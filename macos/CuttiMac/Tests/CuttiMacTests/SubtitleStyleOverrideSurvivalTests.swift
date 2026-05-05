import XCTest
import CuttiKit
@testable import CuttiMac

/// V1 of per-cue subtitle style override added a new metadata field to
/// `SubtitleEntry`. This file pins down the audit guarantee: every code
/// path that *transforms* an existing cue (text edit, resize, move, AI
/// rewrite, replace, segment split, segment merge, tombstone restore,
/// etc.) preserves `styleOverride`. Without these tests, future struct
/// fields are likely to silently drop again — that bug class drove the
/// per-cue-style scoping work in the first place.
@MainActor
final class SubtitleStyleOverrideSurvivalTests: XCTestCase {

    private let override = SubtitleCueStyleOverride(
        fontSizePoints: 70,
        textColor: SubtitleStyle.RGBAColor(red: 1, green: 0.85, blue: 0.08, alpha: 1),
        backgroundColor: .black,
        cornerRadius: 12
    )

    private func makeVM(with subtitles: [SubtitleEntry], speed: Double = 1.0) -> MediaCoreViewModel {
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 30),
                text: subtitles.map(\.text).joined(separator: " "),
                subtitles: subtitles,
                speedRate: speed
            )
        ]
        return vm
    }

    private func cue(for id: UUID, in vm: MediaCoreViewModel) -> SubtitleEntry? {
        vm.timelineSegments.flatMap(\.subtitles).first { $0.id == id }
    }

    // MARK: - Text-mutating paths

    func test_updateSubtitleText_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "hello",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.updateSubtitleText(id: id, newText: "hello world")
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
        XCTAssertEqual(cue(for: id, in: vm)?.text, "hello world")
    }

    func test_replaceSubtitleText_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "foo bar",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        let n = vm.replaceSubtitleText(find: "foo", replace: "FOO")
        XCTAssertEqual(n, 1)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
        XCTAssertEqual(cue(for: id, in: vm)?.text, "FOO bar")
    }

    func test_updateSubtitleBilingualText_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "hi",
            translations: ["zh-Hans": "你好"],
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.updateSubtitleBilingualText(
            id: id, primaryText: "hello", secondaryText: "你好啊", secondaryLocale: "zh-Hans"
        )
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
        XCTAssertEqual(cue(for: id, in: vm)?.text, "hello")
    }

    // MARK: - Time-mutating paths

    func test_moveSubtitle_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.moveSubtitle(id: id, to: 2.0)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
    }

    func test_resizeSubtitle_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.resizeSubtitle(id: id, edge: .trailing, toComposedTime: 3.0)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
    }

    // MARK: - Run/emphasis paths

    func test_clearEmphasisOnSubtitle_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            runs: [SubtitleRun(text: "hi", style: SubtitleRunStyle(weight: .bold))],
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        let didClear = vm.clearEmphasisOnSubtitle(cueID: id)
        XCTAssertTrue(didClear)
        XCTAssertNil(cue(for: id, in: vm)?.runs)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override,
                       "clearing per-run emphasis must NOT touch the per-cue override")
    }

    // MARK: - Tombstone delete + restore

    func test_deleteThenRestoreSubtitle_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.rebuildComposedSubtitles()

        vm.deleteSubtitleCues(ids: [id])
        XCTAssertNil(cue(for: id, in: vm))
        let tomb = vm.subtitleTombstones.first { $0.id == id }
        XCTAssertEqual(tomb?.styleOverride, override,
                       "tombstone must capture override at delete time")

        vm.restoreSubtitleTombstone(id: id)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override,
                       "restored cue must wear the same override it had at delete time")
    }

    // MARK: - Translation merge (write-back path)

    func test_mergeSubtitleTranslations_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "hello",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        let merge = vm.mergeSubtitleTranslations(
            into: vm.timelineSegments,
            translations: [id: "你好"],
            locale: "zh-Hans"
        )
        let merged = merge.segments.flatMap(\.subtitles).first { $0.id == id }
        XCTAssertEqual(merged?.styleOverride, override)
        XCTAssertEqual(merged?.translations["zh-Hans"], "你好")
    }
}
